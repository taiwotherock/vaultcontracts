// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title  FiatStablecoinAMMFee
 * @notice Tracks per-LP fee entitlements using a reward-per-share accumulator.
 *         Prevents the pro-rata timing attack present in naive fee pools.
 *
 * Pattern: Synthetix StakingRewards / MasterChef
 *
 * rewardPerShareStored grows monotonically as fees arrive.
 * Each LP's pending claim = shares * (rewardPerShareStored - rewardPerSharePaid[lp])
 *
 * Security changes vs original:
 *   [FIX-V1] Math.mulDiv in depositFee, _settle, pendingClaim — prevents
 *            intermediate overflow on large (amount * PRECISION) products.
 *   [FIX-V2] updateShares uses explicit delta logic with checked sub/add
 *            rather than totalShares - old + new, preventing underflow
 *            if state is ever inconsistent.
 *   [FIX-V3] emergencySweep validates `to != address(0)`.
 *   [FIX-V4] setAMM emits AMMUpdated event for on-chain traceability.
 *   [FIX-V5] Constructor error messages added to all require statements.
 *   [FIX-V6] claimFor nonReentrant guard preserved; no state changes
 *            after external safeTransfer (CEI ordering).
 */
contract FiatStablecoinAMMFeeV6 is Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // -------------------------------------------------------
    // PRECISION
    // -------------------------------------------------------

    /// @dev Precision multiplier — large enough to avoid truncation
    ///      on small fee amounts relative to large share totals.
    uint256 public constant PRECISION = 1e18;

    // -------------------------------------------------------
    // STATE
    // -------------------------------------------------------

    /// @dev The AMM contract authorised to call depositFee / updateShares / claimFor.
    address public amm;

    // token => accumulated reward per share (scaled by PRECISION)
    mapping(address => uint256) public rewardPerShareStored;

    // token => lp => reward-per-share snapshot at last settlement
    mapping(address => mapping(address => uint256)) public rewardPerSharePaid;

    // token => lp => pending rewards not yet transferred
    mapping(address => mapping(address => uint256)) public pendingRewards;

    // token => lp => share balance (mirrors AMM's internal accounting)
    mapping(address => mapping(address => uint256)) public shares;

    // token => total shares outstanding
    mapping(address => uint256) public totalShares;

    // -------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------

    event FeeDeposited(address indexed token, uint256 amount);
    event SharesUpdated(address indexed lp, address indexed token, uint256 newShares);
    event Claimed(address indexed lp, address indexed token, uint256 amount);
    event AMMUpdated(address indexed newAMM); // FIX-V4

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    constructor(address _amm) Ownable(msg.sender) {
        require(_amm != address(0), "zero address"); // FIX-V5
        amm = _amm;
    }

    // -------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------

    modifier onlyAMM() {
        require(msg.sender == amm, "only AMM");
        _;
    }

    // -------------------------------------------------------
    // AMM-FACING: called by FiatStablecoinAMM
    // -------------------------------------------------------

    /**
     * @notice Called by AMM when swap fees are generated.
     *         Tokens must be transferred to this contract BEFORE calling this.
     *         If no LPs are active (totalShares == 0) the fee sits idle in
     *         the vault until the first LP deposits.
     */
    function depositFee(address token, uint256 amount) external onlyAMM {
        if (amount == 0 || totalShares[token] == 0) return;

        // FIX-V1: Math.mulDiv prevents overflow when amount * PRECISION
        //         exceeds uint256 max on large fee amounts.
        rewardPerShareStored[token] += Math.mulDiv(amount, PRECISION, totalShares[token]);
        emit FeeDeposited(token, amount);
    }

    /**
     * @notice Called by AMM whenever an LP's share balance changes.
     *         MUST be called BEFORE the share change takes effect so
     *         the LP's accrued rewards are snapshotted at the current
     *         rate, not the post-change rate.
     */
    function updateShares(
        address lp,
        address token,
        uint256 newShares
    )
        external onlyAMM
    {
        // Settle existing accrual at current rate BEFORE changing balance
        _settle(lp, token);

        // FIX-V2: Explicit delta arithmetic — avoids totalShares underflow
        //         if old shares somehow exceed current totalShares.
        uint256 oldShares = shares[token][lp];
        if (newShares > oldShares) {
            totalShares[token] += (newShares - oldShares);
        } else {
            totalShares[token] -= (oldShares - newShares);
        }

        shares[token][lp] = newShares;
        emit SharesUpdated(lp, token, newShares);
    }

    // -------------------------------------------------------
    // CLAIM
    // -------------------------------------------------------

    /// @notice LP claims their own accumulated fees directly.
    function claim(address token) external nonReentrant {
        _settle(msg.sender, token);
        uint256 owed = pendingRewards[token][msg.sender];
        if (owed == 0) return;
        // CEI: zero before transfer
        pendingRewards[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, owed);
        emit Claimed(msg.sender, token, owed);
    }

    /// @notice AMM claims on behalf of an LP (used by metaClaimLPFee).
    function claimFor(address lp, address token) external onlyAMM nonReentrant {
        _settle(lp, token);
        uint256 owed = pendingRewards[token][lp];
        if (owed == 0) return;
        // CEI: zero before transfer
        pendingRewards[token][lp] = 0;
        IERC20(token).safeTransfer(lp, owed);
        emit Claimed(lp, token, owed);
    }

    // -------------------------------------------------------
    // VIEW
    // -------------------------------------------------------

    /// @notice Returns total pending claim for `lp` including unsettled accrual.
    function pendingClaim(address lp, address token) external view returns (uint256) {
        uint256 unpaid = rewardPerShareStored[token] - rewardPerSharePaid[token][lp];
        // FIX-V1: Math.mulDiv prevents overflow in view function too
        return pendingRewards[token][lp] + Math.mulDiv(shares[token][lp], unpaid, PRECISION);
    }

    /// @notice Returns total pending claim for `lp` including unsettled accrual.
    function getLPStats(address lp, address token) external view returns
     (uint256 totalReward, uint256 totalPaid, uint256 totalUnPaid, uint256 totalPendingClaim,
        uint256 shareReward, uint256 totalShare, uint256 lpShare) {
        totalUnPaid = rewardPerShareStored[token] - rewardPerSharePaid[token][lp];
        totalReward = rewardPerShareStored[token];
        totalPaid = rewardPerSharePaid[token][lp];
        totalPendingClaim = pendingRewards[token][lp];
        shareReward = Math.mulDiv(shares[token][lp], totalUnPaid, PRECISION);
        totalShare = totalShares[token];
        lpShare = shares[token][lp];
    }

    // -------------------------------------------------------
    // INTERNAL
    // -------------------------------------------------------

    /// @dev Snapshot the LP's accrued rewards at the current rewardPerShare.
    ///      Always advances the paid cursor even if shares == 0, to prevent
    ///      a future deposit from claiming historical fees.
    function _settle(address lp, address token) internal {
        uint256 unpaid = rewardPerShareStored[token] - rewardPerSharePaid[token][lp];
        if (unpaid > 0 && shares[token][lp] > 0) {
            // FIX-V1: Math.mulDiv prevents overflow
            pendingRewards[token][lp] += Math.mulDiv(shares[token][lp], unpaid, PRECISION);
        }
        // Always advance cursor to prevent double-counting on future deposits
        rewardPerSharePaid[token][lp] = rewardPerShareStored[token];
    }

    // -------------------------------------------------------
    // ADMIN
    // -------------------------------------------------------

    function setAMM(address _amm) external onlyOwner {
        require(_amm != address(0), "zero address"); // FIX-V5
        amm = _amm;
        emit AMMUpdated(_amm); // FIX-V4
    }

    /**
     * @notice Emergency sweep — should never be needed in normal operation.
     *         Allows recovery of tokens accidentally sent directly to vault.
     */
    function emergencySweep(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero address"); // FIX-V3
        IERC20(token).safeTransfer(to, amount);
    }
}
