// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// =============================================================
// AMMRiskBase — Abstract base: all risk state + guard functions
// Extracted from FiatStablecoinAMMV2 to reduce deploy size
// =============================================================

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./FiatAMMErrorsLib.sol";
import "./FiatAMMStorage.sol";

abstract contract FiatAMMRiskBase3 {


    // -------------------------------------------------------
    // EPOCH LIMITER STATE
    // -------------------------------------------------------

    //mapping(uint256 => DailyStats) public dailyStats;

    mapping(address => uint256) public epochVolumeUSD;
    mapping(address => uint256) public epochVolumeLCY;
    mapping(address => uint256) public epochStart;

    uint256 public epochDuration     = 1 hours;
    uint256 public maxEpochVolumeBps = 5000; // 50% of pool per user per epoch

    // -------------------------------------------------------
    // SWAP SIZE CAP STATE
    // -------------------------------------------------------

    uint256 public maxSwapBps               = 1000; // 10% of pool
    bool    public swapCheckEnabled         = true;
    uint256 public swapCheckOverrideExpiry;

    uint256 public constant MIN_SWAP_BPS            = 10;   // 0.1%
    uint256 public constant MAX_SWAP_BPS_CAP        = 2000; // 20%
    uint256 public constant MAX_SWAP_CHECK_OVERRIDE = 1 hours;

    // -------------------------------------------------------
    // BLOCK SPAM STATE
    // -------------------------------------------------------

    mapping(address => uint256) public lastTradeBlock;

    // -------------------------------------------------------
    // LIQUIDITY SHOCK STATE
    // -------------------------------------------------------

    mapping(address => uint256) public liquidityHighWaterMark;
    mapping(address => uint256) public liquidityWindowStart;

    uint256 public drainObservationWindow       = 1 hours;
    uint256 public constant MAX_LIQUIDITY_DRAIN_BPS = 1000; // 10%

    // -------------------------------------------------------
    // PAUSE STATE
    // -------------------------------------------------------

    bool    public swapsPaused;
    uint256 public pauseTimestamp;
    uint256 public constant PAUSE_COOLDOWN = 15 minutes;

    uint256 public pendingPrice;
    uint256 public priceActiveAt;
    uint256 public priceUpdateDelay = 60; // seconds; owner-adjustable

    uint256 public lastPriceUpdate;
    uint256 public maxPriceAge = 2 hours; // owner-adjustable

    uint256 public constant MAX_PRICE_DEVIATION_BPS = 500; // 5%
    uint256 public lastSafePrice;

    uint256 public MIN_TRADE_USD            = 7_000;        // $0.007
    uint256 public MIN_TRADE_LCY            = 1_000_000;   // 1 LCY


    // -------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------

    event SwapsPaused(uint256 value, uint256 deviationBps);
    event SwapsResumed(address by);
    event SwapCheckEnabled(address indexed by);
    event SwapCheckDisabled(address indexed by, uint256 expiresAt);
    event MaxSwapBpsUpdated(uint256 oldBps, uint256 newBps);
    event EpochParamsUpdated(uint256 duration, uint256 maxBps);
    event DrainWindowUpdated(uint256 oldWindow, uint256 newWindow);


    // -------------------------------------------------------
    // GUARD — EPOCH RATE LIMITER
    // -------------------------------------------------------

    /// @dev Resets per-epoch counters when the window rolls over, then
    ///      accumulates volume and enforces the per-user epoch cap.
    ///      isUSD=true tracks USD leg; isUSD=false tracks LCY leg.
    function _checkEpochLimit(
        address user,
        uint256 amount,
        uint256 pool,
        bool    isUSD
    ) internal {
        if (block.timestamp >= epochStart[user] + epochDuration) {
            epochStart[user]     = block.timestamp;
            epochVolumeUSD[user] = 0;
            epochVolumeLCY[user] = 0;
        }

        uint256 cap = Math.mulDiv(pool, maxEpochVolumeBps, 10_000);

        if (isUSD) {
            epochVolumeUSD[user] += amount;
            if (epochVolumeUSD[user] > cap) revert EpochUSDCapExceeded();
        } else {
            epochVolumeLCY[user] += amount;
            if (epochVolumeLCY[user] > cap) revert EpochLCYCapExceeded();
        }
    }

    // -------------------------------------------------------
    // GUARD — SWAP SIZE CAP
    // -------------------------------------------------------

    /// @dev Auto-expires any temporary override so the cap re-engages
    ///      even if the owner key is unavailable after a disable.
    function _checkSwapSize(uint256 amount, uint256 pool) internal {
        if (
            !swapCheckEnabled &&
            swapCheckOverrideExpiry != 0 &&
            block.timestamp >= swapCheckOverrideExpiry
        ) {
            swapCheckEnabled        = true;
            swapCheckOverrideExpiry = 0;
            emit SwapCheckEnabled(address(0)); // address(0) signals auto-expiry
        }

        if (!swapCheckEnabled || pool == 0) return;

        uint256 cap = Math.mulDiv(pool, maxSwapBps, 10_000);
        if (amount > cap) revert SwapTooLarge();
    }

    // -------------------------------------------------------
    // GUARD — BLOCK SPAM
    // -------------------------------------------------------

    function _checkBlockSpam(address user) internal {
        require(lastTradeBlock[user] != block.number, "OneTradePerBlock");
        lastTradeBlock[user] = block.number;
    }

    // -------------------------------------------------------
    // GUARD — LIQUIDITY SHOCK
    // -------------------------------------------------------

    /// @dev Tracks cumulative pool drain within an observation window using
    ///      a high-water mark. Pauses swaps if drain exceeds MAX_LIQUIDITY_DRAIN_BPS.
    function _checkLiquidityShock(address token, uint256 currentPool) internal {
        uint256 hwm         = liquidityHighWaterMark[token];
        uint256 windowStart = liquidityWindowStart[token];

        // Bootstrap: first call for this token
        if (hwm == 0) {
            liquidityHighWaterMark[token] = currentPool;
            liquidityWindowStart[token]   = block.timestamp;
            return;
        }

        bool windowExpired = block.timestamp >= windowStart + drainObservationWindow;

        if (windowExpired) {
            // Recovery gate: pool must be within MAX_LIQUIDITY_DRAIN_BPS of HWM
            // before the window resets. Otherwise the window extends.
            uint256 recoveryBps       = Math.mulDiv(currentPool, 10_000, hwm);
            uint256 recoveryThreshold = 10_000 - MAX_LIQUIDITY_DRAIN_BPS;

            if (recoveryBps >= recoveryThreshold) {
                liquidityHighWaterMark[token] = currentPool;
                liquidityWindowStart[token]   = block.timestamp;
                return;
            }
            // Pool still depressed — extend window, fall through to drain check
        }

        // Raise HWM if pool has grown (LP deposit within window)
        if (currentPool > hwm) {
            liquidityHighWaterMark[token] = currentPool;
            return; // pool grew, no drain to check
        }

        // Measure cumulative drain from window peak
        uint256 drainBps = Math.mulDiv(hwm - currentPool, 10_000, hwm);

        if (drainBps > MAX_LIQUIDITY_DRAIN_BPS) {
            swapsPaused    = true;
            pauseTimestamp = block.timestamp;
            emit SwapsPaused(currentPool, drainBps);
        }
    }

    // -------------------------------------------------------
    // GUARD — LIQUIDITY RECOVERED (used by autoUnpause)
    // -------------------------------------------------------

    /*function _checkLiquidityRecovered(
        uint256 usdPool,
        uint256 lcyPool,
        uint256 minUSD,
        uint256 minLCY,
        address usdAddr,
        address lcyAddr
    ) internal view returns (bool) {
        if (usdPool < minUSD || lcyPool < minLCY) return false;

        uint256 hwmUSD = liquidityHighWaterMark[usdAddr];
        uint256 hwmLCY = liquidityHighWaterMark[lcyAddr];

        if (hwmUSD == 0 && hwmLCY == 0) return true;

        uint256 maxDrain;

        if (hwmUSD > 0) {
            uint256 d = hwmUSD > usdPool
                ? Math.mulDiv(hwmUSD - usdPool, 10_000, hwmUSD)
                : 0;
            if (d > maxDrain) maxDrain = d;
        }

        if (hwmLCY > 0) {
            uint256 d = hwmLCY > lcyPool
                ? Math.mulDiv(hwmLCY - lcyPool, 10_000, hwmLCY)
                : 0;
            if (d > maxDrain) maxDrain = d;
        }

        return maxDrain <= MAX_LIQUIDITY_DRAIN_BPS;
    }*/

    // -------------------------------------------------------
    // ADMIN SETTERS (delegated from onlyOwner in main contract)
    // -------------------------------------------------------

    function _setEpochParams(uint256 _duration, uint256 _maxBps) internal {
        if (_maxBps > 10_000) revert ExceedsDenom();
        epochDuration     = _duration;
        maxEpochVolumeBps = _maxBps;
        emit EpochParamsUpdated(_duration, _maxBps);
    }

    function _setMaxSwapBps(uint256 _bps) internal {
        if (_bps < MIN_SWAP_BPS)     revert SwapCapBelowMin();
        if (_bps > MAX_SWAP_BPS_CAP) revert SwapCapAboveMax();
        uint256 old = maxSwapBps;
        maxSwapBps  = _bps;
        emit MaxSwapBpsUpdated(old, _bps);
    }

    function _setDrainWindow(uint256 _window) internal {
        if (_window < 15 minutes || _window > 24 hours) revert InvalidWindow();
        uint256 old            = drainObservationWindow;
        drainObservationWindow = _window;
        emit DrainWindowUpdated(old, _window);
    }

    function _disableSwapCheck(uint256 duration) internal {
        if (duration == 0)                           revert ZeroDuration();
        if (duration > MAX_SWAP_CHECK_OVERRIDE)      revert DurationExceedsMax();
        swapCheckEnabled        = false;
        swapCheckOverrideExpiry = block.timestamp + duration;
        emit SwapCheckDisabled(msg.sender, swapCheckOverrideExpiry);
    }

    function _enableSwapCheck() internal {
        swapCheckEnabled        = true;
        swapCheckOverrideExpiry = 0;
        emit SwapCheckEnabled(msg.sender);
    }

    function percentDiff(uint256 a,uint256 b) internal pure returns (uint256) {
        if (a == 0 && b == 0) return 0;

        uint256 diff = a > b ? a - b : b - a;
        uint256 maxVal = a > b ? a : b;
        return Math.mulDiv(diff, 100, maxVal);
    }

    /*function fetchLPPositionStats(address lp,address fee)
        external view
        returns (
            uint256 shareLCY, uint256 shareUSD,
            uint256 totalShareLCY, uint256 totalShareUSD
        )
    {
        //if (address(feeVault).code.length == 0) revert FeeVaultNotContract();
        IFiatFeeVault feeVault = IFiatFeeVault(fee);
        shareLCY      = feeVault.shares(address(cLCY), lp);
        shareUSD      = feeVault.shares(address(USD),  lp);
        totalShareLCY = feeVault.totalShares(address(cLCY));
        totalShareUSD = feeVault.totalShares(address(USD));
       
    }*/

    /*function getTodayStats()
        external
        view
        returns (
            uint256 swapVolumeLCY,
            uint256 swapVolumeUSD,
            uint256 swapCountLCY,
            uint256 swapCountUSD,
            uint256 lpFeeUSD,
            uint256 lpFeeLCY,
            uint256 platformFeeUSD,
            uint256 platformFeeLCY,
            uint256 liquidityAddedUSD,
            uint256 liquidityAddedLCY,
            uint256 liquidityRemovedUSD,
            uint256 liquidityRemovedLCY
        )
    {
        //uint256 dayNumber = block.timestamp / 1 days;
        uint256 dayNumber = today();
        DailyStats storage stats = dailyStats[dayNumber];

        return (
            stats.swapVolumeLCY,
            stats.swapVolumeUSD,
            stats.swapCountLCY,
            stats.swapCountUSD,
            stats.lpFeeUSD,
            stats.lpFeeLCY,
            stats.platformFeeUSD,
            stats.platformFeeLCY,
            stats.liquidityAddedUSD,
            stats.liquidityAddedLCY,
            stats.liquidityRemovedUSD,
            stats.liquidityRemovedLCY
        );
    }*/

    function getRiskParams()
        external view
        returns (
            uint256 _pendingPrice,
            uint256 _priceActiveAt,
            uint256 _priceUpdateDelay,
            uint256 _lastPriceUpdate,
            uint256 _maxPriceAge,
            uint256 _maxEpochVolumeBps,
            bool    _swapsPaused,
            uint256 _lastSafePrice,
            uint256 _pauseTimestamp,
            uint256 _pauseCooldown,
            uint256 _maxLiquidityDrainBps,
            uint256 _maxSwapBps,
            uint256 _minTradeUSD,
            uint256 _minTradeCNGN
        )
    {
        return (
            pendingPrice,
            priceActiveAt,
            priceUpdateDelay,
            lastPriceUpdate,
            maxPriceAge,
            maxEpochVolumeBps,
            swapsPaused,
            lastSafePrice,
            pauseTimestamp,
            PAUSE_COOLDOWN,
            MAX_LIQUIDITY_DRAIN_BPS,
            maxSwapBps,
            MIN_TRADE_USD,
            MIN_TRADE_LCY
        );
    }

    
}
