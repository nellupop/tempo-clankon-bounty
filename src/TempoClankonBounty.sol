// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// ─── Tempo Precompile Interfaces ──────────────────────────────────────────────

/// @notice Minimal interface for Tempo's TIP-20 Factory precompile
/// @dev Predeployed at 0x20C000000000000000000000000000000000000A (TIP-20 Factory)
///      Used to verify whether an address is a valid TIP-20 stablecoin on Tempo.
interface ITIP20Factory {
    function isTIP20(address token) external view returns (bool);
}

/// @notice Minimal interface for Tempo's enshrined Stablecoin DEX precompile
/// @dev Predeployed at 0xDEc0000000000000000000000000000000000000
///      Supports swapExactAmountIn and quoting between any two TIP-20 stablecoins.
///      Uses uint128 for amounts (not uint256 as in standard ERC-20 DEXes).
interface IStablecoinDEX {
    /// @notice Swap an exact input amount for at least minAmountOut of tokenOut
    /// @param tokenIn  Address of TIP-20 token to sell
    /// @param tokenOut Address of TIP-20 token to receive
    /// @param amountIn Exact amount of tokenIn to sell (uint128)
    /// @param minAmountOut Minimum acceptable output (slippage protection)
    /// @return amountOut Actual amount of tokenOut received
    function swapExactAmountIn(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut
    ) external returns (uint128 amountOut);

    /// @notice Quote the output for an exact-input swap (view, no gas cost)
    function quoteSwapExactAmountIn(
        address tokenIn,
        address tokenOut,
        uint128 amountIn
    ) external view returns (uint128 amountOut);
}

/// @title TempoClankonBounty — Tempo-native agent-to-agent bounty escrow with multi-winner support
/// @notice Poster deposits any Tempo TIP-20 stablecoin, oracle reports eval winners,
///         winners can claim their reward in the original token OR swap via Tempo's
///         enshrined DEX into any other TIP-20 stablecoin of their choosing.
///
/// @dev Key differences from Ethereum/EVM ClankonBounty:
///   1. No ETH / native token assumptions. All value is held in TIP-20 stablecoins.
///   2. Token validation uses Tempo's TIP-20 Factory precompile (`isTIP20`) instead of
///      an owner-managed allowlist, so any legitimately issued Tempo stablecoin is
///      accepted automatically without admin intervention.
///   3. Winners may claim in a *different* stablecoin by routing through Tempo's
///      enshrined DEX precompile (0xDEc0000...). DEX amounts use uint128 per the spec.
///   4. Gas/storage optimizations for Tempo:
///      - `uint128` used for DEX amount casts (DEX-compatible).
///      - Bounty struct packs status (uint8) and numWinners (uint8) tightly.
///      - Removed the legacy `platformFeeBps` state variable (replaced entirely by
///        the per-bounty `bountyFeeBps` mapping that was already authoritative).
///      - `cancelPenaltyBps` and fee tier arrays remain for full functional parity.
contract TempoClankonBounty is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ─── Tempo Precompile Addresses ───────────────────────────────────────────

    /// @notice Tempo TIP-20 Factory precompile — validates whether a token is TIP-20
    ITIP20Factory public constant TIP20_FACTORY =
        ITIP20Factory(0x20C000000000000000000000000000000000000A);

    /// @notice Tempo enshrined Stablecoin DEX precompile
    /// @dev Fixed protocol-level address on Tempo. Uses uint128 for amounts.
    IStablecoinDEX public constant STABLECOIN_DEX =
        IStablecoinDEX(0xDEc0000000000000000000000000000000000000);

    // ─── Types ────────────────────────────────────────────────────────────────

    enum BountyStatus {
        Active,
        Resolved,
        Claimed,
        Cancelled
    }

    /// @dev Tightly packed for Tempo storage efficiency.
    struct Bounty {
        address poster;
        address token;
        uint256 amount;
        uint256 deadline;
        bytes32 evalHash;
        string metadataURI;
        uint8 numWinners;
        BountyStatus status;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    mapping(uint256 => Bounty) internal _bounties;
    uint256 public nextBountyId;

    mapping(uint256 => uint16[]) internal _sharesBps;
    mapping(uint256 => address[]) internal _winners;
    mapping(uint256 => uint256[]) internal _winnerScores;
    mapping(uint256 => mapping(address => uint256)) public winnerRewards;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(uint256 => uint256) public bountyBalance;

    // Reveal bundle state
    mapping(uint256 => address[]) internal _revealSolvers;
    mapping(uint256 => uint16[]) internal _revealSharesBps;
    mapping(uint256 => mapping(address => bool)) internal _isRevealSolver;
    mapping(uint256 => mapping(address => uint16)) internal _revealShareBpsBySolver;
    mapping(uint256 => mapping(address => bool)) public revealBundleAccess;
    mapping(uint256 => mapping(address => uint256)) public revealRevenueClaimed;
    mapping(uint256 => uint256) public revealBundlePrice;
    mapping(uint256 => uint256) public totalRevealRevenue;

    address public oracle;
    address public treasury;

    /// @notice Per-bounty fee tier in basis points
    mapping(uint256 => uint16) public bountyFeeBps;

    /// @notice Allowed fee tiers (e.g. [100, 250, 500])
    uint16[] internal _allowedFeeTiers;
    mapping(uint16 => bool) public isAllowedFeeTier;

    uint16 public revealFeeBps = 500; // 5% reveal bundle platform fee

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant GRACE_PERIOD = 7 days;
    uint8 public constant MAX_WINNERS = 3;
    uint256 public constant MAX_DURATION = 90 days;
    uint256 public constant MAX_CANCEL_PENALTY_BPS = 10000;
    uint256 public cancelPenaltyBps = 8000;

    /// @notice Minimum bounty amount in token base units (6-decimal TIP-20 stablecoins → 1 USD)
    uint256 public constant MIN_AMOUNT = 1_000_000;

    /// @notice Delegation: winner → preferred recipient wallet
    mapping(address => address) public delegatedWallets;

    // ─── Events ───────────────────────────────────────────────────────────────

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed poster,
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 numWinners,
        uint16 feeBps,
        string metadataURI
    );
    event WinnersReported(uint256 indexed bountyId, address[] winners, uint256[] scores);
    event RewardClaimed(
        uint256 indexed bountyId,
        address indexed winner,
        address indexed recipient,
        uint256 reward,
        address claimToken
    );
    event WalletDelegated(address indexed agent, address indexed delegate);
    event BountyReclaimed(uint256 indexed bountyId, address indexed poster, uint256 amount);
    event BountyCancelled(uint256 indexed bountyId, uint256 refund, uint256 penalty);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeeTiersUpdated(uint16[] tiers);
    event CancelPenaltyUpdated(uint256 oldPenalty, uint256 newPenalty);
    event RevealFeeBpsUpdated(uint16 oldFee, uint16 newFee);
    event RevealSetReported(
        uint256 indexed bountyId,
        address[] revealedSolvers,
        uint16[] revealSharesBps,
        uint256 bundlePrice
    );
    event RevealBundlePurchased(uint256 indexed bountyId, address indexed buyer, uint256 amount);
    event RevealRevenueClaimed(
        uint256 indexed bountyId,
        address indexed solver,
        address indexed recipient,
        uint256 amount
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error TokenNotTIP20();           // Replaces TokenNotAllowed — uses Tempo's TIP-20 factory check
    error DeadlineTooSoon();
    error DeadlineTooFar();
    error AmountZero();
    error AmountTooLow();
    error InvalidPayoutConfig();
    error SharesMustSumTo10000();
    error NotPoster();
    error BountyNotActive();
    error DeadlineReached();
    error DeadlineNotReached();
    error GracePeriodActive();
    error OnlyOracle();
    error TooManyWinners();
    error WinnersLengthMismatch();
    error ZeroAddressWinner();
    error DuplicateWinner();
    error NotWinner();
    error AlreadyClaimed();
    error ZeroAddress();
    error FeeTooHigh();
    error NothingToClaim();
    error RevealBundlePriceZero();
    error RevealAlreadyReported();
    error InvalidRevealSet();
    error ZeroAddressRevealSolver();
    error DuplicateRevealSolver();
    error RevealNotReported();
    error DuplicateBuyer();
    error NotRevealSolver();
    error InvalidFeeTier();
    error NotAuthorized();
    error SlippageTooHigh();
    error ClaimTokenNotTIP20();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _oracle, address _owner, address _treasury) Ownable(_owner) {
        if (_treasury == address(0)) revert ZeroAddress();
        oracle = _oracle;
        treasury = _treasury;
        // Default fee tiers: Haiku 1%, Sonnet 2.5%, Opus 5%
        _allowedFeeTiers = [100, 250, 500];
        isAllowedFeeTier[100] = true;
        isAllowedFeeTier[250] = true;
        isAllowedFeeTier[500] = true;
    }

    // ─── Poster Functions ─────────────────────────────────────────────────────

    /// @notice Create a bounty and escrow any Tempo TIP-20 stablecoin
    /// @dev Token validity is checked via the Tempo TIP-20 Factory precompile.
    ///      No owner-managed token allowlist is needed — any valid TIP-20 on Tempo is accepted.
    function createBounty(
        address token,
        uint256 amount,
        uint256 deadline,
        bytes32 evalHash,
        string calldata metadataURI,
        uint8 numWinners,
        uint16[] calldata sharesBps,
        uint16 feeBps
    ) external nonReentrant whenNotPaused returns (uint256 bountyId) {
        if (!TIP20_FACTORY.isTIP20(token)) revert TokenNotTIP20();
        if (deadline < block.timestamp + MIN_DURATION) revert DeadlineTooSoon();
        if (deadline > block.timestamp + MAX_DURATION) revert DeadlineTooFar();
        if (amount == 0) revert AmountZero();
        if (amount < MIN_AMOUNT) revert AmountTooLow();
        if (numWinners == 0 || numWinners > MAX_WINNERS) revert InvalidPayoutConfig();
        if (sharesBps.length != numWinners) revert InvalidPayoutConfig();
        if (!isAllowedFeeTier[feeBps]) revert InvalidFeeTier();

        uint256 totalShares;
        for (uint256 i = 0; i < sharesBps.length; i++) {
            totalShares += sharesBps[i];
        }
        if (totalShares != 10000) revert SharesMustSumTo10000();

        bountyId = nextBountyId++;

        _bounties[bountyId] = Bounty({
            poster: msg.sender,
            token: token,
            amount: amount,
            deadline: deadline,
            evalHash: evalHash,
            metadataURI: metadataURI,
            numWinners: numWinners,
            status: BountyStatus.Active
        });

        _sharesBps[bountyId] = sharesBps;
        bountyFeeBps[bountyId] = feeBps;
        bountyBalance[bountyId] = amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit BountyCreated(bountyId, msg.sender, token, amount, deadline, numWinners, feeBps, metadataURI);
    }

    /// @notice Poster cancels bounty before deadline if no winner has been reported
    function cancelBounty(uint256 bountyId) external nonReentrant whenNotPaused {
        Bounty storage b = _bounties[bountyId];
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != BountyStatus.Active) revert BountyNotActive();
        if (block.timestamp >= b.deadline) revert DeadlineReached();

        b.status = BountyStatus.Cancelled;
        uint256 balance = bountyBalance[bountyId];
        bountyBalance[bountyId] = 0;

        uint256 penalty = (balance * cancelPenaltyBps) / 10000;
        uint256 refund = balance - penalty;

        if (refund > 0) IERC20(b.token).safeTransfer(b.poster, refund);
        if (penalty > 0) IERC20(b.token).safeTransfer(treasury, penalty);

        emit BountyCancelled(bountyId, refund, penalty);
    }

    /// @notice Poster reclaims funds after deadline + grace period
    function reclaimBounty(uint256 bountyId) external nonReentrant {
        Bounty storage b = _bounties[bountyId];
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != BountyStatus.Active && b.status != BountyStatus.Resolved) revert BountyNotActive();
        if (block.timestamp < b.deadline + GRACE_PERIOD) revert GracePeriodActive();

        uint256 balance = bountyBalance[bountyId];
        bountyBalance[bountyId] = 0;
        b.status = BountyStatus.Cancelled;

        if (balance > 0) IERC20(b.token).safeTransfer(b.poster, balance);

        emit BountyReclaimed(bountyId, b.poster, balance);
    }

    // ─── Oracle Functions ─────────────────────────────────────────────────────

    /// @notice Oracle reports winners after deadline.
    ///         Fee is transferred immediately; rewards are stored for winner claims.
    function reportWinners(
        uint256 bountyId,
        address[] calldata winners,
        uint256[] calldata scores
    ) external nonReentrant whenNotPaused {
        if (msg.sender != oracle) revert OnlyOracle();

        Bounty storage b = _bounties[bountyId];
        if (b.status != BountyStatus.Active) revert BountyNotActive();
        if (block.timestamp < b.deadline) revert DeadlineNotReached();
        if (winners.length == 0 || winners.length > b.numWinners) revert TooManyWinners();
        if (winners.length != scores.length) revert WinnersLengthMismatch();

        for (uint256 i = 0; i < winners.length; i++) {
            if (winners[i] == address(0)) revert ZeroAddressWinner();
            for (uint256 j = 0; j < i; j++) {
                if (winners[j] == winners[i]) revert DuplicateWinner();
            }
        }

        uint256 fee = (b.amount * bountyFeeBps[bountyId]) / 10000;
        uint256 netPool = b.amount - fee;

        uint16[] storage shares = _sharesBps[bountyId];
        uint256 usedSharesBps;
        for (uint256 i = 0; i < winners.length; i++) {
            usedSharesBps += shares[i];
        }

        uint256 totalDistributed;
        for (uint256 i = 0; i < winners.length; i++) {
            uint256 reward = (netPool * shares[i]) / usedSharesBps;
            winnerRewards[bountyId][winners[i]] = reward;
            totalDistributed += reward;
        }

        uint256 dust = netPool - totalDistributed;
        if (dust > 0) winnerRewards[bountyId][winners[0]] += dust;

        _winners[bountyId] = winners;
        _winnerScores[bountyId] = scores;
        b.status = BountyStatus.Resolved;
        bountyBalance[bountyId] -= fee;

        if (fee > 0) IERC20(b.token).safeTransfer(treasury, fee);

        emit WinnersReported(bountyId, winners, scores);
    }

    /// @notice Oracle reports the frozen reveal set and bundle price after deadline
    function reportRevealSet(
        uint256 bountyId,
        address[] calldata revealedSolvers,
        uint16[] calldata revealShares,
        uint256 bundlePrice
    ) external nonReentrant whenNotPaused {
        if (msg.sender != oracle) revert OnlyOracle();
        Bounty storage b = _bounties[bountyId];
        if (b.poster == address(0)) revert BountyNotActive();
        if (b.status == BountyStatus.Cancelled) revert BountyNotActive();
        if (block.timestamp < b.deadline) revert DeadlineNotReached();
        if (bundlePrice == 0) revert RevealBundlePriceZero();
        if (_revealSolvers[bountyId].length != 0) revert RevealAlreadyReported();
        if (revealedSolvers.length == 0 || revealedSolvers.length != revealShares.length) revert InvalidRevealSet();

        uint256 totalShares;
        for (uint256 i = 0; i < revealedSolvers.length; i++) {
            address solver = revealedSolvers[i];
            if (solver == address(0)) revert ZeroAddressRevealSolver();
            if (_isRevealSolver[bountyId][solver]) revert DuplicateRevealSolver();
            _isRevealSolver[bountyId][solver] = true;
            _revealShareBpsBySolver[bountyId][solver] = revealShares[i];
            _revealSolvers[bountyId].push(solver);
            _revealSharesBps[bountyId].push(revealShares[i]);
            totalShares += revealShares[i];
        }

        if (totalShares != 10000) revert SharesMustSumTo10000();
        revealBundlePrice[bountyId] = bundlePrice;

        emit RevealSetReported(bountyId, revealedSolvers, revealShares, bundlePrice);
    }

    // ─── Winner Claim Functions ────────────────────────────────────────────────

    /// @notice Winner claims their reward in the bounty's original token
    function claimReward(uint256 bountyId) external nonReentrant whenNotPaused {
        _claimRewardFor(bountyId, msg.sender, address(0), 0);
    }

    /// @notice Winner claims reward, optionally swapping to a different TIP-20 via Tempo DEX
    /// @param claimToken   TIP-20 stablecoin to receive; address(0) = use bounty's original token
    /// @param minAmountOut Minimum acceptable output after DEX swap (slippage protection)
    function claimRewardWithSwap(
        uint256 bountyId,
        address claimToken,
        uint128 minAmountOut
    ) external nonReentrant whenNotPaused {
        _claimRewardFor(bountyId, msg.sender, claimToken, minAmountOut);
    }

    /// @notice Delegate or winner claims on behalf of the winner (original token)
    function claimRewardFor(uint256 bountyId, address winner) external nonReentrant whenNotPaused {
        if (msg.sender != winner && delegatedWallets[winner] != msg.sender) revert NotAuthorized();
        _claimRewardFor(bountyId, winner, address(0), 0);
    }

    /// @notice Delegate or winner claims on behalf of the winner, with optional DEX swap
    function claimRewardForWithSwap(
        uint256 bountyId,
        address winner,
        address claimToken,
        uint128 minAmountOut
    ) external nonReentrant whenNotPaused {
        if (msg.sender != winner && delegatedWallets[winner] != msg.sender) revert NotAuthorized();
        _claimRewardFor(bountyId, winner, claimToken, minAmountOut);
    }

    /// @dev Internal claim handler.
    ///      If claimToken is non-zero and different from the bounty token, the reward is swapped
    ///      via Tempo's enshrined DEX before being sent to the recipient.
    function _claimRewardFor(
        uint256 bountyId,
        address winner,
        address claimToken,
        uint128 minAmountOut
    ) internal {
        uint256 reward = winnerRewards[bountyId][winner];
        if (reward == 0) revert NotWinner();
        if (hasClaimed[bountyId][winner]) revert AlreadyClaimed();

        Bounty storage b = _bounties[bountyId];
        if (b.status != BountyStatus.Resolved) revert BountyNotActive();

        hasClaimed[bountyId][winner] = true;
        bountyBalance[bountyId] -= reward;

        address recipient = delegatedWallets[winner];
        if (recipient == address(0)) recipient = winner;

        address outToken = (claimToken == address(0)) ? b.token : claimToken;

        if (outToken != b.token) {
            // Validate the requested claim token is a valid Tempo TIP-20
            if (!TIP20_FACTORY.isTIP20(outToken)) revert ClaimTokenNotTIP20();

            // Approve DEX to spend reward (safe cast: stablecoin rewards with 6 decimals fit in uint128)
            uint128 rewardU128 = uint128(reward);
            IERC20(b.token).approve(address(STABLECOIN_DEX), reward);

            // Swap via Tempo's enshrined Stablecoin DEX precompile
            uint128 received = STABLECOIN_DEX.swapExactAmountIn(
                b.token,
                outToken,
                rewardU128,
                minAmountOut
            );

            // Reset approval (safety hygiene)
            IERC20(b.token).approve(address(STABLECOIN_DEX), 0);

            IERC20(outToken).safeTransfer(recipient, uint256(received));
            emit RewardClaimed(bountyId, winner, recipient, uint256(received), outToken);
        } else {
            IERC20(b.token).safeTransfer(recipient, reward);
            emit RewardClaimed(bountyId, winner, recipient, reward, b.token);
        }

        // Mark bounty Claimed once all winners have collected
        address[] storage winners = _winners[bountyId];
        bool allClaimed = true;
        for (uint256 i = 0; i < winners.length; i++) {
            if (!hasClaimed[bountyId][winners[i]]) {
                allClaimed = false;
                break;
            }
        }
        if (allClaimed) b.status = BountyStatus.Claimed;
    }

    // ─── Reveal Bundle Functions ───────────────────────────────────────────────

    /// @notice Buy permanent access to the frozen reveal bundle for a bounty.
    function buyRevealBundle(uint256 bountyId) external nonReentrant whenNotPaused {
        Bounty storage b = _bounties[bountyId];
        uint256 price = revealBundlePrice[bountyId];
        if (b.status == BountyStatus.Cancelled) revert BountyNotActive();
        if (price == 0) revert RevealNotReported();
        if (revealBundleAccess[bountyId][msg.sender]) revert DuplicateBuyer();

        uint256 fee = (price * revealFeeBps) / 10000;
        uint256 netPrice = price - fee;

        revealBundleAccess[bountyId][msg.sender] = true;
        totalRevealRevenue[bountyId] += netPrice;

        IERC20(b.token).safeTransferFrom(msg.sender, address(this), price);
        if (fee > 0) IERC20(b.token).safeTransfer(treasury, fee);

        emit RevealBundlePurchased(bountyId, msg.sender, price);
    }

    /// @notice Claim accrued reveal revenue for the caller
    function claimRevealRevenue(uint256 bountyId) external nonReentrant whenNotPaused {
        _claimRevealRevenueFor(bountyId, msg.sender);
    }

    /// @notice Delegate or solver claims reveal revenue on behalf of the solver
    function claimRevealRevenueFor(uint256 bountyId, address solver) external nonReentrant whenNotPaused {
        if (msg.sender != solver && delegatedWallets[solver] != msg.sender) revert NotAuthorized();
        _claimRevealRevenueFor(bountyId, solver);
    }

    function _claimRevealRevenueFor(uint256 bountyId, address solver) internal {
        if (!_isRevealSolver[bountyId][solver]) revert NotRevealSolver();

        uint256 accrued = getRevealRevenueAccrued(bountyId, solver);
        uint256 claimed = revealRevenueClaimed[bountyId][solver];
        if (accrued <= claimed) revert NothingToClaim();

        uint256 amount = accrued - claimed;
        revealRevenueClaimed[bountyId][solver] = accrued;

        address recipient = delegatedWallets[solver];
        if (recipient == address(0)) recipient = solver;

        Bounty storage b = _bounties[bountyId];
        IERC20(b.token).safeTransfer(recipient, amount);

        emit RevealRevenueClaimed(bountyId, solver, recipient, amount);
    }

    // ─── Delegation Functions ──────────────────────────────────────────────────

    /// @notice Set a delegate wallet to receive bounty rewards on your behalf.
    function setDelegateWallet(address delegate) external {
        delegatedWallets[msg.sender] = delegate;
        emit WalletDelegated(msg.sender, delegate);
    }

    function getDelegateWallet(address agent) external view returns (address) {
        address delegate = delegatedWallets[agent];
        return delegate == address(0) ? agent : delegate;
    }

    /// @notice Oracle batches pending delegations submitted via the API
    function batchSetDelegations(address[] calldata agents, address[] calldata delegates) external {
        if (msg.sender != oracle) revert OnlyOracle();
        if (agents.length != delegates.length) revert InvalidPayoutConfig();
        for (uint256 i = 0; i < agents.length; i++) {
            delegatedWallets[agents[i]] = delegates[i];
            emit WalletDelegated(agents[i], delegates[i]);
        }
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return _bounties[bountyId];
    }

    function getWinners(uint256 bountyId) external view returns (address[] memory, uint256[] memory) {
        return (_winners[bountyId], _winnerScores[bountyId]);
    }

    function getShares(uint256 bountyId) external view returns (uint16[] memory) {
        return _sharesBps[bountyId];
    }

    function getAllowedFeeTiers() external view returns (uint16[] memory) {
        return _allowedFeeTiers;
    }

    function getRevealSolvers(uint256 bountyId) external view returns (address[] memory, uint16[] memory) {
        return (_revealSolvers[bountyId], _revealSharesBps[bountyId]);
    }

    function getRevealRevenueAccrued(uint256 bountyId, address solver) public view returns (uint256) {
        uint16 shareBps = _revealShareBpsBySolver[bountyId][solver];
        if (shareBps == 0) return 0;
        return (totalRevealRevenue[bountyId] * uint256(shareBps)) / 10000;
    }

    function getRevealRevenueAvailable(uint256 bountyId, address solver) external view returns (uint256) {
        uint256 accrued = getRevealRevenueAccrued(bountyId, solver);
        uint256 claimed = revealRevenueClaimed[bountyId][solver];
        return accrued > claimed ? accrued - claimed : 0;
    }

    /// @notice Quote the output a winner would receive if swapping via the Tempo DEX
    function quoteClaimSwap(
        uint256 bountyId,
        address winner,
        address claimToken
    ) external view returns (uint128 amountOut) {
        uint256 reward = winnerRewards[bountyId][winner];
        if (reward == 0) return 0;
        Bounty storage b = _bounties[bountyId];
        if (claimToken == b.token) return uint128(reward);
        return STABLECOIN_DEX.quoteSwapExactAmountIn(b.token, claimToken, uint128(reward));
    }

    // ─── Admin Functions ───────────────────────────────────────────────────────

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        emit OracleUpdated(oracle, _oracle);
        oracle = _oracle;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setAllowedFeeTiers(uint16[] calldata tiers) external onlyOwner {
        for (uint256 i = 0; i < _allowedFeeTiers.length; i++) {
            isAllowedFeeTier[_allowedFeeTiers[i]] = false;
        }
        delete _allowedFeeTiers;
        for (uint256 i = 0; i < tiers.length; i++) {
            if (tiers[i] > MAX_FEE_BPS) revert FeeTooHigh();
            isAllowedFeeTier[tiers[i]] = true;
            _allowedFeeTiers.push(tiers[i]);
        }
        emit FeeTiersUpdated(tiers);
    }

    function setCancelPenalty(uint256 _penaltyBps) external onlyOwner {
        if (_penaltyBps > MAX_CANCEL_PENALTY_BPS) revert FeeTooHigh();
        emit CancelPenaltyUpdated(cancelPenaltyBps, _penaltyBps);
        cancelPenaltyBps = _penaltyBps;
    }

    function setRevealFeeBps(uint16 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit RevealFeeBpsUpdated(revealFeeBps, _feeBps);
        revealFeeBps = _feeBps;
    }

    function renounceOwnership() public pure override {
        revert("Ownership renouncement disabled");
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
