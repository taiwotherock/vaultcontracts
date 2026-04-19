// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// ── Interfaces ────────────────────────────────────────────────────────────────

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn; address tokenOut; uint256 amountIn; uint24 fee; uint160 sqrtPriceLimitX96;
    }
    struct QuoteExactOutputSingleParams {
        address tokenIn; address tokenOut; uint256 amount; uint24 fee; uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory p)
        external returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 ticksCrossed, uint256 gasEst);
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory p)
        external returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 ticksCrossed, uint256 gasEst);
}

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick,
        uint16, uint16, uint16, uint8, bool
    );
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick) external view returns (
        uint128 liquidityGross, int128 liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        int56, uint160, uint32, bool
    );
    function liquidity() external view returns (uint128);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    struct ExactOutputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 deadline; uint256 amountOut; uint256 amountInMaximum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256 amountIn);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        uint256 deadline;
    }
    struct DecreaseLiquidityParams {
        uint256 tokenId; uint128 liquidity;
        uint256 amount0Min; uint256 amount1Min;
        uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId; address recipient;
        uint128 amount0Max; uint128 amount1Max;
    }
    function mint(MintParams calldata p)
        external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function increaseLiquidity(IncreaseLiquidityParams calldata p)
        external returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata p)
        external returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata p) external returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1,
        uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
}

library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272;

    /// @notice sqrtRatio → tick  (Newton-Raphson not needed here — we only go price→tick)
    /// For price→tick off-chain use:  tick = floor( log(price) / log(1.0001) )
    /// On-chain helper: snap a raw tick to the nearest valid multiple of tickSpacing
    function snapTick(int24 rawTick, int24 spacing) internal pure returns (int24) {
        int24 snapped = (rawTick / spacing) * spacing;
        if (rawTick < 0 && rawTick % spacing != 0) snapped -= spacing;
        return snapped;
    }
}

// ── Q128 math ─────────────────────────────────────────────────────────────────

library FullMath {
    /// fee = feeGrowthDelta * liquidity / 2^128
    function mulDiv128(uint256 a, uint128 b) internal pure returns (uint256) {
        return (a * uint256(b)) >> 128;
    }
}

// ── Main Contract ─────────────────────────────────────────────────────────────

