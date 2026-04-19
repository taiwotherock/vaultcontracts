// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*interface IERC20 {
    function transferFrom(address from, address to, uint value) external returns (bool);
    function approve(address spender, uint value) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
}*/

interface IPair {
    function getReserves() external view returns(uint,uint,uint);
    function token0() external view returns(address);
    function token1() external view returns(address);
}

interface IRouter {

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function getAmountsOut(
        uint amountIn,
        Route[] calldata routes
    ) external view returns (uint[] memory);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        Route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory);

}

interface IFactory {
    function getPair(address,address,bool) external view returns(address);
}

interface IFeePool {
    function fee() external view returns (uint256);
}

contract AeTradingBasket2 is ReentrancyGuard {

    using SafeERC20 for IERC20;
    address public owner;
    address public pendingOwner;
    address public USD;
    uint constant MAX_TOKENS = 3;
    uint256 constant USD_DECIMALS = 6;
    uint256 constant TARGET_DECIMALS = 18;
    uint256 constant PRECISION = 1e18;
    uint256 constant USD_TO_18 = 1e12;
    uint public constant SLIPPAGE_BPS = 20; // 0.2%
    int public realizedPnL;
    mapping(address => int256) public tokenPnL;
    IRouter public router;
    IFactory public factory;

    event AllocationUpdated(uint index, uint16 oldAllocation, uint16 newAllocation);
    event AllocationsUpdated(uint16[6] oldAllocations, uint16[6] newAllocations);
    event TradeExecuted(
        address indexed token,
        bool isBuy,
        uint amountIn,
        uint amountOut,
        uint priceUSD
    );
    event PositionUpdated(
        address indexed token,
        uint256 totalCostUSD,
        uint256 totalTokens,
        int256 pnl
    );
    event OwnershipTransferProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferCancelled(address indexed currentOwner, address indexed cancelledProposed);
    event StopLossUpdated(uint indexed index, uint256 oldValue, uint256 newValue);
    event TakeProfitUpdated(uint indexed index, uint256 oldValue, uint256 newValue);

    constructor(address _USD,address _router,address _factory) {

        require(_router != address(0));
        require(_factory != address(0));

        owner = msg.sender;
        USD = _USD;
        
        router = IRouter(_router);
        factory = IFactory(_factory);

        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // =========================
    // STRUCTS
    // =========================

    struct BasketToken {
        address token;
        uint16 allocation; // in bps
        bool active;
        uint256 stopLoss; // USD scaled
        uint256 takeProfit; // USD scaled
        uint256 totalInvestedUSD;
        uint256 totalTokens;
        int256 pnlTargetBps; // auto-sell trigger
        
    }

    struct Trade {
        uint timestamp;
        address token;
        bool isBuy;
        uint amountIn;
        uint amountOut;
        uint priceUSD;
    }

    struct Position {
        uint256 totalCostUSD;   // cumulative USD invested
        uint256 totalTokens;    // total tokens held
    }
  

    BasketToken[MAX_TOKENS] public basket;
    Trade[] public trades;
    mapping(address => Position) public positions;

    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }
    function pause() external onlyOwner {
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }
  
    // =========================
    // TOKEN MANAGEMENT
    // =========================

    function setToken(
        uint index,
        address _token,
        uint16 _allocation,
        bool _active,
        uint256 _stopLoss,
        uint256 _takeProfit,
        int256 _pnlTargetBps
    ) external onlyOwner {
        require(index < MAX_TOKENS, "Invalid index");
        require(_token != address(0),"invalid token");

        // ✅ ADD THESE TWO LINES
        require(basket[index].totalTokens == 0, "Position open: sell before reconfiguring");
        require(basket[index].totalInvestedUSD == 0, "Position open: sell before reconfiguring");

        basket[index] = BasketToken({
            token: _token,
            allocation: _allocation,
            active: _active,
            stopLoss: _stopLoss,
            takeProfit: _takeProfit,
            totalInvestedUSD: 0,
            totalTokens: 0,
            pnlTargetBps: _pnlTargetBps
        });
    }

    function updateStopLoss(uint tokenIdx, uint256 _stopLoss) external onlyOwner {
        require(tokenIdx < MAX_TOKENS, "Invalid index");
        uint256 oldValue = basket[tokenIdx].stopLoss;
        basket[tokenIdx].stopLoss = _stopLoss;
        emit StopLossUpdated(tokenIdx, oldValue, _stopLoss);

    }

    function updateTakeProfit(uint index, uint256 _takeProfit) external onlyOwner {
        require(index < MAX_TOKENS, "Invalid index");
        uint256 oldValue = basket[index].takeProfit;
        basket[index].takeProfit = _takeProfit;
        emit TakeProfitUpdated(index, oldValue, _takeProfit);
    }

    
    function updateAllocation(uint index, uint16 newAllocation) external onlyOwner {
        require(index < MAX_TOKENS, "Invalid index");
        require(newAllocation <= 10000, "Invalid bps");

        uint total;

        for (uint i = 0; i < MAX_TOKENS; i++) {
            if (i == index) {
                total += newAllocation;
            } else if (basket[i].active) {
                total += basket[i].allocation;
            }
        }

        require(total <= 10000, "Total allocation exceeds 100%");

        uint16 oldAllocation = basket[index].allocation;
        basket[index].allocation = newAllocation;

        emit AllocationUpdated(index, oldAllocation, newAllocation);
    }
   

    function updateAllAllocations(uint16[6] calldata newAllocations) external onlyOwner {

        uint total;

        // calculate total allocation (only active tokens)
        for (uint i = 0; i < MAX_TOKENS; i++) {
            if (basket[i].active) {
                total += newAllocations[i];
            }
        }

        require(total <= 10000, "Total allocation exceeds 100%");

        uint16[6] memory oldAllocations;

        // update allocations
        for (uint i = 0; i < MAX_TOKENS; i++) {
            oldAllocations[i] = basket[i].allocation;
            basket[i].allocation = newAllocations[i];
        }

        emit AllocationsUpdated(oldAllocations, newAllocations);
    }

    // =========================
    // ORACLE PRICE
    // =========================

    
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

    function buildTwoHopRoute(
        address tokenIn,
        address midToken,
        address tokenOut
    ) internal view returns (IRouter.Route[] memory routes) {

        routes = new IRouter.Route[](2);

        routes[0] = IRouter.Route({
            from: tokenIn,
            to: midToken,
            stable: false,
            factory: address(factory)
        });

        routes[1] = IRouter.Route({
            from: midToken,
            to: tokenOut,
            stable: false,
            factory: address(factory)
        });
    }

    function swapTwoHop(
        address tokenIn,
        address midToken,
        address tokenOut,
        uint256 amountIn
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        IERC20(tokenIn).approve(address(router), 0);
        IERC20(tokenIn).approve(address(router), amountIn);

        IRouter.Route[] memory routes = buildTwoHopRoute(tokenIn, midToken, tokenOut);

        uint256[] memory amounts = router.getAmountsOut(amountIn, routes);
        uint256 expected = amounts[amounts.length - 1];
        require(expected > 0, "No liquidity");

        uint256 minOut = (expected * (10000 - SLIPPAGE_BPS)) / 10000;

        uint256[] memory result = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            routes,
            address(this),
            block.timestamp + 60
        );

        uint256 received = result[result.length - 1];

        emit TradeExecuted(tokenOut, true, amountIn, received, 0);
    }

    function getBasketQuote(uint256 usdAmt)
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory amountsOut
        )
    {
        tokens = new address[](MAX_TOKENS);
        amountsOut = new uint256[](MAX_TOKENS);

        for (uint i = 0; i < MAX_TOKENS; i++) {

            BasketToken memory t = basket[i];
            if (!t.active || t.token == address(0)) continue;

            uint256 amountIn = (usdAmt * t.allocation) / 10000;
            if (amountIn == 0) continue;

            IRouter.Route[] memory routes = buildRoute(USD, t.token, false);

            uint256[] memory amounts = router.getAmountsOut(amountIn, routes);
            uint256 expected = amounts[amounts.length - 1];

            tokens[i] = t.token;
            amountsOut[i] = expected;
        }
    }

    function buySingleToken(uint index, uint256 usdAmt)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        BasketToken storage t = basket[index];
        require(t.active, "Inactive");
        require(t.token != address(0), "Invalid token");

        uint256 usdBalance = IERC20(USD).balanceOf(address(this));
        require(usdBalance >= usdAmt, "Insufficient balance");

        IERC20(USD).approve(address(router), 0);
        IERC20(USD).approve(address(router), usdAmt);

        IRouter.Route[] memory routes = buildRoute(USD, t.token, false);

        uint256[] memory amounts = router.getAmountsOut(usdAmt, routes);
        uint256 expected = amounts[amounts.length - 1];
        require(expected > 0, "No liquidity");

        uint256 minOut = (expected * (10000 - SLIPPAGE_BPS)) / 10000;

        uint256[] memory result = router.swapExactTokensForTokens(
            usdAmt,
            minOut,
            routes,
            address(this),
            block.timestamp + 60
        );

        uint256 received = result[result.length - 1];

        uint256 priceUSD = (usdAmt * USD_TO_18 * PRECISION) / received;

        t.totalInvestedUSD += usdAmt;
        t.totalTokens += received;

        _updateOnBuy(t.token, usdAmt, received);

        trades.push(Trade(block.timestamp, t.token, true, usdAmt, received, priceUSD));

        emit TradeExecuted(t.token, true, usdAmt, received, priceUSD);
        emit PositionUpdated(
            t.token,
            positions[t.token].totalCostUSD,
            positions[t.token].totalTokens,
            0
        );

        IERC20(USD).approve(address(router), 0);
    }

    function swapTokenToToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        require(tokenIn != tokenOut, "Same token");

        IERC20(tokenIn).approve(address(router), 0);
        IERC20(tokenIn).approve(address(router), amountIn);

        IRouter.Route[] memory routes = buildRoute(tokenIn, tokenOut, false);

        uint256[] memory amounts = router.getAmountsOut(amountIn, routes);
        uint256 expected = amounts[amounts.length - 1];
        require(expected > 0, "No liquidity");

        uint256 minOut = (expected * (10000 - SLIPPAGE_BPS)) / 10000;

        uint256[] memory result = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            routes,
            address(this),
            block.timestamp + 60
        );

        uint256 received = result[result.length - 1];

        emit TradeExecuted(tokenOut, true, amountIn, received, 0);
    }

    // =========================
    // BUY BASKET
    // =========================

    function buyBasket(uint256 usdAmt) external onlyOwner nonReentrant whenNotPaused {

        //IERC20(USD).transferFrom(msg.sender, address(this), usdAmt);
        uint256 usdBalance = IERC20(USD).balanceOf(address(this));
        require(usdBalance >= usdAmt, "Insufficient balance");

        IERC20(USD).approve(address(router), 0);
        IERC20(USD).approve(address(router), usdAmt);

        for (uint i = 0; i < MAX_TOKENS; i++) {

            BasketToken storage t = basket[i];
            if (!t.active || t.token == address(0)) continue;

            uint256 amountIn = (usdAmt * t.allocation) / 10000;
            if (amountIn == 0) continue;

            //IAerodromeRouter.Route ;
            //routes[0] = IAerodromeRouter.Route(USD, t.token, false);

            IRouter.Route[] memory routes = buildRoute(USD,t.token,false);
            uint256[] memory amounts = router.getAmountsOut(amountIn,routes);
            uint256 expected = amounts[amounts.length - 1];
            require(expected > 0, "No liquidity");
            //uint executionPrice = (amountIn * USD_TO_18 * PRECISION) / expected;
           // require(expected >= amountIn / 2, "Bad price"); // basic sanity
           // uint256 before = IERC20(USD).balanceOf(address(this));

            uint256 minOut = (expected * (10000 - SLIPPAGE_BPS)) / 10000;

            uint256[] memory result = router.swapExactTokensForTokens(
                amountIn,
                minOut,
                routes,
                address(this),
                block.timestamp + 60
            );

            //uint256 afterBal = IERC20(USD).balanceOf(address(this));
            //uint256 received2 = afterBal - before;

            uint256 received = result[result.length - 1];
            uint256 priceUSD = 0;
            if(received > 0)
              priceUSD = (amountIn * USD_TO_18 * PRECISION) / received;
       
            // update cost basis
            t.totalInvestedUSD += amountIn;
            t.totalTokens += received;
            // update position mapping (if used)
            //positions[t.token].totalCostUSD += amountIn;
            //positions[t.token].totalTokens += received;

            // emit position update
            

            // save trade
            //uint priceUSD = getLatestPriceUSD(i);
            trades.push(Trade(block.timestamp, t.token, true, amountIn, received, priceUSD));
            _updateOnBuy(t.token, amountIn, received);
            emit TradeExecuted(t.token, true, amountIn, received, priceUSD);
            emit PositionUpdated(
                t.token,
                positions[t.token].totalCostUSD,
                positions[t.token].totalTokens,
                0
            );
        }

        IERC20(USD).approve(address(router), 0);

    }

    // =========================
    // SELL BASKET
    // =========================

    function sellBasket() external onlyOwner nonReentrant whenNotPaused {

        for (uint i = 0; i < MAX_TOKENS; i++) {
            _sellToken(i);
        }

    }

    function sellOneToken(uint i) external onlyOwner nonReentrant whenNotPaused {

        _sellToken(i);

    }

    function _sellToken(uint i) internal {

        BasketToken storage t = basket[i];
        if (!t.active || t.token == address(0)) return;

        //uint256 balance = IERC20(t.token).balanceOf(address(this));
        //if (balance == 0) return;

        // ✅ Use tracked position size, not raw balanceOf
        uint256 balance = t.totalTokens;
        if (balance == 0) return;

        // ✅ Sanity check: contract must actually hold at least this much
        uint256 actualBalance = IERC20(t.token).balanceOf(address(this));
        require(actualBalance >= balance, "Balance below tracked position");
     
        IERC20(t.token).approve(address(router), 0);
        IERC20(t.token).approve(address(router), balance);

        IRouter.Route[] memory routes = buildRoute(t.token,USD,false);
        uint256[] memory amounts = router.getAmountsOut(balance,routes);
        uint256 expected = amounts[amounts.length - 1];
        require(expected > 0, "No liquidity");

        uint256 minOut = (expected * (10000 - SLIPPAGE_BPS)) / 10000;

        uint[] memory result = router.swapExactTokensForTokens(
            balance,
            minOut,
            routes,
            address(this),
            block.timestamp + 60
        );

        uint received = result[result.length - 1];

        // realized PnL
        //uint cost = t.totalInvestedUSD;
        uint cost = 0;
        if (t.totalTokens > 0)
         cost = (t.totalInvestedUSD * balance) / t.totalTokens;
        int pnl = int(received) - int(cost);
        realizedPnL += pnl;

        uint256 priceUSD = 0;
        priceUSD = (received * USD_TO_18 * PRECISION) / balance;

        trades.push(Trade(block.timestamp, t.token, false, balance, received, priceUSD));

        t.totalTokens = 0;
        t.totalInvestedUSD = 0;
        tokenPnL[t.token] += pnl;

        positions[t.token].totalCostUSD = 0;
        positions[t.token].totalTokens = 0;
    
        // emit position update
        emit PositionUpdated(
            t.token,
            0,
            0,
            pnl
        );
        emit TradeExecuted(t.token, false, balance, received, priceUSD);
    }

    function _updateOnBuy(address token, uint256 amountUSD, uint256 tokensReceived) internal {

        Position storage p = positions[token];
        p.totalCostUSD += amountUSD;
        p.totalTokens += tokensReceived;
    }

   

    function rescueToken(address token) external onlyOwner {
        uint bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner,bal);
    }
  
    function getToken(uint index)
        external
        view
        returns (
            address token,
            uint16 allocation,
            bool active,
            uint256 stopLoss,
            uint256 takeProfit,
            uint256 totalInvestedUSD,
            uint256 totalTokens,
            int256 pnlTargetBps
        )
    {
        require(index < MAX_TOKENS, "Invalid index");

        BasketToken storage t = basket[index];

        return (
            t.token,
            t.allocation,
            t.active,
            t.stopLoss,
            t.takeProfit,
            t.totalInvestedUSD,
            t.totalTokens,
            t.pnlTargetBps
        );
    }

    function getPortfolioSummary()
        external
        view
        returns (
            uint totalInvested,
            uint totalTokensHeld,
            uint totalTrades,
            uint totalSnapshots
        )
    {
        for (uint i = 0; i < MAX_TOKENS; i++) {
            totalInvested += basket[i].totalInvestedUSD;
            totalTokensHeld += basket[i].totalTokens;
        }

        totalTrades = trades.length;
        totalSnapshots = 0;
    }

    function getAllPositions()
        external
        view
        returns (
            address[] memory tokens,
            uint16[] memory allocations,
            bool[] memory active,
            uint256[] memory totalCostUSD,
            uint256[] memory totalTokens,
            uint256[] memory avgCostPerToken
        )
    {
        uint256 count = MAX_TOKENS;

        tokens = new address[](count);
        allocations = new uint16[](count);
        active = new bool[](count);
        totalCostUSD = new uint256[](count);
        totalTokens = new uint256[](count);
        avgCostPerToken = new uint256[](count);

        for (uint i = 0; i < count; i++) {
            BasketToken storage b = basket[i];
            Position storage p = positions[b.token];

            tokens[i] = b.token;
            allocations[i] = b.allocation;
            active[i] = b.active;

            totalCostUSD[i] = p.totalCostUSD;
            totalTokens[i] = p.totalTokens;

            if (p.totalTokens > 0) {
                avgCostPerToken[i] = (p.totalCostUSD * PRECISION) / p.totalTokens;
            } else {
                avgCostPerToken[i] = 0;
            }
        }
    }
    
    /// @notice Step 1 — current owner proposes a new owner. Does not transfer yet.
    function proposeOwner(address _proposed) external onlyOwner {
        require(_proposed != address(0), "Zero address");
        require(_proposed != owner, "Already owner");
        pendingOwner = _proposed;
        emit OwnershipTransferProposed(owner, _proposed);
    }

    /// @notice Step 2 — proposed address must call this to accept ownership.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    /// @notice Cancel a pending proposal. Callable by either party.
    function cancelOwnershipTransfer() external {
        require(
            msg.sender == owner || msg.sender == pendingOwner,
            "Not authorised"
        );
        address cancelled = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(owner, cancelled);
    }
}