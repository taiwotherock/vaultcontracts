// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// =============================================================
// AMMQuoter — Standalone read-only quote contract
// Deployed separately; reads AMM state via interface.
// Keeping quote logic here saves ~1.2 KB on the core AMM deploy.
// =============================================================

import "@openzeppelin/contracts/utils/math/Math.sol";

interface IAMMState {
    function poolDeposits(address token)    external view returns (uint256);
    function buyRate()                      external view returns (uint256);
    function sellRate()                     external view returns (uint256);
    function swapFeeBps()                   external view returns (uint256);
    function lpShareBps()                   external view returns (uint256);
    function minLiquidity(address token)    external view returns (uint256);
    function MIN_TRADE_USD()                external view returns (uint256);
    function MIN_TRADE_LCY()                external view returns (uint256);
    function USD_SCALE()                    external view returns (uint256);
    function MAX_WITHDRAW_BPS()             external view returns (uint256);
    function feeVault()                     external view returns (address);
    function cLCY()                         external view returns (address);
    function USD()                          external view returns (address);
}

contract AMMQuoter {

    uint256 public constant FEE_DENOM = 10_000;

    IAMMState public immutable amm;

    constructor(address _amm) {
        require(_amm != address(0), "zero address");
        amm = IAMMState(_amm);
    }

    // -------------------------------------------------------
    // QUOTE — LCY → USD
    // -------------------------------------------------------

    /// @notice Returns the expected output for a LCY-to-USD swap.
    /// @param lcyAmount  Amount of cLCY in (6 decimals).
    /// @return net       USD received after fee.
    /// @return fee       Total fee deducted (USD, 6 decimals).
    /// @return rate      buyRate used for the quote.
    /// @return feasible  False if pool depth or caps would reject the swap.
    /// @return reason    Human-readable rejection reason when feasible=false.
    function quoteLCYtoUSD(uint256 lcyAmount)
        external view
        returns (
            uint256 net,
            uint256 fee,
            uint256 rate,
            bool    feasible,
            string  memory reason
        )
    {
        address usdAddr = amm.USD();
        address lcyAddr = amm.cLCY();

        uint256 usdPool = amm.poolDeposits(usdAddr);
        uint256 lcyPool = amm.poolDeposits(lcyAddr);

        if (usdPool == 0 || lcyPool == 0) {
            return (0, 0, 0, false, "pool empty");
        }

        rate            = amm.buyRate();
        uint256 gross   = Math.mulDiv(lcyAmount, amm.USD_SCALE(), rate);
        uint256 totalFee = Math.mulDiv(gross, amm.swapFeeBps(), FEE_DENOM);

        if (totalFee == 0) {
            return (0, 0, rate, false, "fee rounds to zero: trade too small");
        }

        net = gross - totalFee;
        fee = totalFee;

        uint256 minUSD    = amm.MIN_TRADE_USD();
        uint256 minLiqUSD = amm.minLiquidity(usdAddr);

        if (net < minUSD) {
            return (net, fee, rate, false, "below min trade USD");
        }
        if (usdPool <= minLiqUSD) {
            return (net, fee, rate, false, "USD pool too small");
        }
        if (usdPool < gross) {
            return (net, fee, rate, false, "insufficient USD pool");
        }
        if (net > Math.mulDiv(usdPool - fee, amm.MAX_WITHDRAW_BPS(), FEE_DENOM)) {
            return (net, fee, rate, false, "pool cap: max swap reached");
        }
        if (usdPool < minLiqUSD + gross) {
            return (net, fee, rate, false, "insufficient USD buffer");
        }

        feasible = true;
    }

    // -------------------------------------------------------
    // QUOTE — USD → LCY
    // -------------------------------------------------------

    /// @notice Returns the expected output for a USD-to-LCY swap.
    /// @param usdAmount  Amount of USD in (6 decimals).
    /// @return net       cLCY received after fee.
    /// @return fee       Total fee deducted (cLCY, 6 decimals).
    /// @return rate      sellRate used for the quote.
    /// @return feasible  False if pool depth or caps would reject the swap.
    /// @return reason    Human-readable rejection reason when feasible=false.
    function quoteUSDtoLCY(uint256 usdAmount)
        external view
        returns (
            uint256 net,
            uint256 fee,
            uint256 rate,
            bool    feasible,
            string  memory reason
        )
    {
        address usdAddr = amm.USD();
        address lcyAddr = amm.cLCY();

        uint256 usdPool = amm.poolDeposits(usdAddr);
        uint256 lcyPool = amm.poolDeposits(lcyAddr);

        if (usdPool == 0 || lcyPool == 0) {
            return (0, 0, 0, false, "pool empty");
        }

        rate            = amm.sellRate();
        uint256 gross   = Math.mulDiv(usdAmount, rate, amm.USD_SCALE());
        uint256 totalFee = Math.mulDiv(gross, amm.swapFeeBps(), FEE_DENOM);

        if (totalFee == 0) {
            return (0, 0, rate, false, "fee rounds to zero: trade too small");
        }

        net = gross - totalFee;
        fee = totalFee;

        uint256 minLCY    = amm.MIN_TRADE_LCY();
        uint256 minLiqLCY = amm.minLiquidity(lcyAddr);

        if (net < minLCY) {
            return (net, fee, rate, false, "below min trade LCY");
        }
        if (lcyPool <= minLiqLCY) {
            return (net, fee, rate, false, "LCY pool too small");
        }
        if (lcyPool < gross) {
            return (net, fee, rate, false, "insufficient LCY pool");
        }
        if (net > Math.mulDiv(lcyPool - fee, amm.MAX_WITHDRAW_BPS(), FEE_DENOM)) {
            return (net, fee, rate, false, "pool cap exceeded");
        }
        if (lcyPool < minLiqLCY + gross) {
            return (net, fee, rate, false, "insufficient LCY buffer");
        }

        feasible = true;
    }

    // -------------------------------------------------------
    // CONVENIENCE — BOTH DIRECTIONS IN ONE CALL
    // -------------------------------------------------------

    /// @notice Returns quotes for both swap directions simultaneously.
    ///         Useful for frontend pricing widgets.
    function quoteBoth(uint256 lcyAmount, uint256 usdAmount)
        external view
        returns (
            uint256 lcyToUsdNet,
            uint256 lcyToUsdFee,
            uint256 usdToLcyNet,
            uint256 usdToLcyFee,
            uint256 buy,
            uint256 sell
        )
    {
        buy  = amm.buyRate();
        sell = amm.sellRate();

        uint256 scale    = amm.USD_SCALE();
        uint256 feeBps   = amm.swapFeeBps();

        uint256 grossLCY = Math.mulDiv(lcyAmount, scale, buy);
        lcyToUsdFee      = Math.mulDiv(grossLCY, feeBps, FEE_DENOM);
        lcyToUsdNet      = lcyToUsdFee < grossLCY ? grossLCY - lcyToUsdFee : 0;

        uint256 grossUSD = Math.mulDiv(usdAmount, sell, scale);
        usdToLcyFee      = Math.mulDiv(grossUSD, feeBps, FEE_DENOM);
        usdToLcyNet      = usdToLcyFee < grossUSD ? grossUSD - usdToLcyFee : 0;
    }
}
