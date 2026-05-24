// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IERC20 {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ICLPool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Minimal single-hop swap helper for pools whose factory
///         doesn't match any deployed router.
contract AeroDirectPoolSwapper {
    // slot0 tick limits
    uint160 internal constant MIN_SQRT = 4295128739 + 1;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    struct CallbackData {
        address tokenIn;
        address payer;
        uint256 amountToPay;
    }

    /// @param pool      The CL pool address (0x99fb961b...)
    /// @param tokenIn   USDC  (0x833589...)
    /// @param tokenOut  tGBP  (0x27f6c8...)
    /// @param amountIn  exact input amount (6 decimals for USDC)
    /// @param amountOutMin  min tGBP to receive (18 decimals)
    /// @param recipient  who gets the tGBP
    function swapExactInput(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) external returns (uint256 amountOut) {
        ICLPool p       = ICLPool(pool);
        bool zeroForOne = tokenIn < tokenOut; // token ordering by address

        (int256 amount0, int256 amount1) = p.swap(
            recipient,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT : MAX_SQRT,
            abi.encode(CallbackData({ tokenIn: tokenIn, payer: msg.sender, amountToPay: amountIn }))
        );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        require(amountOut >= amountOutMin, "Too little received");
    }

    /// @dev Called by the pool to pull tokenIn from payer
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        CallbackData memory d = abi.decode(data, (CallbackData));
        uint256 pay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        IERC20(d.tokenIn).transferFrom(d.payer, msg.sender, pay); // msg.sender is pool
    }
}