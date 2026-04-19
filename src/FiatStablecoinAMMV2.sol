// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// =============================================================
// FiatStablecoinAMM — cNGN / USD Corridor
// Security fixes applied (see audit report for full detail)
// =============================================================

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// -------------------------------------------------------
// FEE VAULT — import sibling contract
// -------------------------------------------------------
// FiatStablecoinAMMFee must be compiled in the same project.
// The AMM holds a typed reference so the compiler validates
// all call signatures at compile time.
// -------------------------------------------------------

import "./FiatStablecoinAMMFeeV2.sol";

contract FiatStablecoinAMMV2 is Ownable, ReentrancyGuard, EIP712 {

    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // -------------------------------------------------------
    // FEE VAULT
    // -------------------------------------------------------

    FiatStablecoinAMMFeeV2 public feeVault;

    // -------------------------------------------------------
    // TOKENS
    // -------------------------------------------------------

    IERC20  public immutable cNGN;
    IERC20  public immutable USD;

    /// @dev Read from token metadata at deploy time — avoids hardcoded DECIMALS
    ///      assumption. USDC/USDT = 1e6; DAI = 1e18.
    uint256 public immutable USD_SCALE;

    // -------------------------------------------------------
    // ACCESS CONTROL — 2-STEP TRANSFER PATTERN
    // -------------------------------------------------------

    /// @dev Treasury address. Use proposeTreasury/acceptTreasury to change.
    address public platformTreasury;
    address public pendingTreasury;

    /// @dev Oracle address. Use proposeOracle/acceptOracle to change.
    address public oracleManager;
    address public pendingOracleManager;

    /// @dev Whitelist for LPs and traders
    mapping(address => bool) public lpWhitelisted;

    // -------------------------------------------------------
    // PRICE — COMMIT-REVEAL (MEV / Oracle Sandwich Mitigation)
    // -------------------------------------------------------
    //
    // Oracle commits a price with a mandatory delay before it takes effect.
    // Any MEV bot watching the mempool cannot profitably frontrun because
    // the new rate only activates after `priceUpdateDelay` seconds.
    // After delay elapses, *anyone* can call applyPrice() — permissionless
    // finalization prevents the oracle from suppressing a committed update.
    // -------------------------------------------------------

    uint256 public midPrice;
    uint256 public halfSpread;         // set in constructor
    uint256 public buyRate;
    uint256 public sellRate;

    uint256 public pendingPrice;
    uint256 public priceActiveAt;
    uint256 public priceUpdateDelay = 60;  // seconds; owner-adjustable

    uint256 public lastPriceUpdate;
    uint256 public maxPriceAge = 2 hours;  // owner-adjustable

    // -------------------------------------------------------
    // EPOCH RATE LIMITER (Pool Drain Mitigation)
    // -------------------------------------------------------
    //
    // Each whitelisted address is limited to maxEpochVolumeBps of the
    // relevant pool depth per epochDuration window. Prevents a compromised
    // or malicious whitelisted address from draining the pool across
    // multiple consecutive blocks.
    // -------------------------------------------------------

    mapping(address => uint256) public epochVolumeUSD;
    mapping(address => uint256) public epochVolumeCNGN;
    mapping(address => uint256) public epochStart;

    uint256 public epochDuration     = 1 hours;
    uint256 public maxEpochVolumeBps = 5000;    // 50% of pool per user per epoch
    bool public swapsPaused;
    //bool public enableSwapCheck;

    uint256 public constant MAX_PRICE_DEVIATION_BPS = 500; // 5%
    uint256 public lastSafePrice;
    uint256 public pauseTimestamp;
    uint256 public constant PAUSE_COOLDOWN = 15 minutes;

    //mapping(address => uint256) public liquiditySnapshot;
    //mapping(address => uint256) public lastLiquidityCheck;
    mapping(address => uint256) public liquidityHighWaterMark;
    mapping(address => uint256) public liquidityWindowStart;
    uint256 public drainObservationWindow = 1 hours;

    uint256 public constant MAX_LIQUIDITY_DRAIN_BPS = 1000; // 10%
    
    mapping(address => uint256) public lastTradeBlock;
    mapping(address => uint256) public minLiquidity;
    uint256 public constant MIN_FEE = 1e3;
    uint256 public MIN_TRADE_USD = 70_000; //$0.07
    uint256 public MIN_TRADE_CNGN = 100_000_000;   // ₦100

    uint256 public maxSwapBps = 1000; // 10% of pool
    uint256 public constant MIN_SWAP_BPS = 10; //0.1% of pool
    uint256 public constant MAX_SWAP_BPS_CAP = 2000; // 20% of pool
    uint256 public swapCheckOverrideExpiry;
    uint256 public constant MAX_SWAP_CHECK_OVERRIDE = 1 hours;

    bool public swapCheckEnabled = true;
      

    // -------------------------------------------------------
    // POOL ACCOUNTING
    // -------------------------------------------------------
    //
    // poolDeposits tracks LP-deposited capital for each token
    // independently of balanceOf(). This prevents flash-loan
    // inflation of pool balance from manipulating share prices
    // on addLiquidity.
    //
    // Updated on:
    //   - addLiquidity    (+amount)
    //   - removeLiquidity (-amount)
    //   - _swapNGN        (USD: -gross, cNGN: +ngnAmount)
    //   - _swapUSD        (cNGN: -gross, USD: +usdAmount)
    // -------------------------------------------------------

    mapping(address => uint256) public poolDeposits;

    // -------------------------------------------------------
    // NONCES (META-TX / EIP-712)
    // -------------------------------------------------------

    mapping(address => uint256) public nonces;

    // -------------------------------------------------------
    // EIP712 TYPE HASHES
    // -------------------------------------------------------

    bytes32 public constant SWAP_NGN_TYPEHASH =
        keccak256("SwapNGN(address signer,uint256 ngnAmount,uint256 minUSD,uint256 nonce,uint256 deadline)");

    bytes32 public constant SWAP_USD_TYPEHASH =
        keccak256("SwapUSD(address signer,uint256 usdAmount,uint256 minNGN,uint256 nonce,uint256 deadline)");

    bytes32 public constant ADD_LP_TYPEHASH =
        keccak256("AddLP(address signer,address token,uint256 amount,uint256 nonce,uint256 deadline)");

    bytes32 public constant REMOVE_LP_TYPEHASH =
        keccak256("RemoveLP(address signer,address token,uint256 shares,uint256 nonce,uint256 deadline)");

    bytes32 public constant CLAIM_LP_TYPEHASH =
        keccak256("ClaimLP(address signer,address token,uint256 nonce,uint256 deadline)");

    // -------------------------------------------------------
    // FEES
    // -------------------------------------------------------

    uint256 public constant FEE_DENOM = 10_000;

    uint256 public swapFeeBps     = 10;    // 0.10%
    uint256 public lpShareBps     = 7_000; // 70% of fee to LPs
    uint256 public platformShareBps = 3_000; // 30% of fee to treasury

    // -------------------------------------------------------
    // LIMITS
    // -------------------------------------------------------

    uint256 public constant MAX_WITHDRAW_BPS = 2_000; // 20% per tx
    uint256 public constant MAX_SWAP_FEE_BPS =   200; // hard cap: 2%

    // -------------------------------------------------------
    // ANALYTICS — DAILY BUCKETS
    // -------------------------------------------------------
    //
    // dayId = block.timestamp / 86400  (Unix day number, UTC)
    //
    // On-chain daily snapshots let a frontend call getDay(today)
    // without any off-chain indexer.  All-time totals are kept
    // separately so they never need a range scan.
    //
    // GAS NOTE: each DailyStats slot costs ~6 cold SSTOREs on
    // first write of the day (~120k gas) and ~6 warm SSTOREs
    // thereafter (~12k gas).  Acceptable for a whitelisted,
    // low-frequency corridor AMM.
    // -------------------------------------------------------

    struct DailyStats {
        // --- Swap volume ---
        uint256 swapVolumeNGN;       // cNGN in  (NGN→USD swaps)
        uint256 swapVolumeUSD;       // USD in   (USD→NGN swaps)
        uint256 swapCountNGN;        // number of NGN→USD swaps
        uint256 swapCountUSD;        // number of USD→NGN swaps
        // --- Fees generated (split already applied) ---
        uint256 lpFeeUSD;            // USD lpFee credited to vault
        uint256 lpFeeCNGN;           // cNGN lpFee credited to vault
        uint256 platformFeeUSD;      // USD platformFee → treasury
        uint256 platformFeeCNGN;     // cNGN platformFee → treasury
        // --- Liquidity flows ---
        uint256 liquidityAddedUSD;
        uint256 liquidityAddedCNGN;
        uint256 liquidityRemovedUSD;
        uint256 liquidityRemovedCNGN;
    }

    /// @dev UTC day number → stats for that day
    mapping(uint256 => DailyStats) public dailyStats;

    // All-time cumulative totals (no range scan needed)
    uint256 public totalSwapVolumeNGN;
    uint256 public totalSwapCountNGN;
    uint256 public totalSwapVolumeUSD;
    uint256 public totalSwapCountUSD;
    uint256 public totalLpFeeUSD;
    uint256 public totalLpFeeCNGN;
    uint256 public totalPlatformFeeUSD;
    uint256 public totalPlatformFeeCNGN;

    /// @notice Returns the current UTC day number (block.timestamp / 86400).
    function today() public view returns (uint256) {
        return block.timestamp / 86400;
    }

    // -------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------

    event Swap(
        address indexed user,
        uint256 inAmount,
        uint256 outAmount,
        uint256 lpFee,          // fee portion credited to LP vault
        uint256 platformFee,    // fee portion sent to treasury
        bool    ngnToUsd,       // true = NGN→USD, false = USD→NGN
        bool    meta
    );
    event LiquidityAdded(
        address indexed lp,
        address indexed token,
        uint256 amount,
        uint256 shares,
        bool    meta
    );
    event LiquidityRemoved(
        address indexed lp,
        address indexed token,
        uint256 amount,
        uint256 shares,
        bool    meta
    );
    event LPFeeClaimed(address indexed lp, address indexed token);
    event MetaTxExecuted(
        address indexed signer,
        address indexed relayer,
        bytes32         typehash,
        uint256         nonce
    );
    event UserWhitelisted(address indexed lp, bool allowed);
    event PriceCommitted(uint256 price, uint256 activeAt);
    event PriceApplied(uint256 midPrice, uint256 buyRate, uint256 sellRate);
    event TreasuryProposed(address indexed proposed);
    event TreasuryAccepted(address indexed treasury);
    event OracleProposed(address indexed proposed);
    event OracleAccepted(address indexed oracle);
    event FeeVaultUpdated(address indexed vault);
    event SpreadUpdated(uint256 halfSpread);
    event SwapFeeUpdated(uint256 swapFeeBps);
    event LpShareUpdated(uint256 lpShareBps, uint256 platformShareBps);
    event EpochParamsUpdated(uint256 duration, uint256 maxBps);
    event SwapsPaused(uint256 newPrice, uint256 deviationBps);
    event SwapsResumed(address by);
    event EmergencyPause(address triggeredBy);
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);
    event PriceUpdateDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event PriceExpired(uint256 price);
    event MinTradeUSDUpdated(uint256 oldMin, uint256 newMin);
    event MinTradeCNGNUpdated(uint256 oldMin, uint256 newMin);
    event DrainWindowUpdated(uint256 oldWindow, uint256 newWindow);

    event SwapCheckEnabled(address indexed by);
    event SwapCheckDisabled(address indexed by, uint256 expiresAt);
    event MaxSwapBpsUpdated(uint256 oldBps, uint256 newBps);

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    constructor(
        address _cNGN,
        address _USD,
        address _treasury,
        address _oracleManager,
        uint256 _halfSpread,
        uint256 _price
    )
        Ownable(msg.sender)
        EIP712("FiatStablecoinAMMV2", "1")
    {
        require(
            _cNGN     != address(0) &&
            _USD      != address(0) &&
            _treasury != address(0),
            "zero address"
        );

        require(IERC20Metadata(_USD).decimals() == 6, "USD must be 6 decimals");
        require(IERC20Metadata(_cNGN).decimals() == 6, "cNGN must be 6 decimals");

        cNGN             = IERC20(_cNGN);
        USD              = IERC20(_USD);
        USD_SCALE        = 10 ** IERC20Metadata(_USD).decimals();

        require(_oracleManager != address(0),"zero oracle address");
        require(_price > 0, "invalid price");

        platformTreasury = _treasury;
        oracleManager    = _oracleManager;
        //feeVault         = FiatStablecoinAMMFee(_feeVault);
        halfSpread       = _halfSpread;

        midPrice         = _price;
        buyRate          = midPrice + halfSpread;
        sellRate         = midPrice - halfSpread;
        lastPriceUpdate  = block.timestamp;
        pendingPrice     = 0;

        minLiquidity[_USD] = 20 * 10 ** IERC20Metadata(_USD).decimals();
        minLiquidity[_cNGN] = 1_000 * 10 ** IERC20Metadata(_cNGN).decimals();

        maxSwapBps       = 1000;   // 10% of pool per swap
        swapCheckEnabled = true;
    }

    // -------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------

    modifier onlyOracleManager() {
        require(msg.sender == oracleManager, "only oracle");
        _;
    }

    modifier onlyWhitelistedUser() {
        require(lpWhitelisted[msg.sender], "not whitelisted");
        _;
    }

    /// @dev Restricts LP operations to cNGN or USD only.
    ///      Prevents arbitrary ERC20 tokens polluting vault state.
    modifier onlyValidToken(address token) {
        require(
            token == address(cNGN) || token == address(USD),
            "invalid token"
        );
        _;
    }

    modifier swapsNotPaused() {
        require(!swapsPaused, "swaps paused");
        _;
    }

    /// @dev Reverts if price hasn't been updated within maxPriceAge.
    ///      Protects LPs from arbitrage on stale rates when oracle is down.
    modifier priceNotStale() {
       require(
            lastPriceUpdate != 0 &&
            block.timestamp <= lastPriceUpdate + maxPriceAge,
            "price stale"
        );
        _;
    }

    // -------------------------------------------------------
    // ADMIN — WHITELIST
    // -------------------------------------------------------

    function whitelistLP(address lp, bool allowed) external onlyOwner {
        lpWhitelisted[lp] = allowed;
        emit UserWhitelisted(lp, allowed);
    }

    function isLPWhitelisted(address lp) external view returns (bool) {
        return lpWhitelisted[lp];
    }

    // -------------------------------------------------------
    // ADMIN — 2-STEP TREASURY TRANSFER
    // -------------------------------------------------------

    /// @notice Owner proposes a new treasury. Must be accepted by the new address.
    ///         Prevents accidentally sending all platform fees to a wrong address.
    function proposeTreasury(address _new) external onlyOwner {
        require(_new != address(0), "zero address");
        pendingTreasury = _new;
        emit TreasuryProposed(_new);
    }

    function acceptTreasury() external {
        require(msg.sender == pendingTreasury, "not pending treasury");
        platformTreasury = pendingTreasury;
        pendingTreasury  = address(0);
        emit TreasuryAccepted(platformTreasury);
    }

    // -------------------------------------------------------
    // ADMIN — 2-STEP ORACLE MANAGER TRANSFER
    // -------------------------------------------------------

    function proposeOracle(address _new) external onlyOwner {
        require(_new != address(0), "zero address");
        pendingOracleManager = _new;
        emit OracleProposed(_new);
    }

    function acceptOracle() external {
        require(msg.sender == pendingOracleManager, "not pending oracle");
        oracleManager        = pendingOracleManager;
        pendingOracleManager = address(0);
        emit OracleAccepted(oracleManager);
    }

    // -------------------------------------------------------
    // ADMIN — FEE VAULT
    // -------------------------------------------------------

    function setFeeVault(address _vault) external onlyOwner {
        require(_vault != address(0), "zero address");
        require(_vault.code.length > 0, "not a contract");
        feeVault = FiatStablecoinAMMFeeV2(_vault);
        emit FeeVaultUpdated(_vault);
    }

    // -------------------------------------------------------
    // ADMIN — TUNABLE PARAMS
    // -------------------------------------------------------

    function setHalfSpread(uint256 _spread) external onlyOwner {
        require(_spread < midPrice / 10, "spread too large");
        halfSpread = _spread;
        emit SpreadUpdated(_spread);
    }

    /// @dev Hard cap of 2% prevents accidental fee misconfiguration.
    function setSwapFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_SWAP_FEE_BPS, "fee too high");
        require(_bps > 0, "zero fee rate");
        require(Math.mulDiv(MIN_TRADE_USD,  _bps, FEE_DENOM) > 0,"new fee rate: USD min trade too small");
        require(Math.mulDiv(MIN_TRADE_CNGN, _bps, FEE_DENOM) > 0,"new fee rate: NGN min trade too small");
        swapFeeBps = _bps;
        emit SwapFeeUpdated(_bps);
    }

    /// @dev Setting lpShareBps auto-calculates platformShareBps to keep sum == FEE_DENOM.
    function setLpShareBps(uint256 _bps) external onlyOwner {
        require(_bps <= FEE_DENOM, "exceeds denom");
        lpShareBps      = _bps;
        platformShareBps = FEE_DENOM - _bps;
        emit LpShareUpdated(_bps, platformShareBps);
    }

    function setEpochParams(uint256 _duration, uint256 _maxBps) external onlyOwner {
        require(_maxBps <= FEE_DENOM, "exceeds denom");
        epochDuration     = _duration;
        maxEpochVolumeBps = _maxBps;
        emit EpochParamsUpdated(_duration, _maxBps);
    }

    function setMaxPriceAge(uint256 _age) external onlyOwner {
        require(_age >= 1 minutes && _age <= 24 hours, "invalid age");
        require(priceUpdateDelay < _age, "delay must be < max age");
        uint256 old = maxPriceAge;
        maxPriceAge = _age;

        emit MaxPriceAgeUpdated(old, _age);
    }

    function setPriceUpdateDelay(uint256 _delay) external onlyOwner {
        require(_delay >= 10 seconds && _delay <= 10 minutes, "invalid delay");
        require(_delay < maxPriceAge, "delay must be < max age");
        uint256 old = priceUpdateDelay;
        priceUpdateDelay = _delay;

        emit PriceUpdateDelayUpdated(old, _delay);
    }

    function _requireFeeNonZeroAtMin(uint256 minAmount) internal view {
        require(
            Math.mulDiv(minAmount, swapFeeBps, FEE_DENOM) > 0,
            "min trade too small: fee would round to zero at current fee rate"
        );
    }

    function setMinTradeUSD(uint256 _minUSD) external onlyOwner {
        require(_minUSD > 0, "zero min trade");
        _requireFeeNonZeroAtMin(_minUSD);
        uint256 old = MIN_TRADE_USD;
        MIN_TRADE_USD = _minUSD;
        emit MinTradeUSDUpdated(old, _minUSD);
    }

    function setMinTradeCNGN(uint256 _minCNGN) external onlyOwner {
        require(_minCNGN > 0, "zero min trade");
        _requireFeeNonZeroAtMin(_minCNGN);
        uint256 old = MIN_TRADE_CNGN;
        MIN_TRADE_CNGN = _minCNGN;
        emit MinTradeCNGNUpdated(old, _minCNGN);
    }
    function setDrainWindow(uint256 _window) external onlyOwner {
        require(_window >= 15 minutes && _window <= 24 hours, "invalid window");
        uint256 old = drainObservationWindow;
        drainObservationWindow = _window;
        emit DrainWindowUpdated(old, _window);
    }

    function setMaxSwapBps(uint256 _bps) external onlyOwner {
        require(_bps >= MIN_SWAP_BPS,    "swap cap below minimum");
        require(_bps <= MAX_SWAP_BPS_CAP, "swap cap above maximum");
        uint256 old = maxSwapBps;
        maxSwapBps  = _bps;
        emit MaxSwapBpsUpdated(old, _bps);
    }

    function disableSwapCheck(uint256 duration) external onlyOwner {
        require(duration > 0,   "zero duration");
        require(duration <= MAX_SWAP_CHECK_OVERRIDE,  "duration exceeds maximum");

        swapCheckEnabled        = false;
        swapCheckOverrideExpiry = block.timestamp + duration;

        emit SwapCheckDisabled(msg.sender, swapCheckOverrideExpiry);
    }

    function enableSwapCheck() external onlyOwner {
        swapCheckEnabled        = true;
        swapCheckOverrideExpiry = 0;
        emit SwapCheckEnabled(msg.sender);
    }

    // -------------------------------------------------------
    // PRICE MANAGEMENT — COMMIT-REVEAL
    // -------------------------------------------------------

    /// @notice Oracle commits a price. Does NOT take effect immediately.
    ///         The `priceActiveAt` delay gives LPs and traders time to
    ///         react before the new rate becomes tradeable, eliminating
    ///         the oracle sandwich MEV attack vector.
    function commitPrice(uint256 price) external onlyOracleManager {
        // FIX L-02: Guard against sellRate underflow on apply
        require(price > halfSpread, "price must exceed spread");
        if (pendingPrice != 0) {
            require(msg.sender == owner() || msg.sender == oracleManager, "pending exists");
        }
        //require(pendingPrice == 0, "pending price exists");
        (uint256 minPrice, uint256 maxPrice) = _getPriceBounds();
        require(price < maxPrice && price > minPrice, "price out of bounds");
        pendingPrice  = price;
        priceActiveAt = block.timestamp + priceUpdateDelay;
        emit PriceCommitted(price, priceActiveAt);
    }

    function _getPriceBounds() internal view returns (uint256 minPrice, uint256 maxPrice) {
        if (lastSafePrice == 0) {
            // bootstrap case — allow first price
            return (0, type(uint256).max);
        }

        uint256 range = Math.mulDiv(lastSafePrice, MAX_PRICE_DEVIATION_BPS, FEE_DENOM);

        minPrice = lastSafePrice - range;
        maxPrice = lastSafePrice + range;
    }

    /// @notice Anyone can finalise the committed price after the delay.
    ///         Permissionless so oracle infrastructure failure doesn't
    ///         permanently suppress a pending update.
    function applyPrice() external {
        require(pendingPrice > 0, "no pending price");
        require(block.timestamp >= priceActiveAt, "delay not elapsed");

        /*if (block.timestamp < priceActiveAt) {
            revert("delay not elapsed");
        }*/

        // Handle expiry safely
        if (block.timestamp > priceActiveAt + 5 minutes) {
            emit PriceExpired(pendingPrice);
            pendingPrice = 0;
            return; //revert("price expired");
        }

        uint256 newPrice = pendingPrice;
        pendingPrice     = 0;  

        _checkPriceDeviation(newPrice);
        //require(!swapsPaused, "price deviation too high");

        midPrice        = newPrice;
        buyRate         = midPrice + halfSpread;
        sellRate        = midPrice - halfSpread;
        lastPriceUpdate = block.timestamp;

        emit PriceApplied(midPrice, buyRate, sellRate);
    }

    function unpauseSwaps() external onlyOwner {

         require(swapsPaused, "not paused");
        require(block.timestamp <= lastPriceUpdate + maxPriceAge,"price stale");
        swapsPaused = false;
        emit SwapsResumed(msg.sender);
    }

    function autoUnpause() external  {
        require(swapsPaused, "not paused");
        require(msg.sender == owner(), "only owner can auto unpause");
        require(block.timestamp >= pauseTimestamp + PAUSE_COOLDOWN,"cooldown active");

        require(block.timestamp <= lastPriceUpdate + maxPriceAge,"price stale");

        require(_checkLiquidityRecovered(), "liquidity not recovered");

        swapsPaused = false;

        emit SwapsResumed(msg.sender);
    }

    function _checkLiquidityRecovered() internal view returns (bool) {
        uint256 usdPool = poolDeposits[address(USD)];
        uint256 ngnPool = poolDeposits[address(cNGN)];

        // Pool floors must be met.
        if (
            usdPool < minLiquidity[address(USD)] ||
            ngnPool < minLiquidity[address(cNGN)]
        ) {
            return false;
        }

        // If no HWM has been established yet, consider recovered.
        if (
            liquidityHighWaterMark[address(USD)]  == 0 &&
            liquidityHighWaterMark[address(cNGN)] == 0
        ) {
            return true;
        }

        uint256 maxDrainBps = 0;

        if (liquidityHighWaterMark[address(USD)] > 0) {
            uint256 usdDiff = liquidityHighWaterMark[address(USD)] > usdPool
                ? liquidityHighWaterMark[address(USD)] - usdPool
                : 0;
            uint256 usdDrainBps = Math.mulDiv(
                usdDiff, FEE_DENOM, liquidityHighWaterMark[address(USD)]
            );
            if (usdDrainBps > maxDrainBps) maxDrainBps = usdDrainBps;
        }

        if (liquidityHighWaterMark[address(cNGN)] > 0) {
            uint256 ngnDiff = liquidityHighWaterMark[address(cNGN)] > ngnPool
                ? liquidityHighWaterMark[address(cNGN)] - ngnPool
                : 0;
            uint256 ngnDrainBps = Math.mulDiv(
                ngnDiff, FEE_DENOM, liquidityHighWaterMark[address(cNGN)]
            );
            if (ngnDrainBps > maxDrainBps) maxDrainBps = ngnDrainBps;
        }

        return maxDrainBps <= MAX_LIQUIDITY_DRAIN_BPS;
    }

    

     // -------------------------------------------------------
    // EPOCH LIMITER — INTERNAL
    // -------------------------------------------------------

    function _checkEpochLimit(
        address user,
        uint256 amount,
        uint256 pool,
        bool    isUSD
    )
        internal
    {
        // Reset counters when a new epoch begins
        if (block.timestamp >= epochStart[user] + epochDuration) {
            epochStart[user]      = block.timestamp;
            epochVolumeUSD[user]  = 0;
            epochVolumeCNGN[user] = 0;
        }

        uint256 cap = Math.mulDiv(pool, maxEpochVolumeBps, FEE_DENOM);

        if (isUSD) {
            epochVolumeUSD[user] += amount;
            require(epochVolumeUSD[user] <= cap, "USD epoch cap exceeded");
        } else {
            epochVolumeCNGN[user] += amount;
            require(epochVolumeCNGN[user] <= cap, "NGN epoch cap exceeded");
        }
    }

    function _checkPriceDeviation(uint256 newPrice) internal {
        if (lastSafePrice == 0) {
            lastSafePrice = newPrice;
            return;
        }

        uint256 diff;

        if (newPrice > lastSafePrice) {
            diff = newPrice - lastSafePrice;
        } else {
            diff = lastSafePrice - newPrice;
        }

        uint256 deviationBps = Math.mulDiv(diff, FEE_DENOM, lastSafePrice);

        if (deviationBps > MAX_PRICE_DEVIATION_BPS) {
            swapsPaused = true;
            pauseTimestamp = block.timestamp; // ✅ ADD THIS
            lastSafePrice = newPrice;
            emit SwapsPaused(newPrice, deviationBps);
        } else {
            lastSafePrice = newPrice;
        }
        
    }

    function _checkSwapSize(uint256 amount, uint256 pool) internal {
        // Auto-expire any temporary override.
        // Written as a state mutation here (rather than purely in the setter)
        // so the cap re-engages even if the owner never calls enableSwapCheck()
        // after a disable — e.g. if the owner key is unavailable.
        if (
            !swapCheckEnabled &&
            swapCheckOverrideExpiry != 0 &&
            block.timestamp >= swapCheckOverrideExpiry
        ) {
            swapCheckEnabled        = true;
            swapCheckOverrideExpiry = 0;
            emit SwapCheckEnabled(address(0));  // address(0) signals auto-expiry
        }

        if (!swapCheckEnabled) {
            // Override is active and has not yet expired. No cap enforced.
            return;
        }

        // Pool must be non-zero to avoid division by zero in mulDiv.
        // (Callers _swapNGN/_swapUSD already require pool > 0, but guard here
        // makes _checkSwapSize safe to call from any future context.)
        if (pool == 0) return;

        uint256 cap = Math.mulDiv(pool, maxSwapBps, FEE_DENOM);
        require(amount <= cap, "swap too large: exceeds maxSwapBps of pool");
    }

    function _checkBlockSpam(address user) internal {

        require(lastTradeBlock[user] != block.number, "one trade per block");
        lastTradeBlock[user] = block.number;
    }

    function _checkLiquidityShock(address token, uint256 currentPool) internal {
        uint256 hwm         = liquidityHighWaterMark[token];
        uint256 windowStart = liquidityWindowStart[token];

        // ── Bootstrap: first call for this token ─────────────────────────────
        if (hwm == 0) {
            liquidityHighWaterMark[token] = currentPool;
            liquidityWindowStart[token]   = block.timestamp;
            return;
        }

        bool windowExpired = block.timestamp >= windowStart + drainObservationWindow;

        // ── Window expiry: attempt to open a new observation window ──────────
        if (windowExpired) {
            if (hwm > 0) {
                // Recovery gate: pool must be within MAX_LIQUIDITY_DRAIN_BPS of
                // the previous HWM before the window resets.
                //
                // Example (MAX_LIQUIDITY_DRAIN_BPS = 1000 = 10%):
                //   HWM = 1_000_000, currentPool = 910_000
                //   recoveryBps = (910_000 * 10_000) / 1_000_000 = 9_100  ✓ (≥ 9_000)
                //   → window resets.
                //
                //   HWM = 1_000_000, currentPool = 850_000
                //   recoveryBps = 8_500  ✗ (< 9_000)
                //   → window EXTENDS: pool is still depressed; drain check runs below.
                uint256 recoveryBps = Math.mulDiv(currentPool, FEE_DENOM, hwm);
                uint256 recoveryThreshold = FEE_DENOM - MAX_LIQUIDITY_DRAIN_BPS;

                if (recoveryBps >= recoveryThreshold) {
                    // Pool has recovered: open a fresh window from current depth.
                    liquidityHighWaterMark[token] = currentPool;
                    liquidityWindowStart[token]   = block.timestamp;
                    return;
                }

                // Pool still depressed relative to previous HWM.
                // Extend the window — do NOT reset windowStart.
                // Fall through to the drain check below using the existing HWM.

            } else {
                // hwm was somehow zero despite the bootstrap guard — defensive reset.
                liquidityHighWaterMark[token] = currentPool;
                liquidityWindowStart[token]   = block.timestamp;
                return;
            }
        }

        // ── Within the window: raise HWM if pool has grown (LP deposit) ──────
        // This ensures the HWM always reflects the highest point in the window,
        // giving the most accurate baseline for drain measurement.
        if (currentPool > hwm) {
            liquidityHighWaterMark[token] = currentPool;
            // Pool grew → no drain to check. HWM updated; return early.
            return;
        }

        // ── Drain check: measure cumulative fall from window peak ─────────────
        // Because HWM only moves up, (hwm - currentPool) is the total volume
        // that has left the pool since the highest point in this window,
        // regardless of how many transactions caused it or how they were timed.
        uint256 drain    = hwm - currentPool;   // safe: currentPool <= hwm here
        uint256 drainBps = Math.mulDiv(drain, FEE_DENOM, hwm);

        if (drainBps > MAX_LIQUIDITY_DRAIN_BPS) {
            swapsPaused    = true;
            pauseTimestamp = block.timestamp;
            emit SwapsPaused(currentPool, drainBps);
        }
    }

    // -------------------------------------------------------
    // DIRECT SWAP
    // -------------------------------------------------------

    function swapNGNtoUSD(uint256 ngnAmount, uint256 minUSD)
        external onlyWhitelistedUser swapsNotPaused nonReentrant
    {
        _swapNGN(msg.sender, ngnAmount, minUSD, false);
    }

    function swapUSDtoNGN(uint256 usdAmount, uint256 minNGN)
        external onlyWhitelistedUser swapsNotPaused nonReentrant
    {
        _swapUSD(msg.sender, usdAmount, minNGN, false);
    }

    // -------------------------------------------------------
    // META SWAP (gasless relayer pattern)
    // -------------------------------------------------------

    function metaSwapNGNtoUSD(
        address signer,
        uint256 ngnAmount,
        uint256 minUSD,
        uint256 nonce,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    )
        external onlyWhitelistedUser swapsNotPaused nonReentrant
    {
        
         require(lpWhitelisted[signer], "signer not whitelisted");
        _verifyDeadline(deadline);
        _verifyNonce(signer, nonce);
        _verifySig(
            signer,
            keccak256(abi.encode(SWAP_NGN_TYPEHASH, signer, ngnAmount, minUSD, nonce, deadline)),
            v, r, s
        );
        nonces[signer]++;
        emit MetaTxExecuted(signer, msg.sender, SWAP_NGN_TYPEHASH, nonce);
        _swapNGN(signer, ngnAmount, minUSD, true);
    }

    function metaSwapUSDtoNGN(
        address signer,
        uint256 usdAmount,
        uint256 minNGN,
        uint256 nonce,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    )
        external onlyWhitelistedUser swapsNotPaused nonReentrant
    {
        require(lpWhitelisted[signer], "signer not whitelisted");
        _verifyDeadline(deadline);
        _verifyNonce(signer, nonce);
        _verifySig(
            signer,
            keccak256(abi.encode(SWAP_USD_TYPEHASH, signer, usdAmount, minNGN, nonce, deadline)),
            v, r, s
        );
        nonces[signer]++;
        emit MetaTxExecuted(signer, msg.sender, SWAP_USD_TYPEHASH, nonce);
        _swapUSD(signer, usdAmount, minNGN, true);
    }

    // -------------------------------------------------------
    // SWAP — INTERNAL
    // -------------------------------------------------------

    /// @dev NGN  →  USD
    ///      Trader sends cNGN, receives USD at sellRate.
    ///      Fee split: lpFee to vault (USD), platformFee to treasury.
    function _swapNGN(
        address user,
        uint256 ngnAmount,
        uint256 minUSD,
        bool    meta
    )
        internal priceNotStale
    {
        // --- MATH ---
        // FIX M-01: Math.mulDiv prevents intermediate overflow on large amounts
        // FIX C-01 (original): was using hardcoded 1e6; now uses USD_SCALE from token metadata
        _checkBlockSpam(user);
        require(poolDeposits[address(USD)] > 0 && poolDeposits[address(cNGN)] > 0, "pool empty");

        uint256 gross = Math.mulDiv(ngnAmount, USD_SCALE, buyRate);
        (uint256 fee, uint256 lpFee, uint256 platformFee) = _calcFee(gross);

        uint256 net = gross - fee;
       
        require(address(feeVault) != address(0));
        //require(msg.sender != address(feeVault), "vault reentry");
        require(net >= minUSD, "below min slippage");
        require(net >= MIN_TRADE_USD, "below min trade USD");
        require(net > 0,       "zero output");
       
        uint256 usdPool = poolDeposits[address(USD)];
        require(usdPool > minLiquidity[address(USD)], "USD pool too small");

        require(usdPool >= gross,  "insufficient USD pool");
        require(net <= Math.mulDiv(usdPool - fee, MAX_WITHDRAW_BPS, FEE_DENOM), "pool cap max swap reached");
        require(usdPool >= minLiquidity[address(USD)] + gross,"insufficient buffer");
        // --- EPOCH RATE LIMIT ---
        // FIX H-01: Per-user, per-epoch volume limiter prevents rapid draining
        //           across multiple blocks by a compromised whitelisted address.
        _checkSwapSize(gross, usdPool);
        _checkEpochLimit(user, gross, usdPool, true);
               

        // --- STATE UPDATE (before external calls — Checks-Effects-Interactions) ---
        poolDeposits[address(USD)]  -= gross;       // net + lpFee + platformFee
        poolDeposits[address(cNGN)] += ngnAmount;
        _checkLiquidityShock(address(USD), poolDeposits[address(USD)]);

        // All-time totals
        totalSwapVolumeNGN += ngnAmount;
        totalSwapCountNGN++;
        totalLpFeeUSD      += lpFee;
        totalPlatformFeeUSD += platformFee;

        // Daily bucket
        uint256 day = today();
        dailyStats[day].swapVolumeNGN  += ngnAmount;
        dailyStats[day].swapCountNGN   += 1;
        dailyStats[day].lpFeeUSD       += lpFee;
        dailyStats[day].platformFeeUSD += platformFee;

        // --- TRANSFERS ---
        cNGN.safeTransferFrom(user, address(this), ngnAmount);
         // Step B — register lpFee in vault accounting BEFORE transferring tokens.
        //  If depositFee reverts, the swap reverts here — tokens are
        //  not yet sent so nothing is orphaned.

        USD.safeTransfer(address(feeVault), lpFee);
        feeVault.depositFee(address(USD), lpFee);
        
        USD.safeTransfer(user, net);
        USD.safeTransfer(platformTreasury, platformFee);
        
        
        emit Swap(user, ngnAmount, net, lpFee, platformFee, true, meta);
    }

    /// @dev USD  →  NGN
    ///      Trader sends USD, receives cNGN at sellRate.
    ///      Fee split: lpFee to vault (cNGN), platformFee to treasury.
    function _swapUSD(
        address user,
        uint256 usdAmount,
        uint256 minNGN,
        bool    meta
    )
       internal priceNotStale
    {
        // --- MATH ---
        _checkBlockSpam(user);
        require(poolDeposits[address(USD)] > 0 && poolDeposits[address(cNGN)] > 0, "pool empty");
        uint256 gross = Math.mulDiv(usdAmount, sellRate, USD_SCALE);
        require(gross >= MIN_FEE, "fee too small");
        (uint256 fee, uint256 lpFee, uint256 platformFee) = _calcFee(gross);
        uint256 net = gross - fee;

        require(address(feeVault) != address(0)); //to double check fee vault is set before we allow any swaps that would require it, since fee transfer is after state update
        //require(msg.sender != address(feeVault), "vault reentry");
        require(net >= minNGN, "below min slippage");
        require(net >= MIN_TRADE_CNGN, "below min trade NGN");
        require(net > 0,  "zero output"); //to double check net is not zero after fee deduction, though min trade should catch this
        
        //require(poolDeposits[address(USD)] > 1, "USD pool empty");
        //require(poolDeposits[address(cNGN)] > 10, "NGN pool empty");
        
        // --- POOL CAP ---
        uint256 ngnPool = poolDeposits[address(cNGN)];
        require(ngnPool > minLiquidity[address(cNGN)], "NGN pool too small");
        require(ngnPool >= gross,  "insufficient NGN pool");
        require(net <= Math.mulDiv(ngnPool - fee, MAX_WITHDRAW_BPS, FEE_DENOM), "pool cap");
        require(ngnPool >= minLiquidity[address(cNGN)] + gross,"insufficient buffer");
    
        // --- EPOCH RATE LIMIT ---
        _checkSwapSize(gross, ngnPool);
        _checkEpochLimit(user, gross, ngnPool, false);
        
        // --- STATE UPDATE ---
        poolDeposits[address(cNGN)] -= gross;       // net + lpFee + platformFee
        poolDeposits[address(USD)]  += usdAmount;
        // detect abnormal liquidity drain
        _checkLiquidityShock(address(cNGN), poolDeposits[address(cNGN)]);

        // All-time totals
        totalSwapVolumeUSD  += usdAmount;
        totalSwapCountUSD++;
        totalLpFeeCNGN      += lpFee;
        totalPlatformFeeCNGN += platformFee;

        // Daily bucket
        uint256 day = today();
        dailyStats[day].swapVolumeUSD   += usdAmount;
        dailyStats[day].swapCountUSD    += 1;
        dailyStats[day].lpFeeCNGN       += lpFee;
        dailyStats[day].platformFeeCNGN += platformFee;

        // --- TRANSFERS ---
        USD.safeTransferFrom(user, address(this), usdAmount);

        cNGN.safeTransfer(address(feeVault), lpFee);
        feeVault.depositFee(address(cNGN), lpFee);
        
        cNGN.safeTransfer(user, net);
        cNGN.safeTransfer(platformTreasury, platformFee);
        
        emit Swap(user, usdAmount, net, lpFee, platformFee, false, meta);
    }

   

    // -------------------------------------------------------
    // DIRECT LP OPERATIONS
    // -------------------------------------------------------

    function addLiquidity(address token, uint256 amount)
        external onlyWhitelistedUser onlyValidToken(token) nonReentrant
    {
        _addLiquidity(msg.sender, token, amount, false);
    }

    function removeLiquidity(address token, uint256 shares)
        external onlyWhitelistedUser onlyValidToken(token) nonReentrant
    {
        _removeLiquidity(msg.sender, token, shares, false);
    }

    // -------------------------------------------------------
    // META LP OPERATIONS
    // -------------------------------------------------------

    function metaAddLiquidity(
        address signer,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    )
        external onlyValidToken(token) nonReentrant
    {
        // FIX H-03: validate the *signer* (fund source), not just the relayer
        require(lpWhitelisted[signer], "signer not whitelisted");

        _verifyDeadline(deadline);
        _verifyNonce(signer, nonce);
        _verifySig(
            signer,
            keccak256(abi.encode(ADD_LP_TYPEHASH, signer, token, amount, nonce, deadline)),
            v, r, s
        );
        nonces[signer]++;
        emit MetaTxExecuted(signer, msg.sender, ADD_LP_TYPEHASH, nonce);
        _addLiquidity(signer, token, amount, true);
    }

    function metaRemoveLiquidity(
        address signer,
        address token,
        uint256 shares,
        uint256 nonce,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    )
        external onlyValidToken(token) nonReentrant
    {
        require(lpWhitelisted[signer], "signer not whitelisted");

        _verifyDeadline(deadline);
        _verifyNonce(signer, nonce);
        _verifySig(
            signer,
            keccak256(abi.encode(REMOVE_LP_TYPEHASH, signer, token, shares, nonce, deadline)),
            v, r, s
        );
        nonces[signer]++;
        emit MetaTxExecuted(signer, msg.sender, REMOVE_LP_TYPEHASH, nonce);
        _removeLiquidity(signer, token, shares, true);
    }

    // -------------------------------------------------------
    // LP — INTERNAL
    // -------------------------------------------------------

    /// @dev FIX H-02: Share minting uses poolDeposits (internal accounting)
    ///      instead of balanceOf(this). A flash loan that artificially
    ///      inflates balanceOf cannot manipulate newShares because
    ///      poolDeposits is only updated by controlled functions.
    ///
    ///      FIX M-01: Math.mulDiv prevents overflow on large token amounts.
    function _addLiquidity(
        address lp,
        address token,
        uint256 amount,
        bool    meta
    )
        internal
    {
        _checkBlockSpam(lp);
        require(amount > 0, "zero amount");
        require(token == address(USD) || token == address(cNGN), "invalid token");

        uint256 pool          = poolDeposits[token];
        uint256 currentShares = feeVault.shares(token, lp);
        uint256 total         = feeVault.totalShares(token);

        uint256 newShares;
        if (total == 0 || pool == 0) {
            // First depositor: shares == amount (1:1 bootstrap)
            newShares = amount;
        } else {
            // FIX M-01: safe from overflow via mulDiv
            newShares = Math.mulDiv(amount, total, pool);
        }

        require(newShares > 0, "zero shares minted");

        // Update state BEFORE external calls
        poolDeposits[token] += amount;
        _checkLiquidityShock(token, poolDeposits[token]);

        // Daily liquidity tracking
        uint256 day = today();
        if (token == address(USD)) {
            dailyStats[day].liquidityAddedUSD  += amount;
        } else {
            dailyStats[day].liquidityAddedCNGN += amount;
        }

        // Settle fee entitlement BEFORE changing share balance (critical ordering)
        feeVault.updateShares(lp, token, currentShares + newShares);

        IERC20(token).safeTransferFrom(lp, address(this), amount);
        emit LiquidityAdded(lp, token, amount, newShares, meta);
    }

    function _removeLiquidity(
        address lp,
        address token,
        uint256 shares,
        bool    meta
    )
        internal
    {
        _checkBlockSpam(lp);
        require(shares > 0, "zero shares");
        require(token == address(USD) || token == address(cNGN), "invalid token");

        uint256 currentShares = feeVault.shares(token, lp);
        require(currentShares >= shares, "insufficient shares");

        uint256 pool   = poolDeposits[token];
        
        uint256 total  = feeVault.totalShares(token);
        require(total > 0, "zero share for token");

        // FIX M-01: safe from overflow
        uint256 amount = Math.mulDiv(shares, pool, total);

        require(amount > 0, "zero withdrawal");
        require(pool - amount >= minLiquidity[token], "pool too small");

        // Update state BEFORE external calls
        poolDeposits[token] -= amount;
        _checkLiquidityShock(token, poolDeposits[token]);

        // Daily liquidity tracking
        uint256 day = today();
        if (token == address(USD)) {
            dailyStats[day].liquidityRemovedUSD  += amount;
        } else {
            dailyStats[day].liquidityRemovedCNGN += amount;
        }

        // Settle fee entitlement BEFORE changing share balance (critical ordering)
        feeVault.updateShares(lp, token, currentShares - shares);

        IERC20(token).safeTransfer(lp, amount);
        emit LiquidityRemoved(lp, token, amount, shares, meta);
    }

    // -------------------------------------------------------
    // CLAIM LP FEE
    // -------------------------------------------------------

    function claimLPFee(address token)
        external onlyWhitelistedUser onlyValidToken(token) nonReentrant
    {
        _claimLP(msg.sender, token);
    }

    function metaClaimLPFee(
        address signer,
        address token,
        uint256 nonce,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    )
        external onlyWhitelistedUser onlyValidToken(token) nonReentrant
    {
        _verifyDeadline(deadline);
        _verifyNonce(signer, nonce);
        _verifySig(
            signer,
            keccak256(abi.encode(CLAIM_LP_TYPEHASH, signer, token, nonce, deadline)),
            v, r, s
        );
        nonces[signer]++;
        emit MetaTxExecuted(signer, msg.sender, CLAIM_LP_TYPEHASH, nonce);
        _claimLP(signer, token);
    }

    /// @dev FIX C-02: Fully delegates to feeVault. The previous version read
    ///      from lpFeePool/lpShares/totalLPShares which were never populated
    ///      once the vault pattern was adopted — causing silent no-ops.
    function _claimLP(address lp, address token) internal {

        require(address(feeVault).code.length > 0, "vault not contract");
        feeVault.claimFor(lp, token);
        emit LPFeeClaimed(lp, token);
    }

    // -------------------------------------------------------
    // FEES — INTERNAL
    // -------------------------------------------------------

    /// @dev FIX M-01: All multiplications use Math.mulDiv to prevent
    ///      overflow on large amounts.
   function _calcFee(uint256 amount) internal view
        returns (uint256 total, uint256 lpFee, uint256 platformFee)
    {
        total = Math.mulDiv(amount, swapFeeBps, FEE_DENOM);

        require(total > 0, "fee rounds to zero: trade size too small");

        // lpFee rounded DOWN — any dust (≤1 wei) flows to platformFee, never to LPs.
        lpFee       = Math.mulDiv(total, lpShareBps, FEE_DENOM);

        // Exact subtraction guarantees lpFee + platformFee == total with no rounding gap.
        platformFee = total - lpFee;
    }

    // -------------------------------------------------------
    // EIP-712 HELPERS
    // -------------------------------------------------------

    function _verifyDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "tx expired");
    }

    function _verifyNonce(address signer, uint256 nonce) internal view {
        require(nonces[signer] == nonce, "bad nonce");
    }

    function _verifySig(
        address signer,
        bytes32 structHash,
        uint8   v,
        bytes32 r,
        bytes32 s
    )
        internal view
    {
        bytes32 digest    = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, v, r, s);
        require(recovered == signer, "bad signature");
    }

    function emergencyPause() external onlyOwner {
        swapsPaused = true;
        emit EmergencyPause(msg.sender);
    }

    // -------------------------------------------------------
    // VIEW HELPERS — POOL STATE
    // -------------------------------------------------------

    function getPoolDepth()
        external view
        returns (uint256 usdDepth, uint256 ngnDepth)
    {
        return (
            poolDeposits[address(USD)],
            poolDeposits[address(cNGN)]
        );
    }

    function pendingLPClaim(address lp, address token)
        external view
        returns (uint256)
    {
        require(address(feeVault).code.length > 0, "vault not contract");
        return feeVault.pendingClaim(lp, token);
    }

    function currentRates()
        external view
        returns (uint256 buy, uint256 sell, uint256 mid, bool stale)
    {
        return (
            buyRate,
            sellRate,
            midPrice,
            lastPriceUpdate == 0 || block.timestamp > lastPriceUpdate + maxPriceAge
        );
    }

    function fetchLPPositionStats(address lp)
        external view
        returns (uint256 shareNGN, uint256 shareUSD, uint256 totalShareNGN, 
        uint256 totalShareUSD, uint256 poolDepositNGN, uint256 poolDepositUSD )
    {
        require(address(feeVault).code.length > 0, "vault not contract");
        shareNGN = feeVault.shares(address(cNGN), lp);
        shareUSD = feeVault.shares(address(USD), lp);
        totalShareNGN = feeVault.totalShares(address(cNGN));
        totalShareUSD = feeVault.totalShares(address(USD));
        poolDepositNGN = poolDeposits[address(cNGN)];
        poolDepositUSD = poolDeposits[address(USD)];
    }


    function quoteSwapNGN(uint256 ngnAmount, uint256 minUSD)
        external view
        returns (
            uint256 net,
            uint256 fee,
            uint256 rate
        )
    {
       
        require(poolDeposits[address(USD)] > 0 && poolDeposits[address(cNGN)] > 0, "pool empty");

        uint256 gross = Math.mulDiv(ngnAmount, USD_SCALE, buyRate);
        (uint256 fee, uint256 lpFee, uint256 platformFee) = _calcFee(gross);

        uint256 net = gross - fee;
       
        require(address(feeVault) != address(0));
        //require(msg.sender != address(feeVault), "vault reentry");
        require(net >= minUSD, "below min slippage");
        require(net >= MIN_TRADE_USD, "below min trade USD");
        require(net > 0,       "zero output");
       
        uint256 usdPool = poolDeposits[address(USD)];
        require(usdPool > minLiquidity[address(USD)], "USD pool too small");

        require(usdPool >= gross,  "insufficient USD pool");
        require(net <= Math.mulDiv(usdPool - fee, MAX_WITHDRAW_BPS, FEE_DENOM), "pool cap max swap reached");
        require(usdPool >= minLiquidity[address(USD)] + gross,"insufficient buffer");
        
        //_checkSwapSize(gross, usdPool);
     
       
        return (net, fee, buyRate);
    }

    function quoteSwapUSD(uint256 usdAmount, uint256 minNGN)
        external view
        returns (
            uint256 net,
            uint256 fee,
            uint256 rate
        )
    {
       
        require(poolDeposits[address(USD)] > 0 && poolDeposits[address(cNGN)] > 0, "pool empty");
        uint256 gross = Math.mulDiv(usdAmount, sellRate, USD_SCALE);
        require(gross >= MIN_FEE, "fee too small");
        (uint256 fee, uint256 lpFee, uint256 platformFee) = _calcFee(gross);
        uint256 net = gross - fee;

        require(address(feeVault) != address(0)); //to double check fee vault is set before we allow any swaps that would require it, since fee transfer is after state update
        //require(msg.sender != address(feeVault), "vault reentry");
        require(net >= minNGN, "below min slippage");
        require(net >= MIN_TRADE_CNGN, "below min trade NGN");
        require(net > 0,  "zero output"); //to double check net is not zero after fee deduction, though min trade should catch this
        
        //require(poolDeposits[address(USD)] > 1, "USD pool empty");
        //require(poolDeposits[address(cNGN)] > 10, "NGN pool empty");
        
        // --- POOL CAP ---
        uint256 ngnPool = poolDeposits[address(cNGN)];
        require(ngnPool > minLiquidity[address(cNGN)], "NGN pool too small");
        require(ngnPool >= gross,  "insufficient NGN pool");
        require(net <= Math.mulDiv(ngnPool - fee, MAX_WITHDRAW_BPS, FEE_DENOM), "pool cap");
        require(ngnPool >= minLiquidity[address(cNGN)] + gross,"insufficient buffer");
    
        // --- EPOCH RATE LIMIT ---
        //_checkSwapSize(gross, ngnPool);
      

        return (net, fee, sellRate);
    }

    function isPauseSwap() external view returns(bool)  {
       return swapsPaused;
    }
   
    // -------------------------------------------------------
    // VIEW HELPERS — STATISTICS
    // -------------------------------------------------------

    /*
    /// @notice Returns the full DailyStats struct for a given UTC day number.
    ///         Pass today() for the current day.
    ///         Pass today()-1 for yesterday, etc.
    function getDay(uint256 dayId)
        external view
        returns (DailyStats memory)
    {
        return dailyStats[dayId];
    }

    

    /// @notice Convenience: returns today's stats in one call.
    function getTodayStats()
        external view
        returns (DailyStats memory)
    {
        return dailyStats[today()];
    }

    /// @notice Aggregates stats across a range of days [fromDay, toDay] inclusive.
    ///         Safe to call for any range; missing days return zero values.
    ///         Gas: O(n) where n = toDay - fromDay + 1.
    ///         Keep ranges to ≤ 90 days for view calls; use events for wider history.
    function getRangeStats(uint256 fromDay, uint256 toDay)
        external view
        returns (DailyStats memory agg)
    {
        require(toDay >= fromDay,     "bad range");
        require(toDay - fromDay < 366, "range too wide"); // guard gas
        for (uint256 d = fromDay; d <= toDay; d++) {
            DailyStats storage s = dailyStats[d];
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

    /// @notice Returns all-time protocol totals in one call.
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
            totalSwapVolumeNGN,
            totalSwapVolumeUSD,
            totalSwapCountNGN,
            totalSwapCountUSD,
            totalLpFeeUSD,
            totalLpFeeCNGN,
            totalPlatformFeeUSD,
            totalPlatformFeeCNGN
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
            MIN_TRADE_CNGN
        );
    }*/

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getEIP712Domain()
        external view
        returns (
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract
        )
    {
        return ("FiatStablecoinAMMV2", "1", block.chainid, address(this));
    }
}  