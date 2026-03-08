// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/*interface IERC20 {
    function balanceOf(address) external view returns(uint);
    function approve(address,uint) external returns(bool);
    function transfer(address,uint) external returns(bool);
}*/

interface IPair {
    function getReserves() external view returns(uint,uint,uint);
    function token0() external view returns(address);
    function token1() external view returns(address);
}

interface IFactory {
    function getPair(address,address,bool) external view returns(address);
}

interface IFeePool {
    function fee() external view returns (uint256);
}

interface IRouter {

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns(uint,uint,uint);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns(uint,uint);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        Route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory);

    function getAmountsOut(
        uint amountIn,
        Route[] calldata routes
    ) external view returns (uint[] memory);
}

contract AerodromeLiquidityManager is ReentrancyGuard {

    using SafeERC20 for IERC20;

    address public owner;
    IRouter public router;
    IFactory public factory;

    uint public slippageBps = 50; // 0.5%
    uint constant BPS = 10000;

    
    event LiquidityAdded(address pool,uint amountA,uint amountB,uint liquidity);
    event LiquidityRemoved(uint amountA,uint amountB);
    event SwapExecuted(address tokenIn,address tokenOut,uint amountIn,uint amountOut);
    event SlippageUpdated(uint newSlippage);

    modifier onlyOwner() {
        require(msg.sender == owner,"not owner");
        _;
    }

    constructor(address _router,address _factory) {
        require(_router != address(0));
        require(_factory != address(0));

        owner = msg.sender;
        router = IRouter(_router);
        factory = IFactory(_factory);
    }

    /* ------------------------------------------------------------ */
    /* ROUTE BUILDER */
    /* ------------------------------------------------------------ */

    function buildRoute(
        address tokenIn,
        address tokenOut,
        bool stable
    ) internal view returns(IRouter.Route[] memory routes){

        routes = new IRouter.Route[](1);

        routes[0] = IRouter.Route({
            from: tokenIn,
            to: tokenOut,
            stable: stable,
            factory: address(factory)
        });
    }

    /* ------------------------------------------------------------ */
    /* QUOTE */
    /* ------------------------------------------------------------ */

    function quote(
        address tokenIn,
        address tokenOut,
        bool stable,
        uint256 amountIn
    ) public view returns(uint256 amountOut){

        IRouter.Route[] memory routes = buildRoute(tokenIn,tokenOut,stable);

        uint256[] memory amounts = router.getAmountsOut(amountIn,routes);
        amountOut = amounts[amounts.length - 1];
    }

    /* ------------------------------------------------------------ */
    /* SWAP */
    /* ------------------------------------------------------------ */

    function swap(
        address tokenIn,
        address tokenOut,
        bool stable,
        uint amountIn
    ) external onlyOwner nonReentrant returns(uint amountOut){

        IRouter.Route[] memory routes = buildRoute(tokenIn,tokenOut,stable);
        uint[] memory amounts = router.getAmountsOut(amountIn,routes);
        uint expectedOut = amounts[amounts.length - 1];

        uint minOut = expectedOut * (BPS - slippageBps) / BPS;

        IERC20(tokenIn).safeTransferFrom(msg.sender,address(this),amountIn);
        IERC20(tokenIn).safeIncreaseAllowance(address(router),amountIn);

        uint[] memory result = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            routes,
            address(this),
            block.timestamp + 300
        );

        amountOut = result[result.length - 1];

        emit SwapExecuted(tokenIn,tokenOut,amountIn,amountOut);
    }

    /* ------------------------------------------------------------ */
    /* ADD LIQUIDITY */
    /* ------------------------------------------------------------ */

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountA,
        uint amountB
    ) external onlyOwner nonReentrant {

        address pool = factory.getPair(tokenA,tokenB,stable);
        require(pool != address(0),"pool not found");

        uint minA = amountA * (BPS - slippageBps) / BPS;
        uint minB = amountB * (BPS - slippageBps) / BPS;

         IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
         IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);

        IERC20(tokenA).safeIncreaseAllowance(address(router),amountA);
        IERC20(tokenB).safeIncreaseAllowance(address(router),amountB);

        (uint a,uint b,uint liquidity) =
        router.addLiquidity(
            tokenA,
            tokenB,
            stable,
            amountA,
            amountB,
            minA,
            minB,
            address(this),
            block.timestamp + 300
        );

        emit LiquidityAdded(pool,a,b,liquidity);
    }

    /* ------------------------------------------------------------ */
    /* REMOVE LIQUIDITY */
    /* ------------------------------------------------------------ */

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint liquidity
    ) external onlyOwner nonReentrant {

        address pool = factory.getPair(tokenA,tokenB,stable);
        require(pool != address(0),"pool not found");

        //(address token0, address token1, bool stable)
        //(uint reserve0, uint reserve1) = getPoolReserves(tokenA, tokenB, stable);
        IPair pair = IPair(pool);
        (uint256 reserve0,uint256 reserve1,) = pair.getReserves();

        uint256 minA = reserve0 * (BPS - slippageBps) / BPS;
        uint256 minB = reserve1 * (BPS - slippageBps) / BPS;

        IERC20(pool).safeIncreaseAllowance(address(router),liquidity);

        (uint256 a,uint256 b) =
        router.removeLiquidity(
            tokenA,
            tokenB,
            stable,
            liquidity,
            minA,
            minB,
            address(this),
            block.timestamp + 300
        );

        emit LiquidityRemoved(a,b);
    }

    /* ------------------------------------------------------------ */
    /* POOL RESERVES */
    /* ------------------------------------------------------------ */

    function getPoolReserves(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns(uint reserveA,uint reserveB){

        address pool = factory.getPair(tokenA,tokenB,stable);
        require(pool != address(0),"pool missing");

        IPair pair = IPair(pool);

        (uint256 r0,uint256 r1,) = pair.getReserves();

        if(pair.token0() == tokenA){
            reserveA = r0;
            reserveB = r1;
        } else {
            reserveA = r1;
            reserveB = r0;
        }
    }

    /* ------------------------------------------------------------ */
    /* SETTINGS */
    /* ------------------------------------------------------------ */

    function setSlippage(uint _bps) external onlyOwner {
        require(_bps <= 1000,"too high"); // max 10%
        slippageBps = _bps;
        emit SlippageUpdated(_bps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0));
        owner = newOwner;
    }

    /* ------------------------------------------------------------ */
    /* EMERGENCY */
    /* ------------------------------------------------------------ */

    function rescueToken(address token) external onlyOwner {
        uint bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner,bal);
    }
}