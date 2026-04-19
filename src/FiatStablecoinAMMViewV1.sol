// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================
// FiatStablecoinAMM — View / Read-Only Dashboard
// This contract contains all read-only view functions for
// querying the AMM state without modifying blockchain state.
// =============================================================

import "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract FiatStablecoinAMMViewV1 {
    using Math for uint256;

    // -------------------------------------------------------
    // REQUIRED IMPLEMENTATION — Must be provided by main contract
    // -------------------------------------------------------

    function cNGNToken() internal view virtual returns (address);
    function USDToken() internal view virtual returns (address);
    function feeVaultAddr() internal view virtual returns (address);

    // Pool state
    function poolDeposits(address token) internal view virtual returns (uint256);
    function minLiquidity(address token) internal view virtual returns (uint256);
    function buyRate() internal view virtual returns (uint256);
    function sellRate() internal view virtual returns (uint256);
    function midPrice() internal view virtual returns (uint256);
    function lastPriceUpdate() internal view virtual returns (uint256);
    function maxPriceAge() internal view virtual returns (uint256);
    function pendingPrice() internal view virtual returns (uint256);
    function priceActiveAt() internal view virtual returns (uint256);
    function priceUpdateDelay() internal view virtual returns (uint256);
    function maxEpochVolumeBps() internal view virtual returns (uint256);
    function swapsPaused() internal view virtual returns (bool);
    function lastSafePrice() internal view virtual returns (uint256);
    function pauseTimestamp() internal view virtual returns (uint256);
    function PAUSE_COOLDOWN_CONST() internal view virtual returns (uint256);
    function MAX_LIQUIDITY_DRAIN_BPS_CONST() internal view virtual returns (uint256);
    function maxSwapBps() internal view virtual returns (uint256);
    function MIN_TRADE_USD() internal view virtual returns (uint256);
    function MIN_TRADE_CNGN() internal view virtual returns (uint256);
    function swapFeeBps() internal view virtual returns (uint256);
    function FEE_DENOM_CONST() internal view virtual returns (uint256);
    function lpShareBps() internal view virtual returns (uint256);
    function USD_SCALE_VAL() internal view virtual returns (uint256);
    function epochVolumeUSD(address user) internal view virtual returns (uint256);
    function epochVolumeCNGN(address user) internal view virtual returns (uint256);
    function epochStart(address user) internal view virtual returns (uint256);
    function epochDuration() internal view virtual returns (uint256);
    function liquidityHighWaterMark(address token) internal view virtual returns (uint256);
    function liquidityWindowStart(address token) internal view virtual returns (uint256);
    function drainObservationWindow() internal view virtual returns (uint256);
    function MIN_FEE_CONST() internal view virtual returns (uint256);
    function MAX_WITHDRAW_BPS_CONST() internal view virtual returns (uint256);

    struct DailyStats {
        uint256 swapVolumeNGN;
        uint256 swapVolumeUSD;
        uint256 swapCountNGN;
        uint256 swapCountUSD;
        uint256 lpFeeUSD;
        uint256 lpFeeCNGN;
        uint256 platformFeeUSD;
        uint256 platformFeeCNGN;
        uint256 liquidityAddedUSD;
        uint256 liquidityAddedCNGN;
        uint256 liquidityRemovedUSD;
        uint256 liquidityRemovedCNGN;
    }

    function dailyStats(uint256 dayId) internal view virtual returns (DailyStats memory);
    function today() internal view virtual returns (uint256);

    // All-time totals
    function totalSwapVolumeNGN() internal view virtual returns (uint256);
    function totalSwapVolumeUSD() internal view virtual returns (uint256);
    function totalSwapCountNGN() internal view virtual returns (uint256);
    function totalSwapCountUSD() internal view virtual returns (uint256);
    function totalLpFeeUSD() internal view virtual returns (uint256);
    function totalLpFeeCNGN() internal view virtual returns (uint256);
    function totalPlatformFeeUSD() internal view virtual returns (uint256);
    function totalPlatformFeeCNGN() internal view virtual returns (uint256);

    // Fee vault
    function pendingClaim(address lp, address token) internal view virtual returns (uint256);
    function shares(address token, address lp) internal view virtual returns (uint256);
    function totalShares(address token) internal view virtual returns (uint256);

    // Fee calculation
    function _calcFeeView(uint256 amount) internal view virtual returns (uint256 total, uint256 lpFee, uint256 platformFee);

    // Swap check view
    function _checkSwapSizeView(uint256 amount, uint256 pool) internal view virtual;

    

    // -------------------------------------------------------
    // VIEW HELPERS — POOL STATE
    // -------------------------------------------------------

    function getPoolDepth()
        external view
        returns (uint256 usdDepth, uint256 ngnDepth)
    {
        return (
            poolDeposits(USDToken()),
            poolDeposits(cNGNToken())
        );
    }

    function pendingLPClaim(address lp, address token)
        external view
        returns (uint256)
    {
        return pendingClaim(lp, token);
    }

    function currentRates()
        external view
        returns (uint256 buy, uint256 sell, uint256 mid, bool stale)
    {
        return (
            buyRate(),
            sellRate(),
            midPrice(),
            lastPriceUpdate() == 0 || block.timestamp > lastPriceUpdate() + maxPriceAge()
        );
    }

    function fetchLPPositionStats(address lp)
        external view
        returns (
            uint256 shareNGN,
            uint256 shareUSD,
            uint256 totalShareNGN,
            uint256 totalShareUSD,
            uint256 poolDepositNGN,
            uint256 poolDepositUSD
        )
    {
        shareNGN = shares(cNGNToken(), lp);
        shareUSD = shares(USDToken(), lp);
        totalShareNGN = totalShares(cNGNToken());
        totalShareUSD = totalShares(USDToken());
        poolDepositNGN = poolDeposits(cNGNToken());
        poolDepositUSD = poolDeposits(USDToken());
    }

    

    // -------------------------------------------------------
    // VIEW HELPERS — STATISTICS
    // -------------------------------------------------------

    function getDay(uint256 dayId)
        external view
        returns (DailyStats memory)
    {
        return dailyStats(dayId);
    }

    function isPaused() external view returns (bool) {
        return swapsPaused();
    }

    function getTodayStats()
        external view
        returns (DailyStats memory)
    {
        return dailyStats(today());
    }

    function getRangeStats(uint256 fromDay, uint256 toDay)
        external view
        returns (DailyStats memory agg)
    {
        require(toDay >= fromDay, "bad range");
        require(toDay - fromDay < 366, "range too wide");

        for (uint256 d = fromDay; d <= toDay; d++) {
            DailyStats memory s = dailyStats(d);
            agg.swapVolumeNGN        += s.swapVolumeNGN;
            agg.swapVolumeUSD        += s.swapVolumeUSD;
            agg.swapCountNGN         += s.swapCountNGN;
            agg.swapCountUSD         += s.swapCountUSD;
            agg.lpFeeUSD             += s.lpFeeUSD;
            agg.lpFeeCNGN            += s.lpFeeCNGN;
            agg.platformFeeUSD       += s.platformFeeUSD;
            agg.platformFeeCNGN      += s.platformFeeCNGN;
            agg.liquidityAddedUSD    += s.liquidityAddedUSD;
            agg.liquidityAddedCNGN   += s.liquidityAddedCNGN;
            agg.liquidityRemovedUSD  += s.liquidityRemovedUSD;
            agg.liquidityRemovedCNGN += s.liquidityRemovedCNGN;
        }
    }

    function getAllTimeStats()
        external view
        returns (
            uint256 volNGN,
            uint256 volUSD,
            uint256 countNGN,
            uint256 countUSD,
            uint256 lpFeeUSD_,
            uint256 lpFeeCNGN_,
            uint256 platformFeeUSD_,
            uint256 platformFeeCNGN_
        )
    {
        return (
            totalSwapVolumeNGN(),
            totalSwapVolumeUSD(),
            totalSwapCountNGN(),
            totalSwapCountUSD(),
            totalLpFeeUSD(),
            totalLpFeeCNGN(),
            totalPlatformFeeUSD(),
            totalPlatformFeeCNGN()
        );
    }

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
            pendingPrice(),
            priceActiveAt(),
            priceUpdateDelay(),
            lastPriceUpdate(),
            maxPriceAge(),
            maxEpochVolumeBps(),
            swapsPaused(),
            lastSafePrice(),
            pauseTimestamp(),
            PAUSE_COOLDOWN_CONST(),
            MAX_LIQUIDITY_DRAIN_BPS_CONST(),
            maxSwapBps(),
            MIN_TRADE_USD(),
            MIN_TRADE_CNGN()
        );
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    /*function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }*/

    function getEIP712Domain()
        external view
        returns (
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract
        )
    {
        return ("FiatStablecoinAMMV1", "1", block.chainid, address(this));
    }

    function getEpochStats(address user)
        external view
        returns (
            uint256 volumeUSD,
            uint256 volumeCNGN,
            uint256 startTime,
            uint256 capUSD,
            uint256 capCNGN,
            uint256 currentUSD,
            uint256 currentCNGN
        )
    {
        volumeUSD = epochVolumeUSD(user);
        volumeCNGN = epochVolumeCNGN(user);
        startTime = epochStart(user);

        uint256 usdPool = poolDeposits(USDToken());
        uint256 ngnPool = poolDeposits(cNGNToken());

        capUSD = usdPool.mulDiv(maxEpochVolumeBps(), FEE_DENOM_CONST());
        capCNGN = ngnPool.mulDiv(maxEpochVolumeBps(), FEE_DENOM_CONST());
        currentUSD = epochVolumeUSD(user);
        currentCNGN = epochVolumeCNGN(user);
    }

    function getLiquidityProtectionParams()
        external view
        returns (
            uint256 maxDrainBps,
            uint256 drainWindow,
            uint256 hwmUSD,
            uint256 hwmCNGN,
            uint256 windowStartUSD,
            uint256 windowStartCNGN
        )
    {
        maxDrainBps = MAX_LIQUIDITY_DRAIN_BPS_CONST();
        drainWindow = drainObservationWindow();
        hwmUSD = liquidityHighWaterMark(USDToken());
        hwmCNGN = liquidityHighWaterMark(cNGNToken());
        windowStartUSD = liquidityWindowStart(USDToken());
        windowStartCNGN = liquidityWindowStart(cNGNToken());
    }

    function getFeeParams()
        external view
        returns (
            uint256 swapFeeBps_,
            uint256 lpShareBps_,
            uint256 platformShareBps_,
            uint256 feeDenom
        )
    {
        swapFeeBps_ = swapFeeBps();
        lpShareBps_ = lpShareBps();
        platformShareBps_ = FEE_DENOM_CONST() - lpShareBps_;
        feeDenom = FEE_DENOM_CONST();
    }
}
