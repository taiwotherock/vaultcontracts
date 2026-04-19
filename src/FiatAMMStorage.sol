// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/Math.sol";

// =============================================================
// AMMRiskBase — Abstract base: all risk state + guard functions
// Extracted from FiatStablecoinAMMV2 to reduce deploy size
// =============================================================

library FiatAMMStorage {

 struct DailyStats {
        uint256 swapVolumeLCY;
        uint256 swapVolumeUSD;
        uint256 swapCountLCY;
        uint256 swapCountUSD;
        uint256 lpFeeUSD;
        uint256 lpFeeLCY;
        uint256 platformFeeUSD;
        uint256 platformFeeLCY;
        uint256 liquidityAddedUSD;
        uint256 liquidityAddedLCY;
        uint256 liquidityRemovedUSD;
        uint256 liquidityRemovedLCY;
    }

    

}
