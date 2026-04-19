// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// =============================================================
// AMMRiskBase — Abstract base: all risk state + guard functions
// Extracted from FiatStablecoinAMMV2 to reduce deploy size
// =============================================================

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./FiatAMMStorage.sol";

interface IFiatAMM {
    function today() external view returns (uint256);
    function getDailyStats(uint256 day) external view returns (FiatAMMStorage.DailyStats memory);
    function poolDeposits(address token) external view returns (uint256);
    function minLiquidity(address token) external view returns (uint256);
}

interface IFiatFeeVault {
    function shares(address token, address user) external view returns (uint256);
    function totalShares(address token) external view returns (uint256);
}


contract FiatAMMReader3  {


    /*function getPoolDepth(address amm,address USD,address cLCY)
        external view
        returns (uint256 usdDepth, uint256 lcyDepth, uint256 minLiqUSD, uint256 minLiqLCY)
    {
        IFiatAMM target = IFiatAMM(amm);
        return (target.poolDeposits(address(USD)), target.poolDeposits(address(cLCY)),
         target.minLiquidity(address(USD)), target.minLiquidity(address(cLCY)) );
    }*/
       
    function getTodayStats(address amm)
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
        IFiatAMM target = IFiatAMM(amm);

        uint256 day = target.today();

        FiatAMMStorage.DailyStats memory stats =
            target.getDailyStats(day);

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
    }

    function fetchLPPositionStats(address lp,address fee,address USD,address cLCY)
        external view
        returns (
            uint256 shareLCY, uint256 shareUSD,
            uint256 totalShareLCY, uint256 totalShareUSD
        )
    {
        IFiatFeeVault feeVault = IFiatFeeVault(fee);
        //if (address(feeVault).code.length == 0) revert FeeVaultNotContract();
        shareLCY      = feeVault.shares(address(cLCY), lp);
        shareUSD      = feeVault.shares(address(USD),  lp);
        totalShareLCY = feeVault.totalShares(address(cLCY));
        totalShareUSD = feeVault.totalShares(address(USD));
       
    }
    
}
