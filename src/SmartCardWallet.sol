// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract SmartCardWallet is EIP712, ReentrancyGuard, Initializable {

    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    //uint256 public constant MAX_DAILY_LIMIT       = 10_000_000 * 1e18;
    //uint256 public constant MAX_TX_AMOUNT         = 1_000_000  * 1e18;
    uint256 public constant MIN_SESSION_DURATION  = 1 minutes;
    uint256 public constant MAX_SESSION_DURATION  = 30 days;
    uint256 public constant MAX_GUARDIANS         = 1;

    // ===== ROLES =====
    address public owner;
    address public cardProcessor; // card processor backend
    address public riskManager; //to block, change owner, pause account in case of fraud detection
    address public guardian;
    address public lender;
    address public settlementPoolAddress;
   
    // ===== BALANCE =====
    struct Balance {
        uint256 total;
        uint256 locked;
    }

    // ===== TRANSACTIONS =====
    enum Status { NONE, PENDING, SETTLED, REVERSED,COMPLETED }

    struct TransactionLog {
        address sender;
        address token;
        uint256 amount;
        uint256 createdAt;
        bytes32 refNo;
        Status status;
    }
    
    struct PendingAction {
        bytes32  paramsHash;   // keccak256 of the proposed new value(s)
        uint256  executableAt; // timestamp after which it can be executed
        bool     exists;
    }

    mapping(ActionType => uint256)       public actionTimelock;
    mapping(ActionType => PendingAction) public pendingActions;

    uint256 public constant TIMELOCK_SENSITIVE  = 24 hours; // ownership / processor / settlement
    uint256 public constant TIMELOCK_LIMIT      =  3 hours; // limit increases

    mapping(bytes32 => TransactionLog) private transactionsByRef;
    mapping(address => bool)    public whitelisted;
    uint256 public nextSessionId = 1;

    mapping(address => uint256) public nonces;
    mapping(address => Balance) public balances;
    mapping(bytes32 => bool) public paymentIdUsed;
    uint256 public transactionCount;
    

    uint256 public dailyLimit;
    mapping(address => mapping(uint256 => uint256)) public dailySpendByToken;
    mapping(address => uint256) public tokenDailyLimit;
    mapping(address => uint256) public txSpendLimit;
    mapping(address => uint256) public minBalance; // per token minimum balance, set by risk manager
    uint256 public maxTxAmount;
    
    uint256 public cardBlockedAmount;
    uint256 public cardLimit;
    uint256 public cardMinBalance;
    bool    public paused;

    uint256 public overdraftLimit;
    uint256 public overdraftUtilizedLimit;
    uint256 public constant CARD_TX_COOLDOWN = 30 seconds;
    uint256 public lastCardTxAt;  // timestamp of last card debit
   

    // ─── EIP-712 ──────────────────────────────────────────────────────────────
    bytes32 public constant TRANSFER_TYPEHASH = keccak256(
        "Transfer(address token,address walletAddress,address to,uint256 amount,"
        "uint256 nonce,uint256 deadline,string paymentId)"
    );

     // ─── Timelock ─────────────────────────────────────────────────────────────

    enum ActionType {
        CHANGE_CARD_PROCESSOR,
        CHANGE_SETTLEMENT_ADDRESS,
        CHANGE_OWNER,
        INCREASE_DAILY_LIMIT,
        INCREASE_MAX_TX_AMOUNT,
        CHANGE_MIN_BALANCE,
        CHANGE_RISK_MANAGER,
        CHANGE_LENDER,
        CHANGE_GUARDIAN
    }

    event ActionQueued(ActionType indexed actionType, bytes32 paramsHash, uint256 executableAt);
    event ActionCancelled(ActionType indexed actionType);
    event ActionExecuted(ActionType indexed actionType, bytes32 paramsHash);
   
    // ─── Events ───────────────────────────────────────────────────────────────
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, uint256 nonce, string paymentId,bytes32 refNo);
    event PaymentExecuted(address indexed token, address indexed to, address indexed signer, uint256 amount, uint256 nonce, string paymentId, bytes32 refNo);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event UserAdded(address indexed user);
    event UserRemoved(address indexed user);
    event WhitelistUpdated(address indexed account, bool status);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event CardProcessorTransferred(address indexed oldCardProcessor, address indexed newCardProcessor);
    event Deposited(address indexed sender, address indexed token, uint256 amount, bytes32 refNo);
    event SystemAdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event DailyLimitChanged(uint256 oldLimit, uint256 newLimit);
    event MaxTxAmountChanged(uint256 oldAmount, uint256 newAmount);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event RiskManagerChanged(address indexed oldRiskManager, address indexed newRiskManager);
    event LenderChanged(address indexed oldLender, address indexed newLender);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event MinBalanceChanged(uint256 oldMinBalance, uint256 newMinBalance);
    event TransactionLimitChanged(address indexed token, uint256 newDailyLimit, uint256 tranLimit, uint256 newMinBalance);
    event TokenSpendLimitSet(address indexed token, uint256 oldLimit, uint256 newLimit);
    event Initialized(address indexed _owner, uint256 _dailyLimit, uint256 _maxTxAmount, address _guardian, address _cardProcessor);
  
    event FundBlocked(address indexed token, bytes32 indexed refNo, uint256 amount);
    event FundReleased(address indexed token, bytes32 indexed refNo, uint256 amount);
    event FundApplied(address indexed token, bytes32 indexed refNo, uint256 amount, address indexed to);
    event TokenDailyLimitSet(address indexed token, uint256 oldLimit, uint256 newLimit);
    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "NOT_GUARDIAN");
        _;
    }

    modifier onlyCardProcessor() {
        require(msg.sender == cardProcessor, "NOT_CARD_PROCESSOR");
        _;
    }
    modifier onlyRiskManager() {
        require(msg.sender == riskManager, "NOT_RISK_MANAGER");
        _;
    }

    modifier onlyOwnerOrRiskManager() {
        require(msg.sender == owner || msg.sender == riskManager, "NOT_OWNER_OR_RISK_MANAGER");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == owner || msg.sender == cardProcessor, "NOT_OWNER_OR_PROCESSOR");
        _;
    }

    modifier onlyPowerUser() {
        require(msg.sender == riskManager || msg.sender == owner || 
        msg.sender == guardian || msg.sender == lender || msg.sender == cardProcessor
        , "NOT_POWER_USER");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    modifier cardCooldown() {
        require(block.timestamp >= lastCardTxAt + CARD_TX_COOLDOWN, "CARD_COOLDOWN_ACTIVE");
        _;
        lastCardTxAt = block.timestamp;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor() EIP712("SmartCardWallet", "1") {}

    function initialize(
        address _owner,
        uint256 _dailyLimit,
        uint256 _maxTxAmount,
        address _cardProcessor,
        address _guardian,
        address _riskManager
    ) external initializer {

        require(_owner != address(0),  "OWNER_ZERO_ADDRESS");
        require(_cardProcessor != address(0),  "CARD_PROCESSOR_ZERO_ADDRESS");
        require(_riskManager != address(0),  "RISK_MANAGER_ZERO_ADDRESS");
       
        owner = _owner;
        dailyLimit = _dailyLimit;
        maxTxAmount = _maxTxAmount;
        cardProcessor = _cardProcessor;
        riskManager = _riskManager;

        if(_guardian != address(0)) {
            guardian = _guardian;
        }
        _initTimelocks();

        cardMinBalance = 100 * 1e6; // default minimum balance to prevent card from draining entire wallet, can be changed by risk manager with timelock

        emit Initialized(_owner, _dailyLimit, _maxTxAmount, _guardian,_cardProcessor);
    }

   
    // ─── Pause ────────────────────────────────────────────────────────────────
    function pause() external onlyOperator {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwnerOrRiskManager {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    function setWhitelist(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    // ─── Step 1: Initialise default timelocks ─────────────────────────────────
    function _initTimelocks() internal {
        actionTimelock[ActionType.CHANGE_CARD_PROCESSOR]      = TIMELOCK_SENSITIVE;
        actionTimelock[ActionType.CHANGE_SETTLEMENT_ADDRESS]  = TIMELOCK_SENSITIVE;
        actionTimelock[ActionType.CHANGE_OWNER]               = TIMELOCK_SENSITIVE;
        actionTimelock[ActionType.INCREASE_DAILY_LIMIT]       = TIMELOCK_LIMIT;
        actionTimelock[ActionType.INCREASE_MAX_TX_AMOUNT]     = TIMELOCK_LIMIT;
        actionTimelock[ActionType.CHANGE_MIN_BALANCE]       = TIMELOCK_LIMIT;
        actionTimelock[ActionType.CHANGE_RISK_MANAGER]            = TIMELOCK_SENSITIVE;
        actionTimelock[ActionType.CHANGE_LENDER]                  = TIMELOCK_SENSITIVE;
        actionTimelock[ActionType.CHANGE_GUARDIAN]                = TIMELOCK_SENSITIVE; 
    }

    // ─── Step 2: Override a timelock (owner, with floor) ──────────────────────
    function setActionTimelock(ActionType actionType, uint256 delay) external onlyOwnerOrRiskManager() {
        uint256 floor = _timelockFloor(actionType);
        require(delay >= floor, "BELOW_MINIMUM_TIMELOCK");
        actionTimelock[actionType] = delay;
    }

    function _timelockFloor(ActionType actionType) internal pure returns (uint256) {
        if (
            actionType == ActionType.CHANGE_CARD_PROCESSOR     ||
            actionType == ActionType.CHANGE_SETTLEMENT_ADDRESS ||
            actionType == ActionType.CHANGE_OWNER ||
            actionType == ActionType.CHANGE_RISK_MANAGER ||
            actionType == ActionType.CHANGE_LENDER ||
            actionType == ActionType.CHANGE_GUARDIAN 
        
        ) return TIMELOCK_SENSITIVE;

        if (
            actionType == ActionType.INCREASE_DAILY_LIMIT  ||
            actionType == ActionType.INCREASE_MAX_TX_AMOUNT ||
            actionType == ActionType.CHANGE_MIN_BALANCE
        ) return TIMELOCK_LIMIT;

        return 1 hours; // fallback floor for future ActionTypes
    }

    // ─── Step 3: Queue an action ───────────────────────────────────────────────
    function queueAction(
        ActionType actionType,
        bytes32    paramsHash
    ) external onlyOwner {
        require(!pendingActions[actionType].exists, "ACTION_ALREADY_QUEUED");

        uint256 delay        = actionTimelock[actionType];
        uint256 executableAt = block.timestamp + delay;

        pendingActions[actionType] = PendingAction({
            paramsHash:   paramsHash,
            executableAt: executableAt,
            exists:       true
        });

        emit ActionQueued(actionType, paramsHash, executableAt);
    }

    // ─── Step 4: Cancel a queued action ───────────────────────────────────────
    function cancelAction(ActionType actionType) external onlyOwner {
        require(pendingActions[actionType].exists, "NO_PENDING_ACTION");
        delete pendingActions[actionType];
        emit ActionCancelled(actionType);
    }

    // ─── Step 5: Internal guard used inside each execute function ─────────────
    function _consumeTimelocked(
        ActionType actionType,
        bytes32    paramsHash
    ) internal {
        PendingAction storage p = pendingActions[actionType];
        require(p.exists,                          "ACTION_NOT_QUEUED");
        require(block.timestamp >= p.executableAt, "TIMELOCK_NOT_EXPIRED");
        require(p.paramsHash == paramsHash,        "PARAMS_HASH_MISMATCH");
        delete pendingActions[actionType];
        emit ActionExecuted(actionType, paramsHash);
    }

    // ─── Execute Functions ─────────────────────────────────────────────────────
    function executeChangeOwner(address newOwner) external  {
        require(newOwner != address(0), "ZERO_ADDRESS");
        require(msg.sender == owner || msg.sender == guardian, "NOT_OWNER_OR_GUARDIAN");
        bytes32 paramsHash = keccak256(abi.encode(newOwner));
        _consumeTimelocked(ActionType.CHANGE_OWNER, paramsHash);
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function executeChangeCardProcessor(address newProcessor) external onlyOwner {
        require(newProcessor != address(0), "ZERO_ADDRESS");
        bytes32 paramsHash = keccak256(abi.encode(newProcessor));
        _consumeTimelocked(ActionType.CHANGE_CARD_PROCESSOR, paramsHash);
        emit CardProcessorTransferred(cardProcessor, newProcessor);
        cardProcessor = newProcessor;
    }

    function executeChangeRiskManager(address newRiskManager) external onlyOwner {
        require(newRiskManager != address(0), "ZERO_ADDRESS");
        bytes32 paramsHash = keccak256(abi.encode(newRiskManager));
        _consumeTimelocked(ActionType.CHANGE_RISK_MANAGER, paramsHash);
        emit RiskManagerChanged(riskManager, newRiskManager);
        riskManager = newRiskManager;
    }

    function executeChangeLender(address newLender) external onlyRiskManager {
        require(newLender != address(0), "ZERO_ADDRESS");
        bytes32 paramsHash = keccak256(abi.encode(newLender));
        _consumeTimelocked(ActionType.CHANGE_LENDER, paramsHash);
        emit LenderChanged(lender, newLender);
        lender = newLender;
    }

    function executeChangeGuardian(address newGuardian) external onlyOwner {
        require(newGuardian != address(0), "ZERO_ADDRESS");
        bytes32 paramsHash = keccak256(abi.encode(newGuardian));
        _consumeTimelocked(ActionType.CHANGE_GUARDIAN, paramsHash);
        emit GuardianChanged(guardian, newGuardian);
        guardian = newGuardian;
    }
    
    function executeChangeSettlementAddress(address newAddress) external onlyRiskManager {
        require(newAddress != address(0), "ZERO_ADDRESS");
        bytes32 paramsHash = keccak256(abi.encode(newAddress));
        _consumeTimelocked(ActionType.CHANGE_SETTLEMENT_ADDRESS, paramsHash);
        settlementPoolAddress = newAddress;
    }

    function executeIncreaseDailyLimit(uint256 newLimit) external onlyRiskManager {
        require(newLimit > dailyLimit, "NOT_AN_INCREASE");
        bytes32 paramsHash = keccak256(abi.encode(newLimit));
        _consumeTimelocked(ActionType.INCREASE_DAILY_LIMIT, paramsHash);
        emit DailyLimitChanged(dailyLimit, newLimit);
        dailyLimit = newLimit;
    }

    function executeIncreaseMaxTxAmount(uint256 newAmount) external onlyRiskManager {
        require(newAmount > maxTxAmount, "NOT_AN_INCREASE");
        bytes32 paramsHash = keccak256(abi.encode(newAmount));
        _consumeTimelocked(ActionType.INCREASE_MAX_TX_AMOUNT, paramsHash);
        emit MaxTxAmountChanged(maxTxAmount, newAmount);
        maxTxAmount = newAmount;
    }

    function executeChangeMinBalance(uint256 newAmount) external onlyRiskManager() {
        require(newAmount > 0, "NOT_ZERO");
        bytes32 paramsHash = keccak256(abi.encode(newAmount));
        _consumeTimelocked(ActionType.CHANGE_MIN_BALANCE, paramsHash);
        emit MinBalanceChanged(cardMinBalance, newAmount);
        cardMinBalance = newAmount;
    }

    function setTransactionLimits(address token, uint256 dailyLimit_, uint256 txLimit_
      , uint256 minBalance_) external onlyOwnerOrRiskManager() {
        require(dailyLimit_ > 0, "ZERO_DAILY_LIMIT");
        require(txLimit_ > 0, "ZERO_TX_LIMIT");
        require(minBalance_ > 0, "ZERO_MIN_BALANCE");
        tokenDailyLimit[token] = dailyLimit_;
        txSpendLimit[token] = txLimit_;
        minBalance[token] = minBalance_;
        emit TransactionLimitChanged(token,dailyLimit, txLimit_,minBalance_);
    }

    // ─── Admin: Set Per Token Daily Limit ─────────────────────────────────────
    function setTokenDailyLimit(address token, uint256 limit) external onlyRiskManager {
        require(limit > 0, "ZERO_LIMIT");
        emit TokenDailyLimitSet(token, tokenDailyLimit[token], limit);
        tokenDailyLimit[token] = limit;
    }
    function setTokenSpendLimit(address token, uint256 limit) external onlyRiskManager {
        require(limit > 0, "ZERO_LIMIT");
        emit TokenSpendLimitSet(token, txSpendLimit[token], limit);
        txSpendLimit[token] = limit;
    }

    function _effectiveDailyLimit(address token) internal view returns (uint256) {
        uint256 tokenLimit = tokenDailyLimit[token];
        return tokenLimit > 0 ? tokenLimit : dailyLimit;
    }

    // ─── Internal: Enforce Daily Limit ────────────────────────────────────────
    function _enforceDailyLimit(address token, uint256 amount) internal {
        uint256 dayNumber = block.timestamp / 1 days;
        uint256 limit     = _effectiveDailyLimit(token);

        require(dailySpendByToken[token][dayNumber] + amount <= limit,"DAILY_LIMIT_EXCEEDED");
        dailySpendByToken[token][dayNumber] += amount;
        
    }


    // ─── Deposit ──────────────────────────────────────────────────────────────
    function deposit(
        address token,
        bytes32 refNo,
        uint256 amount
    ) external payable whenNotPaused nonReentrant {
        require(paymentIdUsed[refNo] == false, "PAYMENT_ID_USED");

        uint256 actualAmount;
        
        if (token == address(0)) {
            require(msg.value > 0,           "ZERO_ETH");
            require(msg.value == amount,     "ETH_AMOUNT_MISMATCH");
            actualAmount = msg.value;
        } else {
            require(amount > 0,              "ZERO_AMOUNT");
            require(msg.value == 0,          "ETH_NOT_ACCEPTED_FOR_TOKEN");
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            actualAmount = IERC20(token).balanceOf(address(this)) - before;
            require(actualAmount > 0, "ZERO_RECEIVED");
                
        }

        transactionsByRef[refNo] = TransactionLog({
            sender:    msg.sender,
            token:     token,
            amount:    actualAmount,
            createdAt: block.timestamp,
            refNo:     refNo,
            status:    Status.COMPLETED
        });
        
        paymentIdUsed[refNo] = true;
        transactionCount++;
        Balance storage b = balances[token];
        b.total += actualAmount;
        emit Deposited(msg.sender, token, actualAmount, refNo);
    }

    receive() external payable {
        require(msg.value > 0, "ZERO_ETH");
        require(!paused, "PAUSED");
        bytes32 autoRef = keccak256(abi.encodePacked(msg.sender, block.timestamp, msg.value));
        require(!paymentIdUsed[autoRef], "DUPLICATE_REF");
        
        transactionsByRef[autoRef] = TransactionLog({
            sender:    msg.sender,
            token:     address(0),
            amount:    msg.value,
            createdAt: block.timestamp,
            refNo:     autoRef,
            status:    Status.COMPLETED
        });
        paymentIdUsed[autoRef] = true;
        transactionCount++;
        Balance storage b = balances[address(0)];
        b.total += msg.value;
        emit Deposited(msg.sender, address(0), msg.value, autoRef);
    }

  
    // ─── Signature Validation ─────────────────────────────────────────────────
    function _validateSignature(
        address token,
        address walletAddress,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        string memory paymentId,
        bytes memory signature
    ) internal view returns (address signer) {

        // Time
        require(block.timestamp <= deadline, "EXPIRED");
        bytes32 paymentIdHash = keccak256(bytes(paymentId));

        // nonce
        
        require(nonce == nonces[walletAddress], "INVALID_NONCE");
        require(paymentIdUsed[paymentIdHash] == false, "PAYMENT_ID_USED");
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= maxTxAmount,"TX_AMOUNT_EXCEEDS_LIMIT");
        // Wallet
        require(walletAddress != address(0), "ZERO_WALLET");
       
        // EIP-712
        
        bytes32 structHash = keccak256(abi.encode(
            TRANSFER_TYPEHASH,
            token,
            walletAddress,
            to,
            amount,
            nonce,
            deadline,
            paymentIdHash
        ));

        
        bytes32 digest = _hashTypedDataV4(structHash);
        signer = ECDSA.recover(digest, signature);
        require(signer != address(0),    "ZERO_SIGNER");
        require(signer == walletAddress, "INVALID_SIGNER");
       
    }

    // ─── Card Fund Management ─────────────────────────────────────────────────

    /**
    * @dev Block (reserve) funds on card authorisation.
    *      Called by cardProcessor when card swipe/tap is received.
    */
    function blockFund(address token,bytes32 refNo,uint256 amount) external onlyCardProcessor cardCooldown whenNotPaused nonReentrant {
        require(amount > 0, "ZERO_AMOUNT");
        require(paymentIdUsed[refNo] == false, "PAYMENT_ID_USED");
        uint256 spendLimit = txSpendLimit[token] > 0 ? txSpendLimit[token] : maxTxAmount;
        require(amount <= spendLimit, "TX_AMOUNT_EXCEEDS_LIMIT");
        
        Balance storage b = balances[token];
        require(b.total >= b.locked, "INVALID_STATE");
        uint256 available = b.total - b.locked;
        require(available >= amount, "INSUFFICIENT_AVAILABLE_BALANCE");
        uint256 minBal = minBalance[token] > 0 ? minBalance[token] : cardMinBalance;
        require(available - amount >= minBal, "MIN_BALANCE_VIOLATION");
       
        // Daily limit
        _enforceDailyLimit(token, amount);

        b.locked += amount;
        transactionsByRef[refNo] = TransactionLog({
            sender:    msg.sender,
            token:     token,
            amount:    amount,
            createdAt: block.timestamp,
            refNo:     refNo,
            status:    Status.PENDING
        });
        paymentIdUsed[refNo] = true;
        transactionCount++;

        emit FundBlocked(token, refNo, amount);
    }

    /**
    * @dev Release blocked funds on card decline / reversal / timeout.
    *      Called by cardProcessor to unwind a prior blockFund.
    */
    function releaseFund(bytes32 refNo) external onlyCardProcessor whenNotPaused nonReentrant cardCooldown {
        TransactionLog storage txLog = transactionsByRef[refNo];
        require(txLog.sender != address(0),      "REF_NOT_FOUND");
        require(txLog.status == Status.PENDING,  "NOT_PENDING");

        Balance storage b = balances[txLog.token];
        require(b.locked >= txLog.amount, "LOCKED_UNDERFLOW");
        b.locked -= txLog.amount;
        txLog.status = Status.REVERSED;
        emit FundReleased(txLog.token, refNo, txLog.amount);
    }

    /**
    * @dev Settle blocked funds — deduct from balance and push to merchant/destination.
    *      Called by cardProcessor on final settlement.
    */
    function applyFund(bytes32 refNo,address to) external onlyCardProcessor whenNotPaused nonReentrant cardCooldown {
        require(to == settlementPoolAddress, "NOT_SETTLEMENT_POOL_ADDRESS");

        TransactionLog storage txLog = transactionsByRef[refNo];
        require(txLog.sender != address(0),      "REF_NOT_FOUND");
        require(txLog.status == Status.PENDING,  "NOT_PENDING");
        //require(txLog.amount <= maxTxAmount, "TX_TOO_LARGE");
        uint256 limit = txSpendLimit[txLog.token] > 0 ? txSpendLimit[txLog.token] : maxTxAmount;
        require(txLog.amount <= limit, "TX_AMOUNT_EXCEEDS_LIMIT");

        uint256 amount = txLog.amount;
        address token  = txLog.token;

        Balance storage b = balances[token];
        require(b.locked >= amount,     "LOCKED_UNDERFLOW");
        require(b.total  >= amount,     "TOTAL_UNDERFLOW");

        uint256 minBal = minBalance[token] > 0 ? minBalance[token] : cardMinBalance;
        uint256 available = b.total - b.locked;
        require(available >= amount, "INSUFFICIENT_AVAILABLE");
        require(available - amount >= minBal, "MIN_BALANCE_VIOLATION");

        b.locked -= amount;
        b.total  -= amount;
        txLog.status = Status.SETTLED;

        // Push funds to destination
        if (token == address(0)) {
            require(address(this).balance >= amount, "INSUFFICIENT_ETH");
            (bool sent, ) = payable(to).call{value: amount}("");
            require(sent, "ETH_TRANSFER_FAILED");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit FundApplied(token, refNo, amount, to);
    }

    // ─── Execute Deposit (pull INTO contract) ────────────────────────────────
    function executeDeposit(
        address token,
        address walletAddress,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        string memory paymentId,
        bytes memory signature
    ) external payable whenNotPaused nonReentrant {

        address signer = _validateSignature(
            token, walletAddress, to, amount, nonce, deadline, paymentId, signature
        );

        require(to == address(this), "NOT_CONTRACT_ADDRESS");
        bytes32 refNo = keccak256(bytes(paymentId));
        require(paymentIdUsed[refNo] == false, "PAYMENT_ID_EXISTS");
        require(msg.sender == cardProcessor || msg.sender == owner , "NOT_AUTHORIZED");

        uint256 actualReceived = 0;

        if (token == address(0)) {
            require(msg.value == amount, "ETH_AMOUNT_MISMATCH");
            actualReceived = msg.value;
            //balances[walletAddress][token] += amount;
        } else {

            uint256 allowance = IERC20(token).allowance(walletAddress, address(this));
            require(allowance >= amount, "INSUFFICIENT_ALLOWANCE");
            require(IERC20(token).balanceOf(walletAddress) >= amount,"INSUFFICIENT_BALANCE");

            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(walletAddress, address(this), amount);
            actualReceived = IERC20(token).balanceOf(address(this)) - before;
            require(actualReceived > 0, "ZERO_RECEIVED");
            //balances[walletAddress][token] += actualReceived;
        }

        Balance storage b = balances[token];
        b.total += actualReceived;

       
       transactionsByRef[refNo] = TransactionLog({
            sender:    walletAddress,
            token:     token,
            amount:    actualReceived,
            createdAt: block.timestamp,
            refNo:     refNo,
            status:    Status.COMPLETED
        });
        paymentIdUsed[refNo] = true;
        transactionCount++;
        nonces[walletAddress]++;

        emit PaymentExecuted(token, walletAddress, signer, actualReceived, nonce, paymentId,refNo);
    }

    // ─── Execute Transfer (push OUT of contract) ──────────────────────────────
    function executeTransfer(
        address token,
        address walletAddress,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        string memory paymentId,
        bytes memory signature
    ) external whenNotPaused nonReentrant cardCooldown {

        require(to != address(0), "ZERO_ADDRESS");

        _validateSignature(
            token, walletAddress, to, amount, nonce, deadline, paymentId, signature
        );

        require(whitelisted[to], "NOT_WHITELISTED");
        require(cardProcessor == msg.sender || msg.sender == owner, "NOT_AUTHORIZED");
        bytes32 refNo = keccak256(bytes(paymentId));
        require(paymentIdUsed[refNo] == false, "PAYMENT_ID_EXISTS");
        
        
        Balance storage b = balances[token];
        uint256 available = 0;
        if (b.total > b.locked) {
            available = b.total - b.locked;
        }
        require(available >= amount, "INSUFFICIENT_BALANCE");

        uint256 limit = txSpendLimit[token] > 0 ? txSpendLimit[token] : maxTxAmount;
        require(amount <= limit, "TX_LIMIT_EXCEEDED");

        uint256 minBal = minBalance[token] > 0 ? minBalance[token] : cardMinBalance;
        require(available - amount >= minBal, "MIN_BALANCE_VIOLATION");

        // Daily limit
        _enforceDailyLimit(token, amount);

        b.total -= amount;
        require(b.total >= b.locked, "INVARIANT_BROKEN");

        if (token == address(0)) {
            require(address(this).balance >= amount, "INSUFFICIENT_ETH_BALANCE");
            (bool sent, ) = payable(to).call{value: amount}("");
            require(sent, "ETH_TRANSFER_FAILED");
        } else {
            require(IERC20(token).balanceOf(address(this)) >= amount, "INSUFFICIENT_TOKEN_BALANCE");
            IERC20(token).safeTransfer(to, amount);
        }

           
       transactionsByRef[refNo] = TransactionLog({
            sender:    walletAddress,
            token:     token,
            amount:    amount,
            createdAt: block.timestamp,
            refNo:     refNo,
            status:  Status.COMPLETED
        });
        paymentIdUsed[refNo] = true;
        transactionCount++;
        nonces[walletAddress]++;

        emit TransferExecuted(token, to, amount, nonce, paymentId, refNo);
    }
   
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant {
        require(msg.sender == owner, "NOT_AUTHORIZED");
        require(to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "ZERO_AMOUNT");
        Balance storage b = balances[token];

        require(amount <= b.total - b.locked, "INSUFFICIENT_BALANCE");

        if (token == address(0)) {
            // Withdraw ETH
            require(address(this).balance >= amount, "INSUFFICIENT_ETH_BALANCE");
            b.total -= amount;
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH_TRANSFER_FAILED");
        } else {
            // Withdraw ERC20
            require(IERC20(token).balanceOf(address(this)) >= amount, "INSUFFICIENT_TOKEN_BALANCE");
            b.total -= amount;
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyWithdraw(token, to, amount);
    }

    // ─── View Functions ───────────────────────────────────────────────────────
   
    function getLimits()
        external
        view
        returns (
            uint256 _dailyLimit,
            uint256 _maxTxAmount
        )
    {
        return (
            dailyLimit,
            maxTxAmount
        );
    }

    function getNextNonce(address addr)
        external view returns (uint256 _nonce)
    {
        return (
            nonces[addr]
        );
    }
    
    function isWhitelistedAddress(address user) external view returns (bool) {
        return whitelisted[user];
    }

    function getBalanceAndSpent(address token) external view onlyPowerUser 
        returns (uint256 _total,uint256 _locked, uint256 _dailySpent, uint256 _dailyLimit,
        uint256 _minBalance) {
            uint256 dayNumber = block.timestamp / 1 days;
            return (balances[token].total, balances[token].locked, dailySpendByToken[token][dayNumber],
             tokenDailyLimit[token], minBalance[token]);
    }

    function getSystemAddresses() external view returns (
        address _owner,
        address _cardProcessor,
        address _riskManager,
        address _guardian,
        address _lender,
        address _settlementPoolAddress
    ) {
        return (
            owner,
            cardProcessor,
            riskManager,
            guardian,
            lender,
            settlementPoolAddress
        );
    }

    // ─── Get Transactions (paginated) ─────────────────────────────────────────
   function getTransaction(bytes32 refNo)
        external
        view
        returns (
            address sender,
            address token,
            uint256 amount,
            uint256 createdAt,
            bytes32 ref,
            Status  status
        )
    {
        TransactionLog storage t = transactionsByRef[refNo];
        require(t.sender != address(0), "REF_NOT_FOUND");
        return (
            t.sender,
            t.token,
            t.amount,
            t.createdAt,
            t.refNo,
            t.status
        );
    }

    function getPendingActions(
        uint256 offset,
        uint256 limit
    ) external view returns (
        ActionType[] memory actionTypes,
        bytes32[]    memory paramsHashes,
        uint256[]    memory executableAts,
        bool[]       memory exists,
        uint256             total
    ) {
        uint256 typeCount  = uint256(type(ActionType).max) + 1;

        uint256 matchCount = 0;
        for (uint256 i = 0; i < typeCount; i++) {
            if (pendingActions[ActionType(i)].exists) matchCount++;
        }

        total = matchCount;
        if (offset >= total) return (
            new ActionType[](0),
            new bytes32[](0),
            new uint256[](0),
            new bool[](0),
            total
        );

        uint256 end        = offset + limit > total ? total : offset + limit;
        uint256 resultSize = end - offset;

        actionTypes   = new ActionType[](resultSize);
        paramsHashes  = new bytes32[]  (resultSize);
        executableAts = new uint256[]  (resultSize);
        exists        = new bool[]     (resultSize);

        uint256 idx   = 0;
        uint256 added = 0;

        for (uint256 i = 0; i < typeCount && added < resultSize; i++) {
            PendingAction storage p = pendingActions[ActionType(i)];
            if (p.exists) {
                if (idx >= offset) {
                    actionTypes[added]   = ActionType(i);
                    paramsHashes[added]  = p.paramsHash;
                    executableAts[added] = p.executableAt;
                    exists[added]        = p.exists;
                    added++;
                }
                idx++;
            }
        }
    }
}