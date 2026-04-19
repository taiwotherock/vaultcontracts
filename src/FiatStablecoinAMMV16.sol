// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================
// FiatStablecoinAMMV16 — cLCY / USD Corridor
// Split: risk guards → AMMRiskBase, errors → AMMErrorsLib,
//        quotes → AMMQuoter (standalone read-only contract)
// =============================================================

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./FiatStablecoinAMMFeeV5.sol";
import "./FiatAMMErrorsLib.sol";
import "./FiatAMMStorage.sol";
import "./FiatAMMRiskBase3.sol";

contract FiatStablecoinAMMV16 is Ownable, ReentrancyGuard, EIP712, FiatAMMRiskBase3 {

    using SafeERC20 for IERC20;
    using ECDSA     for bytes32;

    // -------------------------------------------------------
    // FEE VAULT
    // -------------------------------------------------------

    FiatStablecoinAMMFeeV5 public feeVault;
    mapping(uint256 => FiatAMMStorage.DailyStats) public dailyStats;

    // -------------------------------------------------------
    // TOKENS
    // -------------------------------------------------------

    IERC20  public immutable cLCY;
    IERC20  public immutable USD;

    /// @dev Read from token metadata at deploy time — avoids hardcoded DECIMALS.
    ///      USDC/USDT = 1e6; DAI = 1e18.
    uint256 public immutable USD_SCALE;

    // -------------------------------------------------------
    // ACCESS CONTROL — 2-STEP TRANSFER PATTERN
    // -------------------------------------------------------

    address public platformTreasury;
    address public pendingTreasury;
    //address public fiatRampAddress;

    address public oracleManager;
    address public pendingOracleManager;

    mapping(address => bool) public lpWhitelisted;
    mapping(address => bool) public relayer;

    // -------------------------------------------------------
    // PRICE — COMMIT-REVEAL (MEV / Oracle Sandwich Mitigation)
    // -------------------------------------------------------

    uint256 public midPrice;
    uint256 public halfSpread;
    uint256 public buyRate;
    uint256 public sellRate;
   
    mapping(address => uint256) public poolDeposits;
    mapping(address => uint256) public minLiquidity;

    uint256 public constant MIN_FEE         = 1e3;
    //uint256 public MIN_TRADE_USD            = 70_000;        // $0.07
    //uint256 public MIN_TRADE_LCY            = 100_000_000;   // 100 LCY
    // -------------------------------------------------------
    // EIP-712 TYPE HASHES
    // -------------------------------------------------------

    bytes32 public constant SWAP_TYPEHASH =
        keccak256("metaSwap(address wallet,uint256 amount,uint256 minAmt,bool swapUSD,uint256 nonce,uint256 deadline,string paymentId)");
    
    // -------------------------------------------------------
    // FEES
    // -------------------------------------------------------

    uint256 public constant FEE_DENOM        = 10_000;
    uint256 public constant MAX_WITHDRAW_BPS = 5_000; // 50% per tx
    uint256 public constant MAX_SWAP_FEE_BPS =   200; // hard cap 2%

    uint256 public swapFeeBps      = 10;    // 0.10%
    uint256 public lpShareBps      = 7_000; // 70% of fee to LPs
    uint256 public platformShareBps = 40_000; // 30% of fee to treasury
    mapping(address => mapping(uint256 => uint256)) public dailySwapLimitUsd; 
    uint256 public dailySwapLimitUsdMax = 1_000 * 1e6; // $1k daily swap limit in USD

    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool)    public paymentIdUsed;

    // -------------------------------------------------------
    // ANALYTICS — DAILY BUCKETS
    // -------------------------------------------------------

    uint256 public totalSwapVolumeLCY;
    uint256 public totalSwapCountLCY;
    uint256 public totalSwapVolumeUSD;
    uint256 public totalSwapCountUSD;
    uint256 public totalLpFeeUSD;
    uint256 public totalLpFeeLCY;
    uint256 public totalPlatformFeeUSD;
    uint256 public totalPlatformFeeLCY;
    

    // -------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------

    event Swap(
        address indexed user,
        uint256 inAmount,
        uint256 outAmount,
        uint256 lpFee,
        uint256 platformFee,
        bool    lcyToUsd,   // true = LCY→USD, false = USD→LCY
        bool    meta,
        address receiverAddress
    );
    event LiquidityAdded(address indexed lp, address indexed token, uint256 amount, uint256 shares, bool meta);
    event LiquidityRemoved(address indexed lp, address indexed token, uint256 amount, uint256 shares, bool meta);
    event LPFeeClaimed(address indexed lp, address indexed token);
    event MetaTxExecuted(address indexed signer, address indexed relayer, bytes32 typehash, uint256 nonce);
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
    event EmergencyPause(address triggeredBy);
    event MaxPriceAgeUpdated(uint256 oldAge, uint256 newAge);
    event PriceUpdateDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event PriceExpired(uint256 price);
    event MinTradeUSDUpdated(uint256 oldMin, uint256 newMin);
    event MinTradeLCYUpdated(uint256 oldMin, uint256 newMin);
    event DailySwapLimitUpdated(uint256 newLimit);
    event RelayerWhitelisted(address indexed lp,bool allowed);

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    constructor(
        address _cLCY,
        address _USD,
        address _treasury,
        address _oracleManager,
        uint256 _halfSpread,
        uint256 _price
    )
        Ownable(msg.sender)
        EIP712("FiatStablecoinAMMV16", "1")
    {
        if (_cLCY == address(0) || _USD == address(0) || _treasury == address(0)) revert ZeroAddress();
        if (IERC20Metadata(_USD).decimals()  != 6) revert USDMustBe6Decimals();
        if (IERC20Metadata(_cLCY).decimals() != 6) revert LCYMusBe6Decimals();
        if (_oracleManager == address(0))           revert ZeroAddress();
        if (_price == 0)                            revert ZeroAmount();

        cLCY             = IERC20(_cLCY);
        USD              = IERC20(_USD);
        USD_SCALE        = 10 ** IERC20Metadata(_USD).decimals();

        platformTreasury = _treasury;
        oracleManager    = _oracleManager;
        halfSpread       = _halfSpread;

        midPrice         = _price;
        buyRate          = midPrice + halfSpread;
        sellRate         = midPrice - halfSpread;
        lastPriceUpdate  = block.timestamp;
        pendingPrice     = 0;

        minLiquidity[_USD]  = 1  * 10 ** IERC20Metadata(_USD).decimals();
        minLiquidity[_cLCY] = 1 * 10 ** IERC20Metadata(_cLCY).decimals();

        maxSwapBps       = 1000;
        swapCheckEnabled = true;
    }

    // -------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------

    modifier onlyOracleManager() {
        if (msg.sender != oracleManager) revert NotWhitelisted();
        _;
    }

    modifier onlyWhitelistedUser() {
        if (!lpWhitelisted[msg.sender]) revert NotWhitelisted();
        _;
    }

    modifier onlyRelayer() {
       require(relayer[msg.sender], "not relayer");
        _;
    }

    modifier onlyValidToken(address token) {
        if (token != address(cLCY) && token != address(USD)) revert InvalidToken();
        _;
    }

    modifier swapsNotPaused() {
        if (swapsPaused) revert SwapsPausedError();
        _;
    }

    modifier priceNotStale() {
        require( !(lastPriceUpdate == 0 || block.timestamp > lastPriceUpdate + maxPriceAge),"PRICE_STALE");
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

    function whitelistRelayer(address lp, bool allowed) external onlyOwner {
        relayer[lp] = allowed;
        emit RelayerWhitelisted(lp, allowed);
    }

    function isRelayerWhitelisted(address lp) external view returns (bool) {
        return relayer[lp];
    }

    // -------------------------------------------------------
    // ADMIN — 2-STEP TREASURY TRANSFER
    // -------------------------------------------------------

    function today() public view returns (uint256) {
            return block.timestamp / 86400;
    }
    function proposeTreasury(address _new) external onlyOwner {
        if (_new == address(0)) revert ZeroAddress();
        pendingTreasury = _new;
        emit TreasuryProposed(_new);
    }

    function acceptTreasury() external {
        if (msg.sender != pendingTreasury) revert NotPendingTreasury();
        platformTreasury = pendingTreasury;
        pendingTreasury  = address(0);
        emit TreasuryAccepted(platformTreasury);
    }

    // -------------------------------------------------------
    // ADMIN — 2-STEP ORACLE MANAGER TRANSFER
    // -------------------------------------------------------

    function proposeOracle(address _new) external onlyOwner {
        if (_new == address(0)) revert ZeroAddress();
        pendingOracleManager = _new;
        emit OracleProposed(_new);
    }

    function acceptOracle() external {
        if (msg.sender != pendingOracleManager) revert NotPendingOracle();
        oracleManager        = pendingOracleManager;
        pendingOracleManager = address(0);
        emit OracleAccepted(oracleManager);
    }

    // -------------------------------------------------------
    // ADMIN — FEE VAULT
    // -------------------------------------------------------

    function setFeeVault(address _vault) external onlyOwner {
        if (_vault == address(0))  revert ZeroAddress();
        if (_vault.code.length == 0) revert FeeVaultNotContract();
        feeVault = FiatStablecoinAMMFeeV5(_vault);
        emit FeeVaultUpdated(_vault);
    }

    function setMinLiquidityToken(address token, uint256 amount1, address token2, uint256 amount2) external onlyOwner {
        if (token != address(cLCY) && token != address(USD)) revert InvalidToken();
        minLiquidity[token] = amount1;
        minLiquidity[token2] = amount2;
    }

    // -------------------------------------------------------
    // ADMIN — TUNABLE PARAMS
    // -------------------------------------------------------

    function setHalfSpread(uint256 _spread) external onlyOwner {
        //require(percentDiff(halfSpread, _spread) < 10, "Spread change too large"); // 100% difference allowed
        halfSpread = _spread;
        emit SpreadUpdated(_spread);
    }

    function setMaxDailySwapLimit(uint256 _limit) external onlyOwner {
        dailySwapLimitUsdMax = _limit;
        emit DailySwapLimitUpdated(_limit);
    }

    function setSwapFeeBps(uint256 _bps) external onlyOwner {
        if (_bps > MAX_SWAP_FEE_BPS)   revert FeeTooHigh();
        if (_bps == 0)  revert ZeroFeeRate();
        if (Math.mulDiv(MIN_TRADE_USD, _bps, FEE_DENOM) == 0)  revert MinTradeTooSmall();
        if (Math.mulDiv(MIN_TRADE_LCY, _bps, FEE_DENOM) == 0)  revert MinTradeTooSmall();
        swapFeeBps = _bps;
        emit SwapFeeUpdated(_bps);
    }

    function setLpShareBps(uint256 _bps) external onlyOwner {
        if (_bps > FEE_DENOM) revert ExceedsDenom();
        lpShareBps       = _bps;
        platformShareBps = FEE_DENOM - _bps;
        emit LpShareUpdated(_bps, platformShareBps);
    }

    function setEpochParams(uint256 _duration, uint256 _maxBps) external onlyOwner {
        _setEpochParams(_duration, _maxBps);
    }

    function setMaxPriceAge(uint256 _age) external onlyOwner {
        if (_age < 1 minutes || _age > 24 hours) revert InvalidAge();
        if (priceUpdateDelay >= _age)            revert InvalidDelay();
        uint256 old = maxPriceAge;
        maxPriceAge = _age;
        emit MaxPriceAgeUpdated(old, _age);
    }

    function setPriceUpdateDelay(uint256 _delay) external onlyOwner {
        if (_delay < 10 seconds || _delay > 10 minutes) revert InvalidDelay();
        if (_delay >= maxPriceAge)                      revert InvalidDelay();
        uint256 old      = priceUpdateDelay;
        priceUpdateDelay = _delay;
        emit PriceUpdateDelayUpdated(old, _delay);
    }

    function setMinTradeUSD(uint256 _minUSD) external onlyOwner {
        if (_minUSD == 0)                                          revert ZeroAmount();
        if (Math.mulDiv(_minUSD, swapFeeBps, FEE_DENOM) == 0)     revert MinTradeTooSmall();
        uint256 old   = MIN_TRADE_USD;
        MIN_TRADE_USD = _minUSD;
        emit MinTradeUSDUpdated(old, _minUSD);
    }

    function setMinTradeLCY(uint256 _minLCY) external onlyOwner {
        if (_minLCY == 0)                                          revert ZeroAmount();
        if (Math.mulDiv(_minLCY, swapFeeBps, FEE_DENOM) == 0)     revert MinTradeTooSmall();
        uint256 old   = MIN_TRADE_LCY;
        MIN_TRADE_LCY = _minLCY;
        emit MinTradeLCYUpdated(old, _minLCY);
    }

    function setDrainWindow(uint256 _window) external onlyOwner {
        _setDrainWindow(_window);
    }

    function setMaxSwapBps(uint256 _bps) external onlyOwner {
        _setMaxSwapBps(_bps);
    }

    function disableSwapCheck(uint256 duration) external onlyOwner {
        _disableSwapCheck(duration);
    }

    function enableSwapCheck() external onlyOwner {
        _enableSwapCheck();
    }

    // -------------------------------------------------------
    // PRICE MANAGEMENT — COMMIT-REVEAL
    // -------------------------------------------------------

    function commitPrice(uint256 price) external onlyOracleManager {
        
        require(price != 0, "Price cannot be zero");
        require(price >= halfSpread, "Price must exceed spread");
        if(pendingPrice != 0 )
            require(percentDiff(price, pendingPrice) < 10, "Price change too large than 10%"); 
            
        (uint256 minPrice, uint256 maxPrice) = _getPriceBounds();
        if (price >= maxPrice || price <= minPrice) revert PriceOutOfBounds();
        pendingPrice  = price;
        priceActiveAt = block.timestamp + priceUpdateDelay;
        emit PriceCommitted(price, priceActiveAt);
    }

    function _getPriceBounds() internal view returns (uint256 minPrice, uint256 maxPrice) {
        if (lastSafePrice == 0) return (0, type(uint256).max);
        uint256 range = Math.mulDiv(lastSafePrice, MAX_PRICE_DEVIATION_BPS, FEE_DENOM);
        minPrice = lastSafePrice - range;
        maxPrice = lastSafePrice + range;
    }

    function applyPrice() external {
        if (pendingPrice == 0) revert NoPendingPrice();
        if (block.timestamp < priceActiveAt)  revert DelayNotElapsed();

        if (block.timestamp > priceActiveAt + 5 minutes) {
            emit PriceExpired(pendingPrice);
            pendingPrice = 0;
            return;
        }

        uint256 newPrice = pendingPrice;
        pendingPrice     = 0;

        _checkPriceDeviation(newPrice);

        midPrice        = newPrice;
        buyRate         = midPrice + halfSpread;
        sellRate        = midPrice - halfSpread;
        lastPriceUpdate = block.timestamp;

        emit PriceApplied(midPrice, buyRate, sellRate);
    }

    function _checkPriceDeviation(uint256 newPrice) internal {
        if (lastSafePrice == 0) {
            lastSafePrice = newPrice;
            return;
        }

        uint256 diff = newPrice > lastSafePrice
            ? newPrice - lastSafePrice
            : lastSafePrice - newPrice;

        uint256 deviationBps = Math.mulDiv(diff, FEE_DENOM, lastSafePrice);

        if (deviationBps > MAX_PRICE_DEVIATION_BPS) {
            swapsPaused    = true;
            pauseTimestamp = block.timestamp;
            lastSafePrice  = newPrice;
            emit SwapsPaused(newPrice, deviationBps);
        } else {
            lastSafePrice  = newPrice;
        }
    }

    function unpauseSwaps() external onlyOwner {
        if (!swapsPaused) revert NotPaused();
        if (block.timestamp > lastPriceUpdate + maxPriceAge) revert PriceStale();
        swapsPaused = false;
        emit SwapsResumed(msg.sender);
    }

    function autoUnpause() external onlyOwner {
        if (!swapsPaused) revert NotPaused();
        if (block.timestamp < pauseTimestamp + PAUSE_COOLDOWN) revert CooldownActive();
        if (block.timestamp > lastPriceUpdate + maxPriceAge)   revert PriceStale();

        /*if (!_checkLiquidityRecovered(
            poolDeposits[address(USD)],
            poolDeposits[address(cLCY)],
            minLiquidity[address(USD)],
            minLiquidity[address(cLCY)],
            address(USD),
            address(cLCY)
        )) revert LiquidityNotRecovered();*/

        swapsPaused = false;
        emit SwapsResumed(msg.sender);
    }

    function emergencyPause() external onlyOwner {
        swapsPaused = true;
        emit EmergencyPause(msg.sender);
    }

    // -------------------------------------------------------
    // DIRECT SWAP
    // -------------------------------------------------------

    function swapLCYtoUSD(uint256 lcyAmount, uint256 minUSD)
        external onlyWhitelistedUser swapsNotPaused nonReentrant
    {
        //_swapLCY(msg.sender, lcyAmount, minUSD, false);
        _swap(msg.sender, lcyAmount, minUSD, true, false,msg.sender);
    }

    function swapUSDtoLCY(uint256 usdAmount, uint256 minLCY)
        external onlyWhitelistedUser swapsNotPaused nonReentrant
    {
        //_swapUSD(msg.sender, usdAmount, minLCY, false);
        _swap(msg.sender, usdAmount, minLCY, false, false,msg.sender);
    }

    /*function offRampToBank(uint256 amount, uint256 minAmt, bool swapUSD, address receiver)
        external onlyWhitelistedUser swapsNotPaused nonReentrant
    {
       
        _swap(msg.sender, amount, minAmt, !swapUSD, false,receiver);
    }*/

    // -------------------------------------------------------
    // META SWAP (gasless relayer pattern)
    // -------------------------------------------------------

     // ─── Signature Validation ─────────────────────────────────────────────────
    function _validateSignature(
        address wallet,
        uint256 amount,
        uint256 minAmt,
        bool swapUSD,
        uint256 nonce,
        uint256 deadline,
        string memory paymentId,
        bytes memory signature
    ) internal view returns (address signer) {

        // bytes32 public constant SWAP_LCY_TYPEHASH =
        //keccak256("SwapLCY(address signer,uint256 lcyAmount,uint256 minUSD,uint256 nonce,uint256 deadline)");

        // Time
        require(block.timestamp <= deadline, "EXPIRED");

        // nonce
        require(nonce >= 0,"INVALID_ZERO_NONCE");
        require(nonce == nonces[signer], "INVALID_NONCE");
        bytes32 paymentIdHash = keccak256(bytes(paymentId));
               
        require(paymentIdUsed[paymentIdHash] == false, "PAYMENT_ID_USED");
        require(amount > 0, "ZERO_AMOUNT");
       
        // EIP-712
        bytes32 structHash = keccak256(abi.encode(
            SWAP_TYPEHASH,
            wallet,
            amount,
            minAmt,
            swapUSD,
            nonce,
            deadline,
            paymentIdHash
        ));
        
        bytes32 digest = _hashTypedDataV4(structHash);
        signer = ECDSA.recover(digest, signature);
        require(signer != address(0),    "ZERO_SIGNER");
        require(signer == wallet, "INVALID_SIGNER");
       
    }

    function metaSwap(
        address wallet, uint256 amount, uint256 minAmt,bool swapUSD,
        uint256 nonce, uint256 deadline, 
        string memory paymentId,
        bytes memory signature
    )
        external onlyRelayer swapsNotPaused nonReentrant
    {
        address signer = _validateSignature(wallet,amount,minAmt,swapUSD, nonce,deadline,paymentId,signature);
        
        if (!lpWhitelisted[signer]) revert SignerNotWhitelisted();
        require(relayer[msg.sender],"Not relayer");
        nonces[signer]++;
        emit MetaTxExecuted(signer, msg.sender, SWAP_TYPEHASH, nonce);
        _swap(signer, amount, minAmt, !swapUSD, true,signer);
    }

    function _swap(
        address user,
        uint256 amount,
        uint256 minOut,
        bool isLCYtoUSD,
        bool meta,
        address receiverAddress
    )
        internal
    {
        require(lastTradeBlock[user] != block.number, "OneTradePerBlock");
        lastTradeBlock[user] = block.number;

        uint256 usdPool = poolDeposits[address(USD)];
        uint256 lcyPool = poolDeposits[address(cLCY)];

        require(!(usdPool == 0 || lcyPool == 0), "ZERO_AMOUNT");
        if(user != receiverAddress)
            require(lpWhitelisted[receiverAddress], "receiver address not whitelisted" );

        uint256 gross;
        uint256 fee;
        uint256 lpFee;
        uint256 platformFee;
        uint256 net;
        uint256 cap;
        uint256 minLiq;

        uint256 day = today();
        uint256 used = dailySwapLimitUsd[user][day];

        // =========================
        // LCY → USD
        // =========================
        if (isLCYtoUSD) {
            gross = Math.mulDiv(amount, USD_SCALE, buyRate);

            (fee, lpFee, platformFee) = _calcFee(gross);
            net = gross - fee;

            require(address(feeVault) != address(0), "VAULT_NOT_SET");
            require(net >= minOut, "BELOW_MIN_SLIPPAGE");
            require(net >= MIN_TRADE_USD, "BELOW_MIN_TRADE_USD");
            require(net != 0, "ZERO_OUTPUT");

            minLiq = minLiquidity[address(USD)];
            cap = Math.mulDiv(usdPool - fee, MAX_WITHDRAW_BPS, FEE_DENOM);

            require(usdPool > minLiq, "INSUFFICIENT_USD_POOL");
            require(usdPool >= gross, "INSUFFICIENT_USD_POOL");
            require(net <= cap, "POOL_CAP_EXCEEDED");
            require(usdPool >= minLiq + gross, "INSUFFICIENT_BUFFER");

            used += gross;
            dailySwapLimitUsd[user][day] = used;
            require(used <= dailySwapLimitUsdMax, "DAILY_SWAP_LIMIT_EXCEEDED");

            //_checkSwapSize(gross, usdPool);
            //_checkEpochLimit(user, gross, usdPool, true);

            poolDeposits[address(USD)]  -= gross;
            poolDeposits[address(cLCY)] += amount;

            //_checkLiquidityShock(address(USD), poolDeposits[address(USD)]);

            totalSwapVolumeLCY  += amount;
            totalSwapCountLCY++;
            totalLpFeeUSD       += lpFee;
            totalPlatformFeeUSD += platformFee;

            //uint256 day = today();
            dailyStats[day].swapVolumeLCY  += amount;
            dailyStats[day].swapCountLCY   += 1;
            dailyStats[day].lpFeeUSD       += lpFee;
            dailyStats[day].platformFeeUSD += platformFee;

            cLCY.safeTransferFrom(user, address(this), amount);
            USD.safeTransfer(address(feeVault), lpFee);
            feeVault.depositFee(address(USD), lpFee);
            USD.safeTransfer(receiverAddress, net);
            USD.safeTransfer(platformTreasury, platformFee);
        }

        // =========================
        // USD → LCY
        // =========================
        else {
            gross = Math.mulDiv(amount, sellRate, USD_SCALE);

            require(gross >= MIN_FEE, "FEE_ROUNDS_TO_ZERO");

            (fee, lpFee, platformFee) = _calcFee(gross);
            net = gross - fee;

            require(address(feeVault) != address(0), "VAULT_NOT_SET");
            require(net >= minOut, "BELOW_MIN_SLIPPAGE");
            require(net >= MIN_TRADE_LCY, "BELOW_MIN_TRADE_LCY");
            require(net != 0, "ZERO_OUTPUT");

            minLiq = minLiquidity[address(cLCY)];
            cap = Math.mulDiv(lcyPool - fee, MAX_WITHDRAW_BPS, FEE_DENOM);

            require(lcyPool > minLiq, "INSUFFICIENT_LCY_POOL");
            require(lcyPool >= gross, "INSUFFICIENT_LCY_POOL");
            require(net <= cap, "POOL_CAP_EXCEEDED");
            require(lcyPool >= minLiq + gross, "INSUFFICIENT_BUFFER");

            used += gross;
            dailySwapLimitUsd[user][day] = used;
            require(used <= dailySwapLimitUsdMax, "DAILY_SWAP_LIMIT_EXCEEDED");

            //_checkSwapSize(gross, lcyPool);
            //_checkEpochLimit(user, gross, lcyPool, false);

            poolDeposits[address(cLCY)] -= gross;
            poolDeposits[address(USD)]  += amount;

            //_checkLiquidityShock(address(cLCY), poolDeposits[address(cLCY)]);

            totalSwapVolumeUSD  += amount;
            totalSwapCountUSD++;
            totalLpFeeLCY       += lpFee;
            totalPlatformFeeLCY += platformFee;

            //uint256 day = today();
            dailyStats[day].swapVolumeUSD   += amount;
            dailyStats[day].swapCountUSD    += 1;
            dailyStats[day].lpFeeLCY        += lpFee;
            dailyStats[day].platformFeeLCY  += platformFee;

            USD.safeTransferFrom(user, address(this), amount);
            cLCY.safeTransfer(address(feeVault), lpFee);
            feeVault.depositFee(address(cLCY), lpFee);
            cLCY.safeTransfer(receiverAddress, net);
            cLCY.safeTransfer(platformTreasury, platformFee);
        }

        emit Swap(user, amount, net, lpFee, platformFee, !isLCYtoUSD, meta,receiverAddress);
    }


    function quoteSwap(
        uint256 amount,
        uint256 minOut,
        bool isLCYtoUSD
    )
        external
        view
        returns (
            uint256 net,
            uint256 fee,
            uint256 rate,
            bool    feasible,
            string  memory reason
        )
    {
        uint256 usdPool = poolDeposits[address(USD)];
        uint256 lcyPool = poolDeposits[address(cLCY)];

        if (usdPool == 0 || lcyPool == 0) {
            return (0, 0, 0, false, "pool empty");
        }

        uint256 gross;
        uint256 lpFee;
        uint256 platformFee;

        if (isLCYtoUSD) {
            rate  = buyRate;
            gross = Math.mulDiv(amount, USD_SCALE, rate);
        } else {
            rate  = sellRate;
            gross = Math.mulDiv(amount, rate, USD_SCALE);

            if (gross < MIN_FEE) {
                return (0, 0, rate, false, "fee rounds to zero: trade too small");
            }
        }

        (fee, lpFee, platformFee) = _calcFee(gross);
        net = gross - fee;

        if (address(feeVault) == address(0)) {
            return (net, fee, rate, false, "fee vault not set");
        }

        if (net == 0) {
            return (net, fee, rate, false, "zero output");
        }

        // Direction-specific min checks
        if (isLCYtoUSD) {
            if (net < MIN_TRADE_USD)
                return (net, fee, rate, false, "below min trade USD");
            if (net < minOut)
                return (net, fee, rate, false, "below min USD");
        } else {
            if (net < MIN_TRADE_LCY)
                return (net, fee, rate, false, "below min trade LCY");
            if (net < minOut)
                return (net, fee, rate, false, "below min slippage");
        }

        // Pool checks
        if (isLCYtoUSD) {
            uint256 minLiqUSD = minLiquidity[address(USD)];
            uint256 cap = Math.mulDiv(usdPool-fee, MAX_WITHDRAW_BPS, FEE_DENOM);

            if (usdPool < minLiqUSD)
                return (net, fee, rate, false, "USD pool is below minimum liquidity");
            if (usdPool < gross)
                return (net, fee, rate, false, "insufficient USD pool");
            if (net > cap)
                return (net, fee, rate, false, "pool cap exceeded");
            if (usdPool < minLiqUSD + gross)
                return (net, fee, rate, false, "insufficient USD buffer");

        } else {
            uint256 minLiqLCY = minLiquidity[address(cLCY)];
            uint256 cap = Math.mulDiv(lcyPool-fee, MAX_WITHDRAW_BPS, FEE_DENOM);

            if (lcyPool < minLiqLCY)
                return (net, fee, rate, false, "LCY Pool is below minimum liquidity");
            if (lcyPool < gross)
                return (net, fee, rate, false, "insufficient LCY pool");
            if (net > cap)
                return (net, fee, rate, false, "pool cap exceeded");
            if (lcyPool < minLiqLCY + gross)
                return (net, fee, rate, false, "insufficient LCY buffer");
        }

        feasible = true;
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
    // LP — INTERNAL
    // -------------------------------------------------------

    function _addLiquidity(address lp, address token, uint256 amount, bool meta) internal {
        _checkBlockSpam(lp);
        if (amount == 0) revert ZeroAmount();

        uint256 pool          = poolDeposits[token];
        uint256 currentShares = feeVault.shares(token, lp);
        uint256 total         = feeVault.totalShares(token);

        uint256 newShares = (total == 0 || pool == 0)
            ? amount
            : Math.mulDiv(amount, total, pool);

        if (newShares == 0) revert ZeroShares();

        poolDeposits[token] += amount;
        _checkLiquidityShock(token, poolDeposits[token]);

        uint256 day = today();
        if (token == address(USD)) {
            dailyStats[day].liquidityAddedUSD  += amount;
        } else {
            dailyStats[day].liquidityAddedLCY  += amount;
        }

        feeVault.updateShares(lp, token, currentShares + newShares);
        IERC20(token).safeTransferFrom(lp, address(this), amount);
        emit LiquidityAdded(lp, token, amount, newShares, meta);
    }

    function _removeLiquidity(address lp, address token, uint256 shares, bool meta) internal {
        _checkBlockSpam(lp);
        require(shares > 0, "Zero shares");

        uint256 currentShares = feeVault.shares(token, lp);
        require(currentShares >= shares, "InsufficientShares");

        uint256 total = feeVault.totalShares(token);
        require(total > 0, "ZeroSharesForToken");

        uint256 amount = Math.mulDiv(shares, poolDeposits[token], total);
        require(amount > 0, "ZeroWithdrawal");
        require(poolDeposits[token] - amount >= minLiquidity[token], "PoolTooSmall");

        poolDeposits[token] -= amount;
        _checkLiquidityShock(token, poolDeposits[token]);

        uint256 day = today();
        if (token == address(USD)) {
            dailyStats[day].liquidityRemovedUSD  += amount;
        } else {
            dailyStats[day].liquidityRemovedLCY  += amount;
        }

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

    function _claimLP(address lp, address token) internal {
        if (address(feeVault).code.length == 0) revert FeeVaultNotContract();
        feeVault.claimFor(lp, token);
        emit LPFeeClaimed(lp, token);
    }

    function rescueToken(address receiver) external onlyOwner {
        uint balUSD = IERC20(address(USD)).balanceOf(address(this));
        IERC20(address(USD)).safeTransfer(receiver,balUSD);
        uint balLCY = IERC20(address(cLCY)).balanceOf(address(this));
        IERC20(address(cLCY)).safeTransfer(receiver,balLCY);
    }

    function _calcFee(uint256 amount)
        internal view
        returns (uint256 total, uint256 lpFee, uint256 platformFee)
    {
        total = Math.mulDiv(amount, swapFeeBps, FEE_DENOM);
        if (total == 0) revert FeeRoundsToZero();
        lpFee       = Math.mulDiv(total, lpShareBps, FEE_DENOM);
        platformFee = total - lpFee;
    }

    
    // -------------------------------------------------------
    // VIEW HELPERS
    // -------------------------------------------------------

    function pendingLPClaim(address lp, address token) external view returns (uint256) {
        if (address(feeVault).code.length == 0) revert FeeVaultNotContract();
        return feeVault.pendingClaim(lp, token);
    }

    function isPauseSwap() external view returns (bool) {
        return swapsPaused;
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getEIP712Domain()
        external view
        returns (string memory name, string memory version, uint256 chainId, address verifyingContract)
    {
        return ("FiatStablecoinAMMV16", "1", block.chainid, address(this));
    }

    function getDailyStats(uint256 day) external view returns (FiatAMMStorage.DailyStats memory) {
        return dailyStats[day];
    }

    function currentRates() external view returns (uint256 buy, uint256 sell,uint256 mid)
    {
        return (buyRate, sellRate, midPrice);
    }

    function getPoolDepth()
        external view
        returns (uint256 usdDepth, uint256 lcyDepth, uint256 minLiqUSD, uint256 minLiqLCY)
    {
        return (poolDeposits[address(USD)], poolDeposits[address(cLCY)],
         minLiquidity[address(USD)], minLiquidity[address(cLCY)]);
    }

    function getNextNonce(address addr)
        external view returns (uint256 _nonce)
    {
        return (
            nonces[addr]
        );
    }
    

}