contract BfLiquidityEngine {

    IQuoterV2                    public immutable quoter;
    IUniswapV3Factory            public immutable factory;
    ISwapRouter                  public immutable router;
    INonfungiblePositionManager  public immutable npm;

    // tickSpacing per fee tier
    mapping(uint24 => int24) public tickSpacing;

    // ─ Addresses same across Mainnet / Base / Arbitrum / Optimism ─────────────
    // QuoterV2  : 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
    // Factory   : 0x1F98431c8aD98523631AE4a59f267346ea31F984
    // Router    : 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // NPM       : 0xC36442b4a4522E871399CD717aBDD847Ab11FE88
    constructor(address _quoter, address _factory, address _router, address _npm) {
        quoter  = IQuoterV2(_quoter);
        factory = IUniswapV3Factory(_factory);
        router  = ISwapRouter(_router);
        npm     = INonfungiblePositionManager(_npm);

        tickSpacing[100]   = 1;    // 0.01%  (Base / v3.1)
        tickSpacing[500]   = 10;   // 0.05%
        tickSpacing[3000]  = 60;   // 0.30%
        tickSpacing[10000] = 200;  // 1.00%
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. GET POOL
    // ─────────────────────────────────────────────────────────────────────────

    function getPool(address tokenA, address tokenB, uint24 fee)
        external view returns (address pool)
    {
        pool = factory.getPool(tokenA, tokenB, fee);
        require(pool != address(0), "pool not found");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. QUOTES  (call off-chain via eth_call / callStatic — NOT view)
    // ─────────────────────────────────────────────────────────────────────────

    function quoteExactInput(
        address tokenIn, address tokenOut, uint24 fee, uint256 amountIn
    ) external returns (uint256 amountOut) {
        (amountOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams(tokenIn, tokenOut, amountIn, fee, 0)
        );
    }

    function quoteExactOutput(
        address tokenIn, address tokenOut, uint24 fee, uint256 amountOut
    ) external returns (uint256 amountIn) {
        (amountIn,,,) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams(tokenIn, tokenOut, amountOut, fee, 0)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. SWAP — EXACT INPUT
    //    caller approves this contract for amountIn before calling
    // ─────────────────────────────────────────────────────────────────────────

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum   // slippage guard — use quoteExactInput * (1 - slippage)
    ) external returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(address(router), amountIn);

        amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee,
                recipient:         msg.sender,
                deadline:          block.timestamp + 300,
                amountIn:          amountIn,
                amountOutMinimum:  amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. SWAP — EXACT OUTPUT
    //    caller approves this contract for amountInMaximum before calling
    //    unused tokenIn is refunded back to caller
    // ─────────────────────────────────────────────────────────────────────────

    function swapExactOutput(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountOut,
        uint256 amountInMaximum    // slippage guard — use quoteExactOutput * (1 + slippage)
    ) external returns (uint256 amountIn) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountInMaximum);
        IERC20(tokenIn).approve(address(router), amountInMaximum);

        amountIn = router.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn:          tokenIn,
                tokenOut:         tokenOut,
                fee:              fee,
                recipient:        msg.sender,
                deadline:         block.timestamp + 300,
                amountOut:        amountOut,
                amountInMaximum:  amountInMaximum,
                sqrtPriceLimitX96: 0
            })
        );

        // refund unspent tokenIn
        if (amountIn < amountInMaximum) {
            IERC20(tokenIn).approve(address(router), 0);
            IERC20(tokenIn).transfer(msg.sender, amountInMaximum - amountIn);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. ADD LIQUIDITY  →  mints a new NFT position
    //    caller approves this contract for amount0Desired & amount1Desired
    //    token0 < token1 (sort by address before calling)
    // ─────────────────────────────────────────────────────────────────────────

    function addLiquidity(
        address token0,
        address token1,
        uint24  fee,
        int24   tickLower,
        int24   tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,        // slippage guard
        uint256 amount1Min         // slippage guard
    ) external returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Used,
        uint256 amount1Used
    ) {
        IERC20(token0).transferFrom(msg.sender, address(this), amount0Desired);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1Desired);
        IERC20(token0).approve(address(npm), amount0Desired);
        IERC20(token1).approve(address(npm), amount1Desired);

        (tokenId, liquidity, amount0Used, amount1Used) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0:         token0,
                token1:         token1,
                fee:            fee,
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min:     amount0Min,
                amount1Min:     amount1Min,
                recipient:      msg.sender,
                deadline:       block.timestamp + 300
            })
        );

        // refund dust
        _refundDust(token0, token1, amount0Desired - amount0Used, amount1Desired - amount1Used);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. REMOVE LIQUIDITY  →  decrease + collect in one call
    //    caller must approve NPM to transfer the NFT, or this contract must
    //    be the NFT owner.  Simplest: caller holds NFT, approves NPM operator,
    //    then calls npm.approve(address(this), tokenId) before calling here.
    // ─────────────────────────────────────────────────────────────────────────

    function removeLiquidity(
        uint256 tokenId,
        uint128 liquidity,         // from npm.positions(tokenId).liquidity
        uint256 amount0Min,        // slippage guard
        uint256 amount1Min         // slippage guard
    ) external returns (uint256 amount0, uint256 amount1) {
        // decrease
        (amount0, amount1) = npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId:    tokenId,
                liquidity:  liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline:   block.timestamp + 300
            })
        );

        // collect all owed tokens (including any accrued fees)
        (amount0, amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId:     tokenId,
                recipient:   msg.sender,
                amount0Max:  type(uint128).max,
                amount1Max:  type(uint128).max
            })
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. COLLECT FEES ONLY  (without removing liquidity)
    // ─────────────────────────────────────────────────────────────────────────

    function collectFees(uint256 tokenId)
        external returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId:    tokenId,
                recipient:  msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────

    function _refundDust(address t0, address t1, uint256 d0, uint256 d1) internal {
        if (d0 > 0) IERC20(t0).transfer(msg.sender, d0);
        if (d1 > 0) IERC20(t1).transfer(msg.sender, d1);
    }

    function computeTickRange(
        int24  rawTickLower,    // floor(log_1.0001(priceLower))
        int24  rawTickUpper,    // floor(log_1.0001(priceUpper))
        uint24 fee
    ) public view returns (int24 tickLower, int24 tickUpper) {
        int24 spacing = tickSpacing[fee];
        require(spacing > 0, "unknown fee");
        tickLower = TickMath.snapTick(rawTickLower, spacing);
        tickUpper = TickMath.snapTick(rawTickUpper, spacing);
        require(tickLower < tickUpper,             "lower >= upper");
        require(tickLower >= TickMath.MIN_TICK,    "below min");
        require(tickUpper <= TickMath.MAX_TICK,    "above max");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. CURRENT TICK  (read live pool price)
    // ─────────────────────────────────────────────────────────────────────────

    function currentTick(address token0, address token1, uint24 fee)
        external view returns (int24 tick, uint160 sqrtPriceX96)
    {
        address pool = factory.getPool(token0, token1, fee);
        require(pool != address(0), "no pool");
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. ADD CONCENTRATED LIQUIDITY
    //    token0 < token1 (sort by address).
    //    Caller approves this contract for amount0Desired & amount1Desired.
    // ─────────────────────────────────────────────────────────────────────────

    function addConcentratedLiquidity(
        address token0,
        address token1,
        uint24  fee,
        int24   rawTickLower,       // pre-compute off-chain or use currentTick ± range
        int24   rawTickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 slippageBps         // e.g. 50 = 0.5%
    ) external returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Used,
        uint256 amount1Used
    ) {
        (int24 tl, int24 tu) = computeTickRange(rawTickLower, rawTickUpper, fee);

        // pull tokens
        IERC20(token0).transferFrom(msg.sender, address(this), amount0Desired);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1Desired);
        IERC20(token0).approve(address(npm), amount0Desired);
        IERC20(token1).approve(address(npm), amount1Desired);

        uint256 min0 = amount0Desired * (10000 - slippageBps) / 10000;
        uint256 min1 = amount1Desired * (10000 - slippageBps) / 10000;

        (tokenId, liquidity, amount0Used, amount1Used) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0:         token0,
                token1:         token1,
                fee:            fee,
                tickLower:      tl,
                tickUpper:      tu,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min:     min0,
                amount1Min:     min1,
                recipient:      msg.sender,
                deadline:       block.timestamp + 300
            })
        );

        // refund dust
        uint256 d0 = amount0Desired - amount0Used;
        uint256 d1 = amount1Desired - amount1Used;
        if (d0 > 0) IERC20(token0).transfer(msg.sender, d0);
        if (d1 > 0) IERC20(token1).transfer(msg.sender, d1);
    }

    
    function computeFeesEarned(uint256 tokenId)
        external view
        returns (uint256 fee0, uint256 fee1)
    {
        (
            ,, address token0, address token1,
            uint24 fee,
            int24 tickLower, int24 tickUpper,
            uint128 liq,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = npm.positions(tokenId);

        IUniswapV3Pool pool = IUniswapV3Pool(
            factory.getPool(token0, token1, fee)
        );

        uint256 fg0 = pool.feeGrowthGlobal0X128();
        uint256 fg1 = pool.feeGrowthGlobal1X128();
        (, int24 currentT,,,,,) = pool.slot0();

        uint256 inside0 = _feeGrowthInside(pool, tickLower, tickUpper, currentT, fg0, true);
        uint256 inside1 = _feeGrowthInside(pool, tickLower, tickUpper, currentT, fg1, false);

        // uncollected = delta * liquidity / 2^128   (uint256 wrapping is intentional — V3 spec)
        uint256 uncollected0 = FullMath.mulDiv128(inside0 - feeGrowthInside0Last, liq);
        uint256 uncollected1 = FullMath.mulDiv128(inside1 - feeGrowthInside1Last, liq);

        fee0 = uint256(tokensOwed0) + uncollected0;
        fee1 = uint256(tokensOwed1) + uncollected1;
    }

    /// @dev feeGrowthInside = global - feeGrowthBelow(lower) - feeGrowthAbove(upper)
    function _feeGrowthInside(
        IUniswapV3Pool pool,
        int24  tickLower,
        int24  tickUpper,
        int24  tickCurrent,
        uint256 feeGrowthGlobal,
        bool   isToken0
    ) internal view returns (uint256 feeGrowthInside) {
        (,,uint256 fg0Lower, uint256 fg1Lower,,,,) = pool.ticks(tickLower);
        (,,uint256 fg0Upper, uint256 fg1Upper,,,,) = pool.ticks(tickUpper);

        uint256 fgLower = isToken0 ? fg0Lower : fg1Lower;
        uint256 fgUpper = isToken0 ? fg0Upper : fg1Upper;

        // feeGrowthBelow: if currentTick >= tickLower → use stored, else global - stored
        uint256 below = tickCurrent >= tickLower
            ? fgLower
            : feeGrowthGlobal - fgLower;

        // feeGrowthAbove: if currentTick < tickUpper → use stored, else global - stored
        uint256 above = tickCurrent < tickUpper
            ? fgUpper
            : feeGrowthGlobal - fgUpper;

        feeGrowthInside = feeGrowthGlobal - below - above;  // wrapping subtraction is correct
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. COLLECT FEES  (realise accrued fees to wallet)
    // ─────────────────────────────────────────────────────────────────────────

 

    // ─────────────────────────────────────────────────────────────────────────
    // 6. REMOVE CONCENTRATED LIQUIDITY + COLLECT in one shot
    // ─────────────────────────────────────────────────────────────────────────

    function removeLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 slippageBps
    ) external returns (uint256 amount0, uint256 amount1) {
        (,,,,,,,uint128 posLiq,,,,) = npm.positions(tokenId);
        require(liquidity <= posLiq, "exceeds position liquidity");

        // estimate minimums from current quote before calling
        (uint256 e0, uint256 e1) = npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId:    tokenId,
                liquidity:  liquidity,
                amount0Min: 0,     // set post-quote in prod
                amount1Min: 0,
                deadline:   block.timestamp + 300
            })
        );
        //_ = e0; _ = e1; // suppress warnings — collect sweeps everything

        (amount0, amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId:    tokenId,
                recipient:  msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }
}