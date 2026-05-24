// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// ════════════════════════════════════════════════════════════════════════════════
//  AERODROME SLIPSTREAM VAULT
//  Manages Aerodrome CL (Slipstream) NFT positions on behalf of a
//  BusinessSmartWallet.  Tokens flow IN via the wallet's spend mechanism;
//  proceeds flow OUT via sweepToWallet / closePosition.
//
//  Deployment (Base mainnet):
//    POSITION_MANAGER  = 0x827922686190790b37229fd06084350E74485b72
//    AERO              = 0x940181a94A35A4569E4529A3CDfB74e38FD98631
// ════════════════════════════════════════════════════════════════════════════════

// ─── Interface: Aerodrome CL Position Manager ─────────────────────────────────
interface INonfungiblePositionManager {

    struct MintParams {
        address  token0;
        address  token1;
        int24    tickSpacing;
        int24    tickLower;
        int24    tickUpper;
        uint256  amount0Desired;
        uint256  amount1Desired;
        uint256  amount0Min;
        uint256  amount1Min;
        address  recipient;
        uint256  deadline;
        uint160  sqrtPriceX96;   // 0 if pool already exists
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external;

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96  nonce,
            address operator,
            address token0,
            address token1,
            int24   tickSpacing,
            int24   tickLower,
            int24   tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address to, uint256 tokenId) external;
}

// ─── Interface: Aerodrome CL Gauge ────────────────────────────────────────────
interface ICLGauge {
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
    function earned(address rewardToken, uint256 tokenId) external view returns (uint256);
    function rewardToken() external view returns (address);
    function nft() external view returns (address);
}

// ─── Interface: Aerodrome CL Pool ─────────────────────────────────────────────
interface ICLPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24   tick,
        uint16  observationIndex,
        uint16  observationCardinality,
        uint16  observationCardinalityNext,
        bool    unlocked
    );

    // ── Added for real-time fee calculation ──────────────────────────────────
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick) external view returns (
        uint128 liquidityGross,
        int128  liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        int56   tickCumulativeOutside,
        uint160 secondsPerLiquidityOutsideX128,
        uint32  secondsOutside,
        bool    initialized
    );

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    
}

interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing)
        external view returns (address pool);
}

// ─── Interface: BusinessSmartWallet (read-only surface) ───────────────────────
interface IBusinessSmartWallet {
    function owner() external view returns (address);
    function relayer() external view returns (address);
    function paused() external view returns (bool);
    function allowedTokens(address token) external view returns (bool);
    function approvers(address who) external view returns (uint256 amount, bool status, uint8 role);
    function autoApproveLimit() external view returns (uint256);
    function approveVaultSpend(address token, address spender, uint256 amount) external;
}

// ─── Interface: BusinessSmartWallet token approval bridge ─────────────────────
// The vault pulls ERC-20s from the wallet after the wallet's owner calls
// wallet.approveVaultSpend(token, vault, amount) — see the extension below.
/*interface IWalletApprovalBridge {
    function approveVaultSpend(address token, address spender, uint256 amount) external;
}*/

// ════════════════════════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ════════════════════════════════════════════════════════════════════════════════

contract BusinessAeroYieldVault is ReentrancyGuard, IERC721Receiver {

    using SafeERC20 for IERC20;

    // slot0 tick limits
    uint160 internal constant MIN_SQRT = 4295128739 + 1;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    struct CallbackData {
        address tokenIn;
        address payer;
        uint256 amountToPay;
    }

    // ─── Constants ───────────────────────────────────────────────────────────
    //address public constant POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    //address public constant AERO             = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address public POSITION_MANAGER;
    address public AERO;
    uint128 public constant MAX_COLLECT = type(uint128).max;
    
    address public clFactory; // = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    // Math constants for tick → sqrtPrice and fee arithmetic
    uint256 private constant Q96  = 1 << 96;
    uint256 private constant Q128 = 1 << 128;

    // C-1. Entry cost snapshot — written once at mintPosition(), updated by collectFees()
    struct EntryRecord {
        uint256 amount0In;              // actual token0 consumed at mint
        uint256 amount1In;              // actual token1 consumed at mint
        uint160 sqrtPriceAtEntry;       // pool sqrtPriceX96 at the moment of minting
        uint256 entryTimestamp;         // block.timestamp of mint
        uint256 totalFeesCollected0;    // running total of token0 fees swept to wallet
        uint256 totalFeesCollected1;    // running total of token1 fees swept to wallet
    }

    // C-2. Full read-only snapshot returned by snapshot()
    struct PositionSnapshot {
        // ── Identity ───────────────────────────────────────────────────────────
        uint256 tokenId;
        address token0;
        address token1;
        int24   tickSpacing;
        int24   tickLower;
        int24   tickUpper;
        uint128 liquidity;
        // ── Current price context ──────────────────────────────────────────────
        uint160 sqrtPriceX96;
        int24   currentTick;
        bool    inRange;
        // ── Locked token amounts right now ─────────────────────────────────────
        uint256 amount0;
        uint256 amount1;
        // ── Fees ───────────────────────────────────────────────────────────────
        uint256 fees0Uncollected;       // claimable token0 fees right now
        uint256 fees1Uncollected;       // claimable token1 fees right now
        uint256 fees0TotalEver;         // token0 fees already collected to wallet
        uint256 fees1TotalEver;         // token1 fees already collected to wallet
        // ── Gauge ──────────────────────────────────────────────────────────────
        bool    stakedInGauge;
        address gauge;
        uint256 pendingAero;            // AERO waiting to be claimed
        // ── Entry & P&L ────────────────────────────────────────────────────────
        uint256 amount0AtEntry;         // token0 deposited when position was opened
        uint256 amount1AtEntry;         // token1 deposited when position was opened
        uint160 sqrtPriceAtEntry;       // price at open
        uint256 entryTimestamp;
        // pnl = (locked + uncollectedFees + collectedEver) - entry cost
        int256  pnl0;
        int256  pnl1;
        uint256 ageSeconds;
    }

    // ─── Structs ─────────────────────────────────────────────────────────────
    struct PositionRecord {
        address  token0;
        address  token1;
        int24    tickSpacing;
        int24    tickLower;
        int24    tickUpper;
        uint128  liquidity;
        bool     stakedInGauge;
        address  gauge;            // address(0) if not staked
        uint256  depositedAt;
        bytes32  openRefNo;
        bool     active;
    }

    // Parameters bundle for mintPosition — avoids stack-too-deep
    struct MintPositionParams {
        address token0;
        address token1;
        int24   tickSpacing;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        uint160 sqrtPriceX96;      // pass 0 if pool already exists
    }

    // Parameters bundle for addLiquidity
    struct AddLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    // Parameters bundle for removeLiquidity
    struct RemoveLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;         // pass type(uint128).max to remove all
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    // ─── State ────────────────────────────────────────────────────────────────
    IBusinessSmartWallet public wallet;
    INonfungiblePositionManager public immutable positionManager;

    mapping(address => address)   public poolToGauge;      // CL pool ⇒ gauge
    mapping(uint256 => PositionRecord) public positions;   // tokenId ⇒ record
    uint256[] private _positionIds;
    mapping(uint256 => uint256) private _positionIndex;    // tokenId ⇒ array idx+1
    mapping(uint256 => EntryRecord) public entryRecords;

    

    // ─── Events ───────────────────────────────────────────────────────────────
    event PositionMinted(uint256 indexed tokenId, address indexed token0, address indexed token1, int24 tickSpacing, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0Used, uint256 amount1Used, bytes32 refNo);
    event LiquidityAdded(uint256 indexed tokenId, uint128 liquidityDelta, uint256 amount0, uint256 amount1, bytes32 refNo);
    event LiquidityRemoved(uint256 indexed tokenId, uint128 liquidityDelta, uint256 amount0, uint256 amount1, bytes32 refNo);
    event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1, bytes32 refNo);
    event PositionDepositedToGauge(uint256 indexed tokenId, address indexed gauge, bytes32 refNo);
    event PositionWithdrawnFromGauge(uint256 indexed tokenId, address indexed gauge, bytes32 refNo);
    event GaugeRewardsClaimed(uint256 indexed tokenId, address indexed rewardToken, uint256 amount, bytes32 refNo);
    event NFTDeposited(uint256 indexed tokenId, address indexed from, bytes32 refNo);
    event NFTWithdrawn(uint256 indexed tokenId, address indexed to, bytes32 refNo);
    event PositionClosed(uint256 indexed tokenId, uint256 amount0Returned, uint256 amount1Returned, bytes32 refNo);
    event TokensSweptToWallet(address indexed token, uint256 amount, bytes32 refNo);
    event GaugeRegistered(address indexed pool, address indexed gauge);
    event WalletUpdated(address indexed oldWallet, address indexed newWallet);
    event SwapExecuted(address indexed pool, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address recipient);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyWalletOwner() {
        require(msg.sender == wallet.owner(), "NOT_WALLET_OWNER");
        _;
    }

    modifier walletNotPaused() {
        require(!wallet.paused(), "WALLET_PAUSED");
        _;
    }

    modifier positionManaged(uint256 tokenId) {
        require(_positionIndex[tokenId] > 0, "POSITION_NOT_MANAGED");
        require(positions[tokenId].active,   "POSITION_CLOSED");
        _;
    }

    modifier positionNotStaked(uint256 tokenId) {
        require(!positions[tokenId].stakedInGauge, "POSITION_IN_GAUGE");
        _;
    }

    modifier positionStaked(uint256 tokenId) {
        require(positions[tokenId].stakedInGauge, "POSITION_NOT_IN_GAUGE");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _wallet,address _positionManager,address _aero,address _clFactory) {

        require(_positionManager != address(0), "ZERO_POSITION_MANAGER_ADDRESS");
        require(_aero != address(0), "ZERO_AERO_ADDRESS");
        require(_wallet != address(0), "ZERO_WALLET_ADDRESS");
        require(_clFactory != address(0), "Zero CL Factory");

        clFactory = _clFactory;
        POSITION_MANAGER = _positionManager;
        AERO = _aero;
        
        wallet = IBusinessSmartWallet(_wallet);
        positionManager = INonfungiblePositionManager(POSITION_MANAGER);
    }

    // ─── Admin: link wallet & register gauges ─────────────────────────────────

    /// @notice Update the linked BusinessSmartWallet (owner only, safety exit).
    function updateWallet(address _newWallet) external onlyWalletOwner {
        require(_newWallet != address(0), "ZERO_ADDRESS");
        address old = address(wallet);
        wallet = IBusinessSmartWallet(_newWallet);
        emit WalletUpdated(old, _newWallet);
    }

    /// @notice Register a CL gauge for a given pool address.
    /// @dev    Call once per pool. Validates that the gauge's nft matches the PM.
    function registerGauge(address pool, address gauge) external onlyWalletOwner {
        require(pool  != address(0), "ZERO_POOL");
        require(gauge != address(0), "ZERO_GAUGE");
        require(ICLGauge(gauge).nft() == POSITION_MANAGER, "GAUGE_NFT_MISMATCH");
        poolToGauge[pool] = gauge;
        emit GaugeRegistered(pool, gauge);
    }

    function _fundVaultFromWallet(address token, uint256 amount) internal {
        wallet.approveVaultSpend(token, address(this), amount);
        IERC20(token).safeTransferFrom(address(wallet), address(this), amount);
    }
    
    function swapExactInput(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
    ) external onlyWalletOwner  returns (uint256 amountOut) {

        require(address(wallet) != address(0), "NO_WALLET_LINKED");
        require(amountIn > 0, "ZERO_AMOUNT");
        require(wallet.allowedTokens(tokenOut), "TOKEN_NOT_ALLOWED");
        address recipient = address(wallet);
        ICLPool p = ICLPool(pool);
        bool zeroForOne = tokenIn < tokenOut; // token ordering by address

        wallet.approveVaultSpend(tokenIn,address(this),amountIn);
        IERC20(tokenIn).safeTransferFrom(address(wallet), address(this), amountIn);
        IERC20(tokenIn).forceApprove(pool, amountIn);

        (int256 amount0, int256 amount1) = p.swap(
            recipient,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT : MAX_SQRT,
            abi.encode(CallbackData({ tokenIn: tokenIn, payer: msg.sender, amountToPay: amountIn }))
        );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        require(amountOut >= amountOutMin, "Too little received");
        emit SwapExecuted(pool, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @dev Called by the pool to pull tokenIn from payer
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        CallbackData memory d = abi.decode(data, (CallbackData));
        uint256 pay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        //IERC20(d.tokenIn).transferFrom(d.payer, msg.sender, pay); // msg.sender is pool
        IERC20(decoded.tokenIn).safeTransfer(msg.sender,pay);
    }

    // ─── MINT POSITION ────────────────────────────────────────────────────────

    /// @notice Mint a new concentrated-liquidity NFT position.
    /// @dev    Tokens must already be in this vault (sent here via wallet's
    ///         spend mechanism or fundVault). Any unused tokens are swept back
    ///         to the wallet after minting.
    function mintPosition(
        MintPositionParams calldata p,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant returns (uint256 tokenId) {

        require(p.token0 < p.token1,    "TOKEN_ORDER: token0 must be < token1");
        require(p.amount0Desired > 0 || p.amount1Desired > 0, "ZERO_AMOUNTS");
        require(p.deadline > block.timestamp, "DEADLINE_PASSED");

        // Approve PM to spend vault's tokens
        _approvePositionManager(p.token0, p.amount0Desired);
        _approvePositionManager(p.token1, p.amount1Desired);

        uint128 liquidity;
        uint256 amount0Used;
        uint256 amount1Used;

        (tokenId, liquidity, amount0Used, amount1Used) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0:         p.token0,
                token1:         p.token1,
                tickSpacing:    p.tickSpacing,
                tickLower:      p.tickLower,
                tickUpper:      p.tickUpper,
                amount0Desired: p.amount0Desired,
                amount1Desired: p.amount1Desired,
                amount0Min:     p.amount0Min,
                amount1Min:     p.amount1Min,
                recipient:      address(this),
                deadline:       p.deadline,
                sqrtPriceX96:   p.sqrtPriceX96
            })
        );

        address pool = ICLFactory(clFactory).getPool(p.token0, p.token1, p.tickSpacing);
        uint160 sqrtPriceNow;
        if (pool != address(0)) {
            (sqrtPriceNow,,,,,) = ICLPool(pool).slot0();
        }

        entryRecords[tokenId] = EntryRecord({
            amount0In:           amount0Used,
            amount1In:           amount1Used,
            sqrtPriceAtEntry:    sqrtPriceNow,
            entryTimestamp:      block.timestamp,
            totalFeesCollected0: 0,
            totalFeesCollected1: 0
        });

        // Track the new position
        _trackPosition(
            tokenId,
            p.token0,
            p.token1,
            p.tickSpacing,
            p.tickLower,
            p.tickUpper,
            liquidity,
            refNo
        );

        // Reset PM allowances for safety
        _resetAllowance(p.token0);
        _resetAllowance(p.token1);

        // Return leftover tokens to wallet
        _sweepExcessToWallet(p.token0, refNo);
        _sweepExcessToWallet(p.token1, refNo);

        emit PositionMinted(
            tokenId,
            p.token0,
            p.token1,
            p.tickSpacing,
            p.tickLower,
            p.tickUpper,
            liquidity,
            amount0Used,
            amount1Used,
            refNo
        );
    }

    // ─── ADD LIQUIDITY ────────────────────────────────────────────────────────

    /// @notice Increase liquidity of an existing managed position.
    /// @dev    Tokens must already be in this vault before calling.
    ///         Unused tokens are swept back to the wallet.
    function addLiquidity(
        AddLiquidityParams calldata p,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant
      positionManaged(p.tokenId) positionNotStaked(p.tokenId)
      returns (uint128 liquidityDelta, uint256 amount0, uint256 amount1) {

        require(p.amount0Desired > 0 || p.amount1Desired > 0, "ZERO_AMOUNTS");
        require(p.deadline > block.timestamp, "DEADLINE_PASSED");

        PositionRecord storage rec = positions[p.tokenId];

        _approvePositionManager(rec.token0, p.amount0Desired);
        _approvePositionManager(rec.token1, p.amount1Desired);
        _fundVaultFromWallet(rec.token0, p.amount0Desired);
        _fundVaultFromWallet(rec.token1, p.amount1Desired);

        (liquidityDelta, amount0, amount1) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId:        p.tokenId,
                amount0Desired: p.amount0Desired,
                amount1Desired: p.amount1Desired,
                amount0Min:     p.amount0Min,
                amount1Min:     p.amount1Min,
                deadline:       p.deadline
            })
        );

        EntryRecord storage entry = entryRecords[p.tokenId];
        entry.amount0In += amount0;
        entry.amount1In += amount1;

        rec.liquidity += liquidityDelta;

        _resetAllowance(rec.token0);
        _resetAllowance(rec.token1);

        _sweepExcessToWallet(rec.token0, refNo);
        _sweepExcessToWallet(rec.token1, refNo);

        emit LiquidityAdded(p.tokenId, liquidityDelta, amount0, amount1, refNo);
    }

    // ─── REMOVE LIQUIDITY ─────────────────────────────────────────────────────

    /// @notice Decrease liquidity and collect the freed tokens.
    /// @dev    Pass `liquidity = type(uint128).max` to remove the full position.
    ///         Collected tokens are automatically swept to the wallet.
   function removeLiquidity(
        RemoveLiquidityParams calldata p,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant
    positionManaged(p.tokenId) positionNotStaked(p.tokenId)
    returns (uint256 amount0, uint256 amount1) {

        require(p.deadline > block.timestamp, "DEADLINE_PASSED");

        // FIX: single declaration — used throughout
        PositionRecord storage rec = positions[p.tokenId];

        // Resolve "remove all" shorthand
        uint128 liquidityToRemove = (p.liquidity == type(uint128).max)
            ? rec.liquidity
            : p.liquidity;

        require(liquidityToRemove > 0,              "ZERO_LIQUIDITY");
        require(liquidityToRemove <= rec.liquidity, "EXCEEDS_POSITION_LIQUIDITY");

        // Step 1: decrease — moves tokens into owed balances inside the PM
        positionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId:    p.tokenId,
                liquidity:  liquidityToRemove,
                amount0Min: p.amount0Min,
                amount1Min: p.amount1Min,
                deadline:   p.deadline
            })
        );

        // Step 2: collect — transfers owed tokens to this vault
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId:    p.tokenId,
                recipient:  address(this),
                amount0Max: MAX_COLLECT,
                amount1Max: MAX_COLLECT
            })
        );

        // Step 3: reduce cost basis proportionally BEFORE decrementing rec.liquidity
        // rec.liquidity is still the original full value here — that IS liquidityBefore
        EntryRecord storage entry = entryRecords[p.tokenId];
        if (rec.liquidity > 0) {
            entry.amount0In -= (entry.amount0In * uint256(liquidityToRemove)) / uint256(rec.liquidity);
            entry.amount1In -= (entry.amount1In * uint256(liquidityToRemove)) / uint256(rec.liquidity);
        }

        // Step 4: now decrement — must come after Step 3
        rec.liquidity -= liquidityToRemove;

        // Step 5: sweep both tokens to wallet
        _sweepExcessToWallet(rec.token0, refNo);
        _sweepExcessToWallet(rec.token1, refNo);

        emit LiquidityRemoved(p.tokenId, liquidityToRemove, amount0, amount1, refNo);
    }

    // ─── COLLECT FEES (not staked) ────────────────────────────────────────────

    /// @notice Collect accumulated trading fees from an unstaked position.
    /// @dev    When staked in a gauge, use claimGaugeRewards() instead.
    function collectFees(
        uint256 tokenId,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant
      positionManaged(tokenId) positionNotStaked(tokenId)
      returns (uint256 amount0, uint256 amount1) {

        PositionRecord storage rec = positions[tokenId];

        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId:    tokenId,
                recipient:  address(this),
                amount0Max: MAX_COLLECT,
                amount1Max: MAX_COLLECT
            })
        );

        EntryRecord storage entry = entryRecords[tokenId];
        entry.totalFeesCollected0 += amount0;
        entry.totalFeesCollected1 += amount1;

        _sweepExcessToWallet(rec.token0, refNo);
        _sweepExcessToWallet(rec.token1, refNo);

        emit FeesCollected(tokenId, amount0, amount1, refNo);
    }

    // ─── DEPOSIT TO GAUGE (stake for AERO rewards) ───────────────────────────

    /// @notice Stake the NFT in its registered CL gauge to earn AERO emissions.
    /// @dev    The vault approves the gauge, then calls gauge.deposit().
    ///         Requires the pool gauge to be registered via registerGauge().
    function depositToGauge(
        uint256 tokenId,
        address pool,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant
      positionManaged(tokenId) positionNotStaked(tokenId) {

        address gauge = poolToGauge[pool];
        require(gauge != address(0), "GAUGE_NOT_REGISTERED");

        PositionRecord storage rec = positions[tokenId];

        // Validate the position belongs to the correct pool
        _validatePositionPool(tokenId, pool, rec);

        // Approve gauge to pull the NFT, then stake
        positionManager.approve(gauge, tokenId);
        ICLGauge(gauge).deposit(tokenId);

        rec.stakedInGauge = true;
        rec.gauge         = gauge;

        emit PositionDepositedToGauge(tokenId, gauge, refNo);
    }

    // ─── WITHDRAW FROM GAUGE (unstake) ────────────────────────────────────────

    /// @notice Unstake the NFT from its gauge, returning it to vault custody.
    function withdrawFromGauge(
        uint256 tokenId,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant
      positionManaged(tokenId) positionStaked(tokenId) {

        PositionRecord storage rec = positions[tokenId];
        address gauge = rec.gauge;

        ICLGauge(gauge).withdraw(tokenId);

        rec.stakedInGauge = false;
        rec.gauge         = address(0);

        emit PositionWithdrawnFromGauge(tokenId, gauge, refNo);
    }

    // ─── CLAIM GAUGE REWARDS ──────────────────────────────────────────────────

    /// @notice Claim AERO (and any other) rewards from a staked position.
    ///         Claimed AERO is swept directly to the wallet.
    function claimGaugeRewards(
        uint256 tokenId,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant
      positionManaged(tokenId) positionStaked(tokenId) {

        PositionRecord storage rec = positions[tokenId];
        address gauge        = rec.gauge;
        address rewardToken  = ICLGauge(gauge).rewardToken();

        uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
        ICLGauge(gauge).getReward(tokenId);
        uint256 claimed   = IERC20(rewardToken).balanceOf(address(this)) - balBefore;

        if (claimed > 0) {
            IERC20(rewardToken).safeTransfer(address(wallet), claimed);
        }

        emit GaugeRewardsClaimed(tokenId, rewardToken, claimed, refNo);
    }

    // ─── DEPOSIT NFT (receive existing position into vault) ──────────────────

    /// @notice Accept an existing Slipstream NFT into the vault for management.
    /// @dev    Caller must first approve this contract on the position manager.
    ///         The vault records the position and begins tracking it.
    function depositNFT(
        uint256 tokenId,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant {

        require(_positionIndex[tokenId] == 0, "POSITION_ALREADY_MANAGED");
        require(
            positionManager.ownerOf(tokenId) == msg.sender,
            "NOT_NFT_OWNER"
        );

        // Pull position details from the PM
        (
            ,
            ,
            address token0,
            address token1,
            int24   tickSpacing,
            int24   tickLower,
            int24   tickUpper,
            uint128 liquidity,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);

        // Transfer the NFT to this vault
        positionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        _trackPosition(tokenId, token0, token1, tickSpacing, tickLower, tickUpper, liquidity, refNo);

        emit NFTDeposited(tokenId, msg.sender, refNo);
    }

    // ─── WITHDRAW NFT (send position out of vault) ────────────────────────────

    /// @notice Withdraw a managed NFT to an arbitrary recipient.
    /// @dev    Position must not be staked in a gauge.
    ///         After withdrawal the vault stops tracking this position.
    function withdrawNFT(
        uint256 tokenId,
        address to,
        bytes32 refNo
    ) external onlyWalletOwner nonReentrant
      positionManaged(tokenId) positionNotStaked(tokenId) {

        require(to != address(0), "ZERO_RECIPIENT");

        _removeTrackedPosition(tokenId);

        positionManager.safeTransferFrom(address(this), to, tokenId);

        emit NFTWithdrawn(tokenId, to, refNo);
    }

    // ─── CLOSE POSITION (full exit) ───────────────────────────────────────────

    /// @notice Full exit: unstake (if needed) → remove all liquidity →
    ///         collect all fees → burn the NFT → sweep proceeds to wallet.
    function closePosition(
        uint256 tokenId,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        bytes32 refNo
    ) external onlyWalletPowerUser walletNotPaused nonReentrant
      positionManaged(tokenId) {

        require(deadline > block.timestamp, "DEADLINE_PASSED");

        PositionRecord storage rec = positions[tokenId];

        // Step 1: unstake from gauge if needed
        if (rec.stakedInGauge) {
            address gauge       = rec.gauge;
            address rewardToken = ICLGauge(gauge).rewardToken();
            uint256 balBefore   = IERC20(rewardToken).balanceOf(address(this));

            ICLGauge(gauge).withdraw(tokenId);
            ICLGauge(gauge).getReward(tokenId);

            uint256 claimed = IERC20(rewardToken).balanceOf(address(this)) - balBefore;
            if (claimed > 0) {
                IERC20(rewardToken).safeTransfer(address(wallet), claimed);
                emit GaugeRewardsClaimed(tokenId, rewardToken, claimed, refNo);
            }

            rec.stakedInGauge = false;
            rec.gauge         = address(0);
            emit PositionWithdrawnFromGauge(tokenId, gauge, refNo);
        }

        uint256 amount0Returned;
        uint256 amount1Returned;

        // Step 2: remove all liquidity if any remains
        if (rec.liquidity > 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId:    tokenId,
                    liquidity:  rec.liquidity,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline:   deadline
                })
            );
        }

        // Step 3: collect all owed tokens (fees + removed liquidity)
        (amount0Returned, amount1Returned) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId:    tokenId,
                recipient:  address(this),
                amount0Max: MAX_COLLECT,
                amount1Max: MAX_COLLECT
            })
        );

        // Step 4: burn the empty NFT
        positionManager.burn(tokenId);

        // Step 5: remove from tracking
        _removeTrackedPosition(tokenId);

        // Step 6: sweep token proceeds to wallet
        _sweepExcessToWallet(rec.token0, refNo);
        _sweepExcessToWallet(rec.token1, refNo);

        emit PositionClosed(tokenId, amount0Returned, amount1Returned, refNo);
    }

    // ─── SWEEP TOKENS TO WALLET ───────────────────────────────────────────────

    /// @notice Manually sweep any ERC-20 balance held by the vault to the wallet.
    /// @dev    Use after collecting fees or if tokens are sent here directly.
    function sweepToWallet(
        address token,
        bytes32 refNo
    ) external onlyWalletPowerUser nonReentrant {
        require(token != address(0), "ZERO_TOKEN");
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal > 0, "NOTHING_TO_SWEEP");
        IERC20(token).safeTransfer(address(wallet), bal);
        emit TokensSweptToWallet(token, bal, refNo);
    }

    // ─── FUND VAULT FROM WALLET ───────────────────────────────────────────────

    /// @notice Pull ERC-20 tokens from the wallet into the vault.
    /// @dev    The wallet owner must first have called
    ///         wallet.approveVaultSpend(token, address(this), amount)
    ///         so that this contract is allowed to pull from the wallet.
    function fundVault(
        address token,
        uint256 amount
    ) external onlyWalletPowerUser walletNotPaused nonReentrant {
        require(token  != address(0), "ZERO_TOKEN");
        require(amount > 0,  "ZERO_AMOUNT");
        IERC20(token).safeTransferFrom(address(wallet), address(this), amount);
    }

    // ─── ERC-721 RECEIVER ─────────────────────────────────────────────────────

    /// @notice Allows the vault to receive NFTs via safeTransferFrom.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────────────────

    /// @notice Returns all managed position token IDs.
    function getAllPositionIds() external view returns (uint256[] memory) {
        return _positionIds;
    }

    /// @notice Returns the number of currently managed positions.
    function positionCount() external view returns (uint256) {
        return _positionIds.length;
    }

    /// @notice Returns true if a tokenId is currently managed by this vault.
    function isManaged(uint256 tokenId) external view returns (bool) {
        return _positionIndex[tokenId] > 0 && positions[tokenId].active;
    }

    /// @notice Returns the live position data directly from the PM for a token.
    function getLivePosition(uint256 tokenId)
        external view
        returns (
            address token0,
            address token1,
            int24   tickSpacing,
            int24   tickLower,
            int24   tickUpper,
            uint128 liquidity,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        (
            ,
            ,
            token0,
            token1,
            tickSpacing,
            tickLower,
            tickUpper,
            liquidity,
            ,
            ,
            tokensOwed0,
            tokensOwed1
        ) = positionManager.positions(tokenId);
    }

    /// @notice Returns unclaimed gauge rewards for a staked position.
    function pendingGaugeRewards(uint256 tokenId)
        external view
        positionManaged(tokenId)
        positionStaked(tokenId)
        returns (address rewardToken, uint256 amount)
    {
        address gauge = positions[tokenId].gauge;
        rewardToken   = ICLGauge(gauge).rewardToken();
        amount        = ICLGauge(gauge).earned(rewardToken, tokenId);
    }

    // ─── INTERNAL HELPERS ─────────────────────────────────────────────────────

    function _trackPosition(
        uint256 tokenId,
        address token0,
        address token1,
        int24   tickSpacing,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity,
        bytes32 refNo
    ) internal {
        _positionIds.push(tokenId);
        _positionIndex[tokenId] = _positionIds.length;   // 1-based

        positions[tokenId] = PositionRecord({
            token0:       token0,
            token1:       token1,
            tickSpacing:  tickSpacing,
            tickLower:    tickLower,
            tickUpper:    tickUpper,
            liquidity:    liquidity,
            stakedInGauge: false,
            gauge:        address(0),
            depositedAt:  block.timestamp,
            openRefNo:    refNo,
            active:       true
        });
    }

    function _removeTrackedPosition(uint256 tokenId) internal {
        uint256 idx      = _positionIndex[tokenId] - 1;  // convert to 0-based
        uint256 lastId   = _positionIds[_positionIds.length - 1];

        _positionIds[idx]         = lastId;
        _positionIndex[lastId]    = idx + 1;
        _positionIds.pop();

        delete _positionIndex[tokenId];
        positions[tokenId].active = false;
    }

    /// @dev Sweep the entire balance of `token` to the wallet (if nonzero).
    ///      Used internally after every liquidity operation.
    function _sweepExcessToWallet(address token, bytes32 refNo) internal {
        if (token == address(0)) return;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;
        IERC20(token).safeTransfer(address(wallet), bal);
        emit TokensSweptToWallet(token, bal, refNo);
    }

    function _approvePositionManager(address token, uint256 amount) internal {
        if (token == address(0) || amount == 0) return;
        IERC20(token).forceApprove(POSITION_MANAGER, amount);
    }

    function _resetAllowance(address token) internal {
        if (token == address(0)) return;
        IERC20(token).forceApprove(POSITION_MANAGER, 0);
    }

    /// @dev Validates the on-chain position data matches the pool's token pair.
    function _validatePositionPool(
        uint256 tokenId,
        address pool,
        PositionRecord storage rec
    ) internal view {
        address poolToken0 = ICLPool(pool).token0();
        address poolToken1 = ICLPool(pool).token1();
        int24   poolTick   = ICLPool(pool).tickSpacing();
        require(rec.token0      == poolToken0, "POOL_TOKEN0_MISMATCH");
        require(rec.token1      == poolToken1, "POOL_TOKEN1_MISMATCH");
        require(rec.tickSpacing == poolTick,   "POOL_TICK_SPACING_MISMATCH");
    }

    /// @notice Returns a complete real-time snapshot of a position.
    /// @param  tokenId  The Slipstream NFT token ID.
    /// @param  vault    Address of AerodromeSlipstreamVault (for entry records).
    ///                  Pass address(0) to skip P&L (no entry data required).

    function snapshot(uint256 tokenId)
        external view
        returns (PositionSnapshot memory s)
    {
        s.tokenId = tokenId;

        // ── 1. Raw position data from the Position Manager ────────────────────
        uint256 feeGrowthInside0Last;
        uint256 feeGrowthInside1Last;
        uint128 tokensOwed0;
        uint128 tokensOwed1;

        (
            ,                       // nonce
            ,                       // operator
            s.token0,
            s.token1,
            s.tickSpacing,
            s.tickLower,
            s.tickUpper,
            s.liquidity,
            feeGrowthInside0Last,
            feeGrowthInside1Last,
            tokensOwed0,
            tokensOwed1
        ) = positionManager.positions(tokenId);

        // ── 2. Resolve pool from factory ──────────────────────────────────────
        address pool = ICLFactory(clFactory).getPool(s.token0, s.token1, s.tickSpacing);
        require(pool != address(0), "POOL_NOT_FOUND");

        // ── 3. Current price and tick ─────────────────────────────────────────
        (s.sqrtPriceX96, s.currentTick,,,,) = ICLPool(pool).slot0();
        s.inRange = (s.currentTick >= s.tickLower && s.currentTick < s.tickUpper);

        // ── 4. Token amounts locked in the position at current price ──────────
        (s.amount0, s.amount1) = _snapshotAmounts(
            s.sqrtPriceX96,
            s.tickLower,
            s.tickUpper,
            s.liquidity
        );

        // ── 5. Real-time uncollected fees (feeGrowth delta method) ────────────
        (s.fees0Uncollected, s.fees1Uncollected) = _snapshotFees(
            pool,
            s.currentTick,
            s.tickLower,
            s.tickUpper,
            s.liquidity,
            feeGrowthInside0Last,
            feeGrowthInside1Last,
            tokensOwed0,
            tokensOwed1
        );

        // ── 6. Gauge data — read directly from vault's own PositionRecord ─────
        PositionRecord storage rec = positions[tokenId];
        s.stakedInGauge = rec.stakedInGauge;
        s.gauge         = rec.gauge;

        if (s.stakedInGauge && s.gauge != address(0)) {
            address rewardToken = ICLGauge(s.gauge).rewardToken();
            s.pendingAero = ICLGauge(s.gauge).earned(rewardToken, tokenId);
        }

        // ── 7. Entry record — read directly from vault's own EntryRecord ──────
        EntryRecord storage entry = entryRecords[tokenId];

        s.amount0AtEntry   = entry.amount0In;
        s.amount1AtEntry   = entry.amount1In;
        s.sqrtPriceAtEntry = entry.sqrtPriceAtEntry;
        s.entryTimestamp   = entry.entryTimestamp;
        s.fees0TotalEver   = entry.totalFeesCollected0;
        s.fees1TotalEver   = entry.totalFeesCollected1;

        if (s.entryTimestamp > 0) {
            s.ageSeconds = block.timestamp - s.entryTimestamp;
        }

        // ── 8. P&L ────────────────────────────────────────────────────────────
        // Total return = still locked + claimable now + already swept to wallet
        // P&L          = total return − what was deposited at open
        if (s.amount0AtEntry > 0 || s.amount1AtEntry > 0) {
            int256 total0 = int256(s.amount0 + s.fees0Uncollected + s.fees0TotalEver);
            int256 total1 = int256(s.amount1 + s.fees1Uncollected + s.fees1TotalEver);
            s.pnl0 = total0 - int256(s.amount0AtEntry);
            s.pnl1 = total1 - int256(s.amount1AtEntry);
        }
    }

    // ── Batch: snapshot every managed position in one call ────────────────────

    /// @notice Snapshot all positions currently managed by this vault.
    function snapshotAll()
        external view
        returns (PositionSnapshot[] memory results)
    {
        uint256[] memory ids = this.getAllPositionIds();
        results = new PositionSnapshot[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            results[i] = this.snapshot(ids[i]);
        }
    }
    

    // ─── FEES ONLY ────────────────────────────────────────────────────────────

    /// @notice Returns only uncollected fees for a position.
    ///         Cheaper call — use this for fee dashboards.
    function pendingFees(uint256 tokenId)
        external view
        returns (uint256 fees0, uint256 fees1)
    {
        (
            ,
            ,
            address token0,
            address token1,
            int24   tickSpacing,
            int24   tickLower,
            int24   tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = IPositionManager(POSITION_MANAGER).positions(tokenId);

        address pool = ICLFactory(clFactory).getPool(token0, token1, tickSpacing);
        require(pool != address(0), "POOL_NOT_FOUND");

        (, int24 currentTick,,,,) = ICLPool(pool).slot0();

        (fees0, fees1) = _getFees(
            pool,
            currentTick,
            tickLower,
            tickUpper,
            liquidity,
            feeGrowthInside0Last,
            feeGrowthInside1Last,
            tokensOwed0,
            tokensOwed1
        );
    }

    // ─── AMOUNTS ONLY ─────────────────────────────────────────────────────────

    /// @notice Returns only the current locked token amounts in a position.
    function currentAmounts(uint256 tokenId)
        external view
        returns (uint256 amount0, uint256 amount1, bool inRange)
    {
        (
            ,
            ,
            address token0,
            address token1,
            int24   tickSpacing,
            int24   tickLower,
            int24   tickUpper,
            uint128 liquidity,
            ,
            ,
            ,

        ) = IPositionManager(POSITION_MANAGER).positions(tokenId);

        address pool = ICLFactory(clFactory).getPool(token0, token1, tickSpacing);
        require(pool != address(0), "POOL_NOT_FOUND");

        (uint160 sqrtPriceX96, int24 currentTick,,,,) = ICLPool(pool).slot0();

        inRange = (currentTick >= tickLower && currentTick < tickUpper);
        (amount0, amount1) = _getAmounts(sqrtPriceX96, tickLower, tickUpper, liquidity);
    }
}

