// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface ITIP20Factory {
    function isTIP20(address token) external view returns (bool);
}

interface ITIP20Metadata {
    function currency() external view returns (string memory);
}

interface IStablecoinDEX {
    function swapExactAmountIn(
        address tokenIn,
        address tokenOut,
        uint128 amountIn,
        uint128 minAmountOut
    ) external returns (uint128 amountOut);

    function quoteSwapExactAmountIn(
        address tokenIn,
        address tokenOut,
        uint128 amountIn
    ) external view returns (uint128 amountOut);
}

contract ClankonBounty is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    ITIP20Factory public immutable factory;
    IStablecoinDEX public immutable dex;
    address public immutable oracle;
    address public immutable treasury;
    address public immutable pathUSD;

    uint256 public constant MINAMOUNT = 1_000_000;
    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant MAX_DURATION = 90 days;
    uint256 public constant GRACE_PERIOD = 7 days;
    uint8 public constant MAX_WINNERS = 3;
    uint16 public constant MAXFEEBPS = 1000;
    uint16 public constant MAXCANCELPENALTY_BPS = 10000;

    error ZeroAddress();
    error NotTIP20();
    error NotUSD();
    error AmountTooLow();
    error DeadlineTooSoon();
    error DeadlineTooFar();
    error InvalidPayoutConfig();
    error SharesMustSumTo10000();
    error TooManyWinners();
    error NotOracle();
    error NotPoster();
    error NotWinner();
    error AlreadyClaimed();
    error NotResolved();
    error NotActive();
    error NothingToClaim();
    error RevealAlreadyReported();
    error RevealNotReported();
    error DuplicateBuyer();
    error NotRevealSolver();
    error ClaimTokenNotTIP20();
    error InvalidFeeTier();
    error FeeTooHigh();
    error Unauthorized();
    error SlippageTooHigh();

    enum BountyStatus {
        None,
        Active,
        Resolved,
        Claimed,
        Cancelled
    }

    struct Bounty {
        address poster;
        address token;
        uint128 amount;
        uint48 deadline;
        uint16 feeBps;
        uint8 numWinners;
        uint8 status;
        bytes32 evalHash;
        string metadataURI;
    }

    mapping(uint256 => Bounty) internal _bounties;
    mapping(uint256 => uint16[]) internal _sharesBps;
    mapping(uint256 => address[]) internal _winners;
    mapping(uint256 => uint256[]) internal _winnerScores;
    mapping(uint256 => mapping(address => uint256)) public winnerRewards;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(uint256 => uint256) public bountyBalance;

    mapping(uint256 => address[]) internal _revealSolvers;
    mapping(uint256 => uint16[]) internal _revealSharesBps;
    mapping(uint256 => mapping(address => bool)) internal _isRevealSolver;
    mapping(uint256 => mapping(address => uint16)) internal _revealShareBpsBySolver;
    mapping(uint256 => mapping(address => bool)) public revealBundleAccess;
    mapping(uint256 => mapping(address => uint256)) public revealRevenueClaimed;
    mapping(uint256 => uint256) public revealBundlePrice;
    mapping(uint256 => uint256) public totalRevealRevenue;

    mapping(address => address) public delegatedWallets;
    mapping(uint256 => uint16) public bountyFeeBps;

    uint16[] internal _allowedFeeTiers;
    mapping(uint16 => bool) public isAllowedFeeTier;
    uint16 public revealFeeBps = 500;
    uint256 public cancelPenaltyBps = 8000;
    uint256 public nextBountyId;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed poster,
        address indexed token,
        uint128 amount,
        uint48 deadline,
        uint8 numWinners,
        uint16 feeBps,
        bytes32 evalHash,
        string metadataURI
    );
    event WinnersReported(uint256 indexed bountyId, address[] winners, uint256[] scores, uint256 feeTaken);
    event RewardClaimed(uint256 indexed bountyId, address indexed winner, address indexed recipient, uint256 reward, address claimToken);
    event WalletDelegated(address indexed agent, address indexed delegate);
    event BountyCancelled(uint256 indexed bountyId, address indexed poster, uint256 refund, uint256 penalty);
    event BountyReclaimed(uint256 indexed bountyId, address indexed poster, uint256 amount);
    event RevealSetReported(uint256 indexed bountyId, address[] revealedSolvers, uint16[] revealSharesBps, uint256 bundlePrice);
    event RevealBundlePurchased(uint256 indexed bountyId, address indexed buyer, uint256 price, uint256 fee, uint256 netPrice);
    event RevealRevenueClaimed(uint256 indexed bountyId, address indexed solver, address indexed recipient, uint256 amount);
    event FeeTiersUpdated(uint16[] tiers);
    event CancelPenaltyUpdated(uint256 oldPenalty, uint256 newPenalty);
    event RevealFeeBpsUpdated(uint16 oldFee, uint16 newFee);

    constructor(
        address _factory,
        address _dex,
        address _oracle,
        address _treasury,
        address _pathUSD,
        address _owner
    ) Ownable(_owner) {
        if (
            _factory == address(0) ||
            _dex == address(0) ||
            _oracle == address(0) ||
            _treasury == address(0) ||
            _pathUSD == address(0)
        ) revert ZeroAddress();

        factory = ITIP20Factory(_factory);
        dex = IStablecoinDEX(_dex);
        oracle = _oracle;
        treasury = _treasury;
        pathUSD = _pathUSD;

        _allowedFeeTiers.push(100);
        _allowedFeeTiers.push(250);
        _allowedFeeTiers.push(500);
        isAllowedFeeTier[100] = true;
        isAllowedFeeTier[250] = true;
        isAllowedFeeTier[500] = true;
    }

    function _isTempoUSDToken(address token) internal view returns (bool) {
        if (!factory.isTIP20(token)) return false;
        try ITIP20Metadata(token).currency() returns (string memory cur) {
            bytes memory c = bytes(cur);
            return c.length == 3 && c[0] == 0x55 && c[1] == 0x53 && c[2] == 0x44;
        } catch {
            return false;
        }
    }

    function _validateUSDToken(address token) internal view {
        if (!factory.isTIP20(token)) revert NotTIP20();
        if (!_isTempoUSDToken(token)) revert NotUSD();
    }

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
        _validateUSDToken(token);
        if (amount < MINAMOUNT) revert AmountTooLow();
        if (deadline < block.timestamp + MIN_DURATION) revert DeadlineTooSoon();
        if (deadline > block.timestamp + MAX_DURATION) revert DeadlineTooFar();
        if (numWinners == 0 || numWinners > MAX_WINNERS) revert InvalidPayoutConfig();
        if (sharesBps.length != numWinners) revert InvalidPayoutConfig();
        if (!isAllowedFeeTier[feeBps]) revert InvalidFeeTier();

        uint256 totalShares;
        unchecked {
            for (uint256 i; i < sharesBps.length; ++i) {
                totalShares += sharesBps[i];
            }
        }
        if (totalShares != 10000) revert SharesMustSumTo10000();

        bountyId = nextBountyId;
        unchecked {
            nextBountyId = bountyId + 1;
        }

        Bounty storage b = _bounties[bountyId];
        b.poster = msg.sender;
        b.token = token;
        b.amount = uint128(amount);
        b.deadline = uint48(deadline);
        b.feeBps = feeBps;
        b.numWinners = numWinners;
        b.status = uint8(BountyStatus.Active);
        b.evalHash = evalHash;
        b.metadataURI = metadataURI;

        _sharesBps[bountyId] = sharesBps;
        bountyFeeBps[bountyId] = feeBps;
        bountyBalance[bountyId] = amount;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit BountyCreated(bountyId, msg.sender, token, uint128(amount), uint48(deadline), numWinners, feeBps, evalHash, metadataURI);
    }

    function cancelBounty(uint256 bountyId) external nonReentrant whenNotPaused {
        Bounty storage b = _bounties[bountyId];
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != uint8(BountyStatus.Active)) revert NotActive();
        if (block.timestamp >= b.deadline) revert DeadlineTooSoon();

        uint256 balance = bountyBalance[bountyId];
        uint256 penalty = (balance * cancelPenaltyBps) / 10000;
        uint256 refund = balance - penalty;

        bountyBalance[bountyId] = 0;
        b.status = uint8(BountyStatus.Cancelled);

        if (refund != 0) IERC20(b.token).safeTransfer(b.poster, refund);
        if (penalty != 0) IERC20(b.token).safeTransfer(treasury, penalty);

        emit BountyCancelled(bountyId, b.poster, refund, penalty);
    }

    function reclaimBounty(uint256 bountyId) external nonReentrant {
        Bounty storage b = _bounties[bountyId];
        if (msg.sender != b.poster) revert NotPoster();
        if (b.status != uint8(BountyStatus.Active) && b.status != uint8(BountyStatus.Resolved)) revert NotActive();
        if (block.timestamp < uint256(b.deadline) + GRACE_PERIOD) revert DeadlineTooSoon();

        uint256 balance = bountyBalance[bountyId];
        bountyBalance[bountyId] = 0;
        b.status = uint8(BountyStatus.Cancelled);

        if (balance != 0) IERC20(b.token).safeTransfer(b.poster, balance);

        emit BountyReclaimed(bountyId, b.poster, balance);
    }

    function reportWinners(
        uint256 bountyId,
        address[] calldata winners,
        uint256[] calldata scores
    ) external nonReentrant whenNotPaused {
        if (msg.sender != oracle) revert NotOracle();

        Bounty storage b = _bounties[bountyId];
        if (b.status != uint8(BountyStatus.Active)) revert NotActive();
        if (block.timestamp < uint256(b.deadline)) revert NotActive();
        if (winners.length == 0 || winners.length > b.numWinners) revert TooManyWinners();
        if (winners.length != scores.length) revert InvalidPayoutConfig();

        unchecked {
            for (uint256 i; i < winners.length; ++i) {
                if (winners[i] == address(0)) revert ZeroAddress();
                for (uint256 j; j < i; ++j) {
                    if (winners[i] == winners[j]) revert InvalidPayoutConfig();
                }
            }
        }

        uint16 feeBps = bountyFeeBps[bountyId];
        uint256 fee = (uint256(b.amount) * feeBps) / 10000;
        uint256 netPool = uint256(b.amount) - fee;

        uint16[] storage shares = _sharesBps[bountyId];
        uint256 usedShares;
        unchecked {
            for (uint256 i; i < winners.length; ++i) {
                usedShares += shares[i];
            }
        }
        if (usedShares == 0) revert InvalidPayoutConfig();

        uint256 totalDistributed;
        unchecked {
            for (uint256 i; i < winners.length; ++i) {
                uint256 reward = (netPool * shares[i]) / usedShares;
                winnerRewards[bountyId][winners[i]] = reward;
                totalDistributed += reward;
            }
        }

        uint256 dust = netPool - totalDistributed;
        if (dust != 0) {
            winnerRewards[bountyId][winners[0]] += dust;
        }

        _winners[bountyId] = winners;
        _winnerScores[bountyId] = scores;
        b.status = uint8(BountyStatus.Resolved);
        bountyBalance[bountyId] -= fee;

        if (fee != 0) IERC20(b.token).safeTransfer(treasury, fee);

        emit WinnersReported(bountyId, _winners[bountyId], _winnerScores[bountyId], fee);
    }

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
        if (b.status != uint8(BountyStatus.Resolved)) revert NotResolved();

        hasClaimed[bountyId][winner] = true;
        bountyBalance[bountyId] -= reward;

        address recipient = delegatedWallets[winner];
        if (recipient == address(0)) recipient = winner;

        address outToken = claimToken == address(0) ? b.token : claimToken;
        uint256 payout;

        if (outToken != b.token) {
            _validateUSDToken(outToken);
            if (reward > type(uint128).max) revert SlippageTooHigh();
            IERC20(b.token).approve(address(dex), reward);
            uint128 received = dex.swapExactAmountIn(b.token, outToken, uint128(reward), minAmountOut);
            IERC20(b.token).approve(address(dex), 0);
            payout = uint256(received);
            IERC20(outToken).safeTransfer(recipient, payout);
        } else {
            payout = reward;
            IERC20(b.token).safeTransfer(recipient, payout);
        }

        emit RewardClaimed(bountyId, winner, recipient, payout, outToken);

        address[] storage winners = _winners[bountyId];
        bool allClaimed = true;
        unchecked {
            for (uint256 i; i < winners.length; ++i) {
                if (!hasClaimed[bountyId][winners[i]]) {
                    allClaimed = false;
                    break;
                }
            }
        }
        if (allClaimed) {
            b.status = uint8(BountyStatus.Claimed);
        }
    }

    function claimReward(uint256 bountyId) external nonReentrant whenNotPaused {
        _claimRewardFor(bountyId, msg.sender, address(0), 0);
    }

    function claimRewardFor(uint256 bountyId, address winner) external nonReentrant whenNotPaused {
        if (msg.sender != winner && delegatedWallets[winner] != msg.sender) revert Unauthorized();
        _claimRewardFor(bountyId, winner, address(0), 0);
    }

    function claimRewardWithSwap(
        uint256 bountyId,
        address claimToken,
        uint128 minAmountOut
    ) external nonReentrant whenNotPaused {
        _claimRewardFor(bountyId, msg.sender, claimToken, minAmountOut);
    }

    function claimRewardForWithSwap(
        uint256 bountyId,
        address winner,
        address claimToken,
        uint128 minAmountOut
    ) external nonReentrant whenNotPaused {
        if (msg.sender != winner && delegatedWallets[winner] != msg.sender) revert Unauthorized();
        _claimRewardFor(bountyId, winner, claimToken, minAmountOut);
    }

    function reportRevealSet(
        uint256 bountyId,
        address[] calldata revealedSolvers,
        uint16[] calldata revealShares,
        uint256 bundlePrice
    ) external nonReentrant whenNotPaused {
        if (msg.sender != oracle) revert NotOracle();

        Bounty storage b = _bounties[bountyId];
        if (b.status == uint8(BountyStatus.Cancelled)) revert NotActive();
        if (block.timestamp < uint256(b.deadline)) revert NotActive();
        if (bundlePrice == 0) revert InvalidPayoutConfig();
        if (_revealSolvers[bountyId].length != 0) revert RevealAlreadyReported();
        if (revealedSolvers.length == 0 || revealedSolvers.length != revealShares.length) revert InvalidPayoutConfig();

        uint256 totalShares;
        unchecked {
            for (uint256 i; i < revealedSolvers.length; ++i) {
                address solver = revealedSolvers[i];
                if (solver == address(0)) revert ZeroAddress();
                if (_isRevealSolver[bountyId][solver]) revert InvalidPayoutConfig();
                _isRevealSolver[bountyId][solver] = true;
                _revealSolvers[bountyId].push(solver);
                _revealSharesBps[bountyId].push(revealShares[i]);
                _revealShareBpsBySolver[bountyId][solver] = revealShares[i];
                totalShares += revealShares[i];
            }
        }

        if (totalShares != 10000) revert SharesMustSumTo10000();
        revealBundlePrice[bountyId] = bundlePrice;

        emit RevealSetReported(bountyId, _revealSolvers[bountyId], _revealSharesBps[bountyId], bundlePrice);
    }

    function buyRevealBundle(uint256 bountyId) external nonReentrant whenNotPaused {
        Bounty storage b = _bounties[bountyId];
        if (b.status == uint8(BountyStatus.Cancelled)) revert NotActive();
        uint256 price = revealBundlePrice[bountyId];
        if (price == 0) revert RevealNotReported();
        if (revealBundleAccess[bountyId][msg.sender]) revert DuplicateBuyer();

        uint256 fee = (price * revealFeeBps) / 10000;
        uint256 netPrice = price - fee;

        revealBundleAccess[bountyId][msg.sender] = true;
        totalRevealRevenue[bountyId] += netPrice;

        IERC20(b.token).safeTransferFrom(msg.sender, address(this), price);
        if (fee != 0) IERC20(b.token).safeTransfer(treasury, fee);

        emit RevealBundlePurchased(bountyId, msg.sender, price, fee, netPrice);
    }

    function getRevealRevenueAccrued(uint256 bountyId, address solver) public view returns (uint256) {
        uint16 shareBps = _revealShareBpsBySolver[bountyId][solver];
        if (shareBps == 0) return 0;
        return (totalRevealRevenue[bountyId] * uint256(shareBps)) / 10000;
    }

    function claimRevealRevenue(uint256 bountyId) external nonReentrant whenNotPaused {
        _claimRevealRevenueFor(bountyId, msg.sender);
    }

    function claimRevealRevenueFor(uint256 bountyId, address solver) external nonReentrant whenNotPaused {
        if (msg.sender != solver && delegatedWallets[solver] != msg.sender) revert Unauthorized();
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

    function setDelegateWallet(address delegate) external {
        delegatedWallets[msg.sender] = delegate;
        emit WalletDelegated(msg.sender, delegate);
    }

    function getDelegateWallet(address agent) external view returns (address) {
        address delegate = delegatedWallets[agent];
        return delegate == address(0) ? agent : delegate;
    }

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return _bounties[bountyId];
    }

    function getWinners(uint256 bountyId) external view returns (address[] memory, uint256[] memory) {
        return (_winners[bountyId], _winnerScores[bountyId]);
    }

    function getShares(uint256 bountyId) external view returns (uint16[] memory) {
        return _sharesBps[bountyId];
    }

    function getRevealSolvers(uint256 bountyId) external view returns (address[] memory, uint16[] memory) {
        return (_revealSolvers[bountyId], _revealSharesBps[bountyId]);
    }

    function getAllowedFeeTiers() external view returns (uint16[] memory) {
        return _allowedFeeTiers;
    }

    function quoteClaimSwap(
        uint256 bountyId,
        address winner,
        address claimToken
    ) external view returns (uint128 amountOut) {
        uint256 reward = winnerRewards[bountyId][winner];
        if (reward == 0) return 0;
        Bounty storage b = _bounties[bountyId];
        if (claimToken == address(0) || claimToken == b.token) return uint128(reward);
        if (!_isTempoUSDToken(claimToken)) revert ClaimTokenNotTIP20();
        return dex.quoteSwapExactAmountIn(b.token, claimToken, uint128(reward));
    }

    function setAllowedFeeTiers(uint16[] calldata tiers) external onlyOwner {
        uint16[] storage current = _allowedFeeTiers;
        unchecked {
            for (uint256 i; i < current.length; ++i) {
                isAllowedFeeTier[current[i]] = false;
            }
        }
        delete _allowedFeeTiers;

        unchecked {
            for (uint256 i; i < tiers.length; ++i) {
                uint16 tier = tiers[i];
                if (tier > MAXFEEBPS) revert FeeTooHigh();
                if (isAllowedFeeTier[tier]) {
                    // idempotent if duplicate tiers were supplied
                }
                isAllowedFeeTier[tier] = true;
                _allowedFeeTiers.push(tier);
            }
        }
        emit FeeTiersUpdated(tiers);
    }

    function setCancelPenalty(uint256 _penaltyBps) external onlyOwner {
        if (_penaltyBps > MAXCANCELPENALTY_BPS) revert FeeTooHigh();
        emit CancelPenaltyUpdated(cancelPenaltyBps, _penaltyBps);
        cancelPenaltyBps = _penaltyBps;
    }

    function setRevealFeeBps(uint16 _feeBps) external onlyOwner {
        if (_feeBps > MAXFEEBPS) revert FeeTooHigh();
        emit RevealFeeBpsUpdated(revealFeeBps, _feeBps);
        revealFeeBps = _feeBps;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function renounceOwnership() public pure override {
        revert("Ownership renouncement disabled");
    }
}
