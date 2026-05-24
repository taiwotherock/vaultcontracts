// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract BusinessSmartWalletV2 is EIP712,Initializable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

     enum ActionType {
        SPEND,               // 0
        CHANGE_LIMIT,       // 1
        CHANGE_OWNER,         // 2
        CHANGE_APPROVER,    // 3
        ADD_APPROVER,       // 4
        ADD_SPEND_WALLET,    // 5
        CHANGE_SPENDER_LIMIT, // 6
        CHANGE_AUTO_APPROVE_LIMIT, // 7
        ENABLE_SPEND_WALLET, // 8
        ENABLE_APPROVER,      // 9
        CHANGE_TIMELOCK   //10
    }

    enum UserRole {
        INITIATOR,
        MANAGER,
        OPERATION,
        SPEND_OWNER
    }

    enum TransactionType {
        DEPOSIT,
        TRANSFER,
        PAYMENT,
        SPEND,
        INVEST,
        GIFTING,
        SALARY_ADVANCE,
        BILL_PAYMENT,
        NON_SPEND,
        BANK_WITHDRAWAL,
        CARD_SPEND
    }

    struct ActionRequest {
        ActionType actionType;
        address maker;
        bytes32 refNo;
        uint256 createdAt;
        uint256 executeAfter;
        uint256 expiry;
        bool executed;
        address addressValue;
        uint256 intValue;
        uint256 intValue2;
        uint256 approvalCount;
    }

    struct Approver {
        uint256 amount;
        bool status;
    }

    struct SpendWallet {
        address token;
        uint256 maxLimit;
        uint256 dailyLimit;
        uint256 monthlyLimit;
        bool status;
        uint256 dayNumber;
        uint256 monthNumber;
        uint256 dailySpent;
        uint256 monthlySpent;
        uint256 lastTxTimestamp;
        uint256 totalSpent;
    }

    struct TempLog {
        address sender;
        address token;
        address beneficiary;
        uint256 amount;
        bytes32 refNo;
        TransactionType tranType;
        uint256 amount2;
        uint256 amount3;
    }

    struct TransactionLog {
        address sender;
        address token;
        address beneficiary;
        uint256 amount;
        uint256 createdAt;
        bytes32 refNo;
        TransactionType tranType;
    }

    uint256 public APPROVAL_THRESHOLD;
    uint256 public NO_OF_APPROVALS;
    uint256 public cooldownPeriod;
    uint256 public dailyLimit;
    uint256 public autoApproveLimit;
    uint256 public maxTxAmount;

    address public owner;
    address public relayer;
    //address public cardProcessor;

    uint256 public constant MAX_TIMELOCK = 2 days;

    mapping(bytes32 => TransactionLog) public transactionsByRef;
    mapping(bytes32 => TempLog) public tempLogByRef;
    mapping(bytes32 => ActionRequest) public actions;
    mapping(address => bytes32[]) public senderRefs;
    mapping(address => uint256) public spendNonces;
    mapping(address => uint256) public approvalNonces;
    mapping(address => bool) public allowedTokens;
    mapping(address => SpendWallet) public spenders;
    mapping(address => Approver) public approvers;
    mapping(address => mapping(bytes32 => bool)) public approvals;
    mapping(uint256 => uint256) public dailyTransferred;
    mapping(ActionType => uint256) public actionTimelock;

    address[] private _approverList;
    address[] private _spenderList;
    //mapping(address => uint256) private _spenderIdx; // 1-based

    //bytes32[] private _pendingTempRefs;
    //mapping(bytes32 => uint256) private _pendingTempIdx; // 1-based

    //bytes32[] private _actionRefs;
    //mapping(bytes32 => uint256) private _actionIdx; // 1-based

    bytes32 public constant AUTOSPEND_TYPEHASH = keccak256(
        "AutoSpend(address sender,address token,uint256 amount,uint256 nonce,uint256 deadline,string refNo,uint256 tranType)"
    );

    bytes32 public constant APPROVE_ACTION_TYPEHASH = keccak256(
        "ApproveAction(address sender,string refNo,uint256 deadline,uint256 nonce)"
    );

    event Initialized(address indexed owner, address indexed relayer);
    event TokenAllowed(address indexed token, bool status);
    event Deposited(address indexed sender, address indexed token, address indexed beneficiary, uint256 amount, bytes32 refNo, TransactionType tranType);
    event Spent(address indexed sender, address indexed token, address indexed beneficiary, uint256 amount, bytes32 refNo, TransactionType tranType);
    event AutoSpent(address indexed spender, address indexed token, bytes32 refNo, uint256 amount, TransactionType tranType);
    event ActionProposed(bytes32 indexed refNo, ActionType actionType, address indexed maker, uint256 executeAfter, address indexed target, uint256 amount);
    event ActionApproved(bytes32 indexed refNo, address indexed approver, uint256 approvalCount);
    event ActionExecuted(bytes32 indexed refNo, ActionType actionType);
    event ActionCancelled(bytes32 indexed refNo);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PausedState(address indexed account);
    event UnpausedState(address indexed account);
    event TimelockChanged(ActionType indexed actionType, uint256 delay);
    event CooldownPeriodUpdated(uint256 period);
    event ChangeSpendWalletStatus(address indexed spender, bool status);
    event DisabledApprover(address indexed approver);
    event ChangedSpendWalletLimit(bytes32 indexed refNo, address indexed spender, uint256 maxLimit, uint256 dailyLimit, uint256 monthlyLimit);
    event VaultSpendApproved(address indexed token, address indexed spender, uint256 amount);
    event UnsupportedTokenRescued(address indexed token, address indexed to, uint256 amount);
    event UpdateApproverStatus(address indexed approver,bool status);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyApprover() {
        require(approvers[msg.sender].status, "NOT_APPROVER");
        _;
    }

    modifier onlyPowerUser() {
        require(msg.sender == owner || msg.sender == relayer || approvers[msg.sender].status, "NOT_POWER_USER");
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == owner || msg.sender == relayer, "NOT_EXECUTOR_ROLE");
        _;
    }

    constructor() EIP712("BusinessSmartWalletV2", "1") {}

    function initialize(
        address _owner,
        address _relayer,
        uint256 _dailyLimit,
        uint256 _maxTxAmount,
        uint256 _approvalThreshold,
        uint256 _noOfApprovals,
        address approver1,
        address approver2,
        address approver3
    ) external initializer {
        require(_owner != address(0), "INVALID_OWNER");
        require(_relayer != address(0), "INVALID_RELAYER");

        require(approver1 != address(0), "ZERO_APPROVER");
        require(approver2 != address(0), "ZERO_APPROVER");
        require(approver3 != address(0), "ZERO_APPROVER");

        require(_approvalThreshold > 0, "INVALID_THRESHOLD");
        require(_approvalThreshold <= _noOfApprovals, "INVALID_APPROVAL_CONFIG");

        owner = _owner;
        relayer = _relayer;
        dailyLimit = _dailyLimit;
        maxTxAmount = _maxTxAmount;
        APPROVAL_THRESHOLD = _approvalThreshold;
        NO_OF_APPROVALS = _noOfApprovals;
        cooldownPeriod = 1 minutes;

        actionTimelock[ActionType.SPEND] = 1 hours;
        actionTimelock[ActionType.CHANGE_OWNER] = 1 days;
        actionTimelock[ActionType.CHANGE_LIMIT] = 1 days;
        actionTimelock[ActionType.ADD_APPROVER] = 1 hours;
        actionTimelock[ActionType.CHANGE_APPROVER] = 6 hours;
        actionTimelock[ActionType.ADD_SPEND_WALLET] = 1 hours;
        actionTimelock[ActionType.CHANGE_SPENDER_LIMIT] = 1 hours;

        setDefaultApprovers(approver1,approver2,approver3);

        emit Initialized(_owner, _relayer);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function pause() external onlyOwner {
        _pause();
        emit PausedState(msg.sender);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit UnpausedState(msg.sender);
    }

    function setAllowedToken(address token, bool status) external onlyOwner {
        require(token != address(0), "ZERO_ADDRESS");
        allowedTokens[token] = status;
        emit TokenAllowed(token, status);
    }

    function setCooldownPeriod(uint256 period) external onlyOwner {
        require(period <= 1 hours, "INVALID_PERIOD");
        cooldownPeriod = period;
        emit CooldownPeriodUpdated(period);
    }


    function changeOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setDefaultApprovers(address approver1,address approver2,address approver3) internal {

        approvers[approver1] = Approver({
            amount: maxTxAmount,
            status: true
        });
        _approverList.push(approver1);

        approvers[approver2] = Approver({
            amount: maxTxAmount,
            status: true
        });
        _approverList.push(approver2);

        approvers[approver3] = Approver({
            amount: maxTxAmount,
            status: true
        });
        _approverList.push(approver3);
        
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    receive() external payable {
        require(msg.value > 0, "ZERO_ETH");
        bytes32 autoRef = keccak256(abi.encodePacked(msg.sender, block.timestamp, msg.value, block.prevrandao));
        transactionsByRef[autoRef] = TransactionLog({
            sender:    msg.sender,
            token:     address(0),
            beneficiary: address(this),
            amount:    msg.value,
            createdAt: block.timestamp,
            refNo:     autoRef,
            tranType: TransactionType.DEPOSIT
        });
       
        senderRefs[msg.sender].push(autoRef);
        emit Deposited(msg.sender, address(0), address(this), msg.value, autoRef, TransactionType.DEPOSIT);
    }

    function deposit(address token, bytes32 refNo, uint256 amount) external payable nonReentrant whenNotPaused {
        require(transactionsByRef[refNo].sender == address(0), "REF_EXISTS");

        uint256 actualAmount;

        if (token == address(0)) {
            require(msg.value == amount, "INVALID_ETH_AMOUNT");
            actualAmount = amount;
        } else {
            require(allowedTokens[token], "TOKEN_NOT_ALLOWED");
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            actualAmount = amount;
        }

        transactionsByRef[refNo] = TransactionLog({
            sender: msg.sender,
            token: token,
            beneficiary: address(this),
            amount: actualAmount,
            createdAt: block.timestamp,
            refNo: refNo,
            tranType: TransactionType.DEPOSIT
        });

        senderRefs[msg.sender].push(refNo);

        emit Deposited(msg.sender, token, address(this), actualAmount, refNo, TransactionType.DEPOSIT);
    }

    function disableApprover(address approver) external onlyOwner {
        uint256 activeApprovers = _getActiveApproverCount();
        require(activeApprovers - 1 >= APPROVAL_THRESHOLD,"THRESHOLD_BREAK");
        approvers[approver].status = false;
        emit DisabledApprover(approver);
    }

    // ─── Spend Wallets ────────────────────────────────────────────────────────

    /// @notice Directly add a spend wallet (owner only, no timelock).
    function addSpendWallet(
        bytes32 refNo,
        address spender,
        address token,
        uint256 maxLimit,
        uint256 monthlyLimit,
        uint256 dailySpendLimit
    ) external onlyOwner whenNotPaused {
        require(spender != address(0), "ZERO_SPENDER");
        require(allowedTokens[token], "TOKEN_NOT_ALLOWED");
        require(spenders[spender].token == address(0), "SPENDER_EXISTS");

        spenders[spender] = SpendWallet({
            token: token,
            maxLimit: maxLimit,
            dailyLimit: dailySpendLimit,
            monthlyLimit: monthlyLimit,
            status: true,
            dayNumber: 0,
            monthNumber: 0,
            dailySpent: 0,
            monthlySpent: 0,
            lastTxTimestamp: 0,
            totalSpent: 0
        });
        _spenderList.push(spender);
        emit ChangedSpendWalletLimit(refNo, spender, maxLimit, dailySpendLimit, monthlyLimit);
    }

    function disableSpendWallet(address spender) external onlyOwner {
        require(spenders[spender].token != address(0), "SPENDER_NOT_FOUND");
        spenders[spender].status = false;
        emit ChangeSpendWalletStatus(spender, false);
    }

    function enableSpendWallet(address spender) external onlyOwner {
        require(spenders[spender].token != address(0), "SPENDER_NOT_FOUND");
        spenders[spender].status = true;
        emit ChangeSpendWalletStatus(spender, true);
    }

    // ─── Spend Limits ─────────────────────────────────────────────────────────

    function _enforceGlobalDailySpendLimit(uint256 amount) internal view {
        uint256 dayNumber = block.timestamp / 1 days;
        require(dailyTransferred[dayNumber] + amount <= dailyLimit, "DAILY_LIMIT_EXCEEDED");
    }

    function _enforceDailySpenderLimit(uint256 amount, SpendWallet storage window) internal {
        uint256 today = block.timestamp / 1 days;
        if (window.dayNumber < today) {
            window.dayNumber = today;
            window.dailySpent = 0;
        }
        require(window.dailySpent + amount <= window.dailyLimit, "SPENDER_DAILY_LIMIT");
    }

    function _enforceMonthlySpenderLimit(uint256 amount, SpendWallet storage window) internal {
        uint256 currentMonth = block.timestamp / 30 days;
        if (window.monthNumber < currentMonth) {
            window.monthNumber = currentMonth;
            window.monthlySpent = 0;
        }
        require(window.monthlySpent + amount <= window.monthlyLimit, "SPENDER_MONTHLY_LIMIT");
    }

    function _enforceCooldown(SpendWallet storage window) internal view {
        require(block.timestamp >= window.lastTxTimestamp + cooldownPeriod, "COOLDOWN_ACTIVE");
    }

    // ─── Auto Spend ───────────────────────────────────────────────────────────
    
    function submitSignedSpend(address sender,address token,uint256 amount,
    uint256 nonce,uint256 deadline,string memory refNo,uint256 tranType,
     bytes memory signature) external nonReentrant whenNotPaused onlyPowerUser
    {
        require(block.timestamp <= deadline, "EXPIRED");
        require(sender != address(0), "INVALID_WALLET");
        require(amount > 0, "ZERO_AMOUNT");
        require(nonce == spendNonces[sender], "INVALID_NONCE");
        

        bytes32 paymentHash = keccak256(bytes(refNo));
        bytes32 structHash = keccak256(
            abi.encode(
                AUTOSPEND_TYPEHASH,
                sender,
                token,
                amount,
                nonce,
                deadline,
                paymentHash,
                tranType
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == sender, "INVALID_SIGNER");
        require(allowedTokens[token], "TOKEN_NOT_ALLOWED");
        _autoSpend(sender,paymentHash,amount,token, TransactionType(tranType));
        spendNonces[sender]++;
        
    }

    function autoSpend(address beneficiary,bytes32 refNo,uint256 amount,address token, TransactionType tranType) external onlyExecutor nonReentrant whenNotPaused 
    {
       _autoSpend(beneficiary,refNo,amount,token,tranType);
       
    }

    function _autoSpend(
        address beneficiary,
        bytes32 refNo,
        uint256 amount,
        address token,
        TransactionType tranType
    ) internal {
        require(transactionsByRef[refNo].sender == address(0), "REF_EXISTS");

        SpendWallet storage spender = spenders[beneficiary];

        require(spender.status, "SPENDER_DISABLED");
        require(spender.token == token, "INVALID_TOKEN");
        require(amount <= spender.maxLimit, "MAX_LIMIT_EXCEEDED");

        _enforceCooldown(spender);
        _enforceDailySpenderLimit(amount, spender);
        _enforceMonthlySpenderLimit(amount, spender);

        require(IERC20(token).balanceOf(address(this)) >= amount, "INSUFFICIENT_BALANCE");

        transactionsByRef[refNo] = TransactionLog({
            sender: msg.sender,
            token: token,
            beneficiary: msg.sender,
            amount: amount,
            createdAt: block.timestamp,
            refNo: refNo,
            tranType: tranType
        });

        senderRefs[beneficiary].push(refNo);

        uint256 dayNumber = block.timestamp / 1 days;
        dailyTransferred[dayNumber] += amount;

        spender.dailySpent += amount;
        spender.monthlySpent += amount;
        spender.lastTxTimestamp = block.timestamp;
        spender.totalSpent += amount;
        
        IERC20(token).safeTransfer(beneficiary, amount);

        emit AutoSpent(beneficiary, token, refNo, amount, tranType);
    }

    // ─── Governance: Propose ──────────────────────────────────────────────────

    /// @notice Propose a governed spend (timelock + multi-sig).
    function initiateSpend(
        address token,
        uint256 amount,
        address beneficiary,
        bytes32 refNo,
        TransactionType tranType
    ) external onlyPowerUser whenNotPaused nonReentrant {
        require(actions[refNo].maker == address(0), "ACTION_EXISTS");
        require(spenders[beneficiary].status, "INVALID_SPENDER");
        if (token != address(0)) {
            require(allowedTokens[token], "TOKEN_NOT_ALLOWED");
        }

        tempLogByRef[refNo] = TempLog({
            sender: msg.sender,
            token: token,
            beneficiary: beneficiary,
            amount: amount,
            refNo: refNo,
            tranType: tranType,
            amount2: 0,
            amount3: 0
        });

        uint256 executeAfter = block.timestamp + actionTimelock[ActionType.SPEND];

        actions[refNo] = ActionRequest({
            actionType: ActionType.SPEND,
            maker: msg.sender,
            refNo: refNo,
            createdAt: block.timestamp,
            executeAfter: executeAfter,
            expiry: executeAfter + 1 days,
            executed: false,
            addressValue: beneficiary,
            intValue: amount,
            intValue2: 0,
            approvalCount: 0
        });

        emit ActionProposed(refNo, ActionType.SPEND, msg.sender, executeAfter, beneficiary, amount);
    }

    /// @notice Generic governance proposal for approver/wallet configuration changes.
    // FIX #1 : whenNotPaused (was whenNotPause)
    // FIX #2 : removed undeclared actionCount++
    // FIX #3 : addressValue: addressValue (was beneficiary — undeclared)
    // FIX #4 : emit uses actionType variable (was hardcoded ActionType.SPEND)
    // FIX #5 : CHANGE_APPROVER guard corrected (was inverted)
    function proposeAction(
        ActionType actionType,
        address addressValue,
        bytes32 refNo,
        uint256 intValue,
        uint256 intValue2,
        uint256 expiry
    ) external whenNotPaused nonReentrant onlyApprover {
        require(expiry > block.timestamp, "INVALID_EXPIRY");
        require(addressValue != address(0), "ZERO_ADDRESS");
        require(actions[refNo].maker == address(0), "ACTION_EXISTS");
        require(msg.sender != owner && msg.sender != relayer, "ROLE_NOT_ALLOWED_TO_PROPOSE");

        if (actionType == ActionType.ADD_APPROVER) {
            require(!approvers[addressValue].status, "ALREADY_APPROVER");
        } else if (actionType == ActionType.CHANGE_APPROVER) {
            // FIX #5: CHANGE requires the approver to already exist (was !status)
            require(approvers[addressValue].status, "NOT_EXISTING_APPROVER");
        }
        else if (actionType == ActionType.CHANGE_TIMELOCK) {
            require(intValue <= MAX_TIMELOCK, "TIMELOCK_TOO_LONG");
            require(intValue >= 1 hours, "TIMELOCK_TOO_SHORT");

        }

       

        uint256 executeAfter = block.timestamp + actionTimelock[actionType];

        actions[refNo] = ActionRequest({
            actionType: actionType,
            maker: msg.sender,
            refNo: refNo,
            createdAt: block.timestamp,
            executeAfter: executeAfter,
            expiry: expiry,
            executed: false,
            addressValue: addressValue, // FIX #3
            intValue: intValue,
            intValue2: intValue2,
            approvalCount: 0
        });

        emit ActionProposed(refNo, actionType, msg.sender, executeAfter, addressValue, intValue); // FIX #4
    }

    /// @notice Propose adding a spend wallet through governance (timelock + multi-sig).
    // FIX #11: renamed from addSpendWallet — duplicate function signature
    // FIX #12: expiry computed from timelock (was undeclared); dailySpendLimit avoids state-var shadow
    // FIX #13: tranType: TransactionType.NON_SPEND (was undeclared tranType)
    function proposeAddSpendWallet(
        bytes32 refNo,
        address spender,
        address token,
        uint256 maxLimit,
        uint256 monthlyLimit,
        uint256 dailySpendLimit // FIX #12: renamed from dailyLimit to avoid shadowing state var
    ) external whenNotPaused nonReentrant onlyOwner {
        require(spender != address(0), "ZERO_SPENDER");
        require(token != address(0), "ZERO_TOKEN");
        require(spenders[spender].token == address(0), "EXISTING_SPENDER");
        require(transactionsByRef[refNo].sender == address(0), "REF_EXISTS");
        require(tempLogByRef[refNo].sender == address(0), "REF_EXISTS");
        require(actions[refNo].maker == address(0), "REF_EXISTS");
        require(allowedTokens[token], "TOKEN_NOT_ALLOWED");

        uint256 executeAfter = block.timestamp + actionTimelock[ActionType.ADD_SPEND_WALLET]; // FIX #12
        uint256 expiry = executeAfter + 1 days;

        tempLogByRef[refNo] = TempLog({
            sender: msg.sender,
            token: token,
            beneficiary: spender,
            amount: maxLimit,
            refNo: refNo,
            tranType: TransactionType.NON_SPEND, // FIX #13
            amount2: dailySpendLimit,
            amount3: monthlyLimit
        });

        actions[refNo] = ActionRequest({
            actionType: ActionType.ADD_SPEND_WALLET,
            maker: msg.sender,
            refNo: refNo,
            createdAt: block.timestamp,
            executeAfter: executeAfter,
            expiry: expiry,
            executed: false,
            addressValue: spender,
            intValue: maxLimit,
            intValue2: 0,
            approvalCount: 0
        });

        emit ActionProposed(refNo, ActionType.ADD_SPEND_WALLET, msg.sender, executeAfter, spender, maxLimit);
    }

    /// @notice Propose changing a spend wallet's limits through governance.
    // FIX #1 : whenNotPaused (was whenNotPause)
    // FIX #12: expiry computed; dailySpendLimit avoids shadow; tranType fixed
    function changeSpenderLimit(
        bytes32 refNo,
        address spender,
        address token,
        uint256 maxLimit,
        uint256 monthlyLimit,
        uint256 dailySpendLimit // FIX #12: renamed
    ) external whenNotPaused nonReentrant onlyOwner {
        require(spender != address(0), "ZERO_SPENDER");
        require(token != address(0), "ZERO_TOKEN");
        require(spenders[spender].token != address(0), "SPENDER_NOT_FOUND");
        require(transactionsByRef[refNo].sender == address(0), "REF_EXISTS");
        require(tempLogByRef[refNo].sender == address(0), "REF_EXISTS");
        require(actions[refNo].maker == address(0), "REF_EXISTS");
        require(allowedTokens[token], "TOKEN_NOT_ALLOWED");

        uint256 executeAfter = block.timestamp + actionTimelock[ActionType.CHANGE_SPENDER_LIMIT]; // FIX #12
        uint256 expiry = executeAfter + 1 days;

        tempLogByRef[refNo] = TempLog({
            sender: msg.sender,
            token: token,
            beneficiary: spender,
            amount: maxLimit,
            refNo: refNo,
            tranType: TransactionType.NON_SPEND, // FIX #13
            amount2: dailySpendLimit,
            amount3: monthlyLimit
        });

        actions[refNo] = ActionRequest({
            actionType: ActionType.CHANGE_SPENDER_LIMIT,
            maker: msg.sender,
            refNo: refNo,
            createdAt: block.timestamp,
            executeAfter: executeAfter,
            expiry: expiry,
            executed: false,
            addressValue: spender,
            intValue: maxLimit,
            intValue2: 0,
            approvalCount: 0
        });

        emit ActionProposed(refNo, ActionType.CHANGE_SPENDER_LIMIT, msg.sender, executeAfter, spender, maxLimit);
    }

    // ─── Governance: Approve ──────────────────────────────────────────────────

    function submitSignedApproval(address sender,string memory refNo,
        uint256 deadline,uint256 nonce,bytes memory signature) external nonReentrant whenNotPaused onlyPowerUser
    {
        
        require(block.timestamp <= deadline, "EXPIRED");
        require(sender != address(0), "INVALID_WALLET");
        require(nonce == approvalNonces[sender], "INVALID_NONCE");

        bytes32 paymentHash = keccak256(bytes(refNo));
        bytes32 structHash = keccak256(
            abi.encode(
                APPROVE_ACTION_TYPEHASH,
                sender,
                paymentHash,
                deadline,
                nonce
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == sender, "INVALID_SIGNER");
        approvalNonces[sender]++;
        _approveAction(signer,paymentHash);
        
    }

    function approveAction(bytes32 refNo) external onlyApprover whenNotPaused {
        _approveAction(msg.sender,refNo);
    }

    function _approveAction(address signer,bytes32 refNo) internal {
        ActionRequest storage action = actions[refNo];

        require(action.maker != address(0), "INVALID_ACTION");
        require(!action.executed, "ALREADY_EXECUTED");
        require(!approvals[signer][refNo], "ALREADY_APPROVED");
        require(action.maker != signer, "MAKER_CANNOT_APPROVE");
        require(approvers[signer].status, "ONLY_APPROVER");

        require(signer != owner, "OWNER_CANNOT_APPROVE_ACTION");
        require(signer != relayer, "RELAYER_CANNOT_APPROVE_ACTION");
        
        approvals[signer][refNo] = true;
        action.approvalCount += 1;

        emit ActionApproved(refNo, signer, action.approvalCount);
    }

    function _getActiveApproverCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < _approverList.length; i++) {
            if (approvers[_approverList[i]].status) {
                count++;
            }
        }
    }

    // ─── Governance: Execute ──────────────────────────────────────────────────

    // FIX #1 : whenNotPaused (was whenNotPause)
    // FIX #6 : ActionRequest storage (was ActionType storage)
    // FIX #7 : removed spurious require(!approvals[msg.sender][refNo]) that blocked execution
    // FIX #8 : emit ActionExecuted(refNo, …) (was undeclared actionId)
    // FIX #9 : ENABLE_SPEND_WALLET calls new _enableSpendWallet()
    // FIX #10: ENABLE_APPROVER calls new _enableApprover()
    function executeAction(bytes32 refNo) external whenNotPaused nonReentrant onlyExecutor {
        ActionRequest storage action = actions[refNo]; // FIX #6

        require(action.maker != address(0), "INVALID_ACTION");
        require(!action.executed, "ALREADY_EXECUTED");
        require(block.timestamp >= action.executeAfter, "TIMELOCK_ACTIVE");
        require(block.timestamp <= action.expiry, "EXPIRED");
        require(action.maker != msg.sender, "MAKER_CANNOT_EXECUTE");
        

        //uint256 activeApprovers = _getActiveApproverCount();
        //require(activeApprovers >= APPROVAL_THRESHOLD, "INSUFFICIENT_ACTIVE_APPROVERS");
        require(action.approvalCount >= APPROVAL_THRESHOLD, "THRESHOLD_NOT_MET");

        action.executed = true;

        if (action.actionType == ActionType.SPEND) {
            TempLog storage tempLog = tempLogByRef[refNo];
            if(tempLog.token == address(0))
               _spendETH(tempLog.amount,tempLog.beneficiary,tempLog.refNo,tempLog.tranType);
            else
              _spend(tempLog.token, tempLog.amount, tempLog.beneficiary, tempLog.refNo, tempLog.tranType);
        } else if (action.actionType == ActionType.ADD_SPEND_WALLET) {
            _addSpendWallet(refNo);
        } else if (action.actionType == ActionType.ADD_APPROVER) {
            _addApprover(refNo);
        } else if (action.actionType == ActionType.CHANGE_APPROVER) {
            _changeApprover(refNo);
        } else if (action.actionType == ActionType.CHANGE_SPENDER_LIMIT) {
            _changeSpendWallet(refNo);
        } else if (action.actionType == ActionType.ENABLE_SPEND_WALLET) {
            _enableSpendWallet(action.addressValue, true); // FIX #9
        } else if (action.actionType == ActionType.ENABLE_APPROVER) {
            _enableApprover(action.addressValue, true); // FIX #10
        } else if (action.actionType == ActionType.CHANGE_TIMELOCK) {
            _changeTimelock(action.refNo);
        } else {
            revert("INVALID_ACTION");
        }

        _deleteApprovalRefs(action.refNo);

        emit ActionExecuted(refNo, action.actionType); // FIX #8
    }

    // ─── Governance: Cancel ───────────────────────────────────────────────────

    function cancelAction(bytes32 refNo) external onlyPowerUser nonReentrant {
        ActionRequest storage action = actions[refNo];

        require(!action.executed, "ALREADY_EXECUTED");
        require(msg.sender == action.maker || msg.sender == owner, "NOT_AUTHORIZED");

        action.executed = true;
        _deleteApprovalRefs(refNo);
        emit ActionCancelled(refNo);
    }

    function _deleteApprovalRefs(bytes32 refNo) internal
    {
        
        if(tempLogByRef[refNo].sender != address(0))
            delete tempLogByRef[refNo];

        for (uint256 i = 0; i < _approverList.length; i++) {
            address approver = _approverList[i];
            delete approvals[approver][refNo];
        }
    }

    // ─── Internal: Execution Handlers ─────────────────────────────────────────

    function _spend(
        address token,
        uint256 amount,
        address beneficiary,
        bytes32 refNo,
        TransactionType tranType
    ) internal {
        SpendWallet storage wallet = spenders[beneficiary];

        require(wallet.status, "SPENDER_DISABLED");
        require(wallet.token == token, "INVALID_TOKEN");

        //_enforceGlobalDailySpendLimit(amount);
        _enforceDailySpenderLimit(amount, wallet);
        _enforceMonthlySpenderLimit(amount, wallet);

        require(IERC20(token).balanceOf(address(this)) >= amount, "INSUFFICIENT_BALANCE");

        transactionsByRef[refNo] = TransactionLog({
            sender: msg.sender,
            token: token,
            beneficiary: beneficiary,
            amount: amount,
            createdAt: block.timestamp,
            refNo: refNo,
            tranType: tranType
        });

        uint256 dayNumber = block.timestamp / 1 days;
        dailyTransferred[dayNumber] += amount;
        wallet.dailySpent += amount;
        wallet.monthlySpent += amount;
        wallet.totalSpent += amount;
        wallet.lastTxTimestamp = block.timestamp;

        IERC20(token).safeTransfer(beneficiary, amount);

        emit Spent(msg.sender, token, beneficiary, amount, refNo, tranType);
    }

    function _spendETH(
        uint256 amount,
        address beneficiary,
        bytes32 refNo,
        TransactionType tranType
    ) internal {
      
        require(address(this).balance >= amount, "INSUFFICIENT_ETH");
        SpendWallet storage wallet = spenders[beneficiary];
        require(wallet.status, "SPENDER_DISABLED");
        require(amount <= wallet.maxLimit, "MAX_LIMIT_EXCEEDED");

        _enforceDailySpenderLimit(amount, wallet);
        _enforceMonthlySpenderLimit(amount, wallet);
        _enforceCooldown(wallet);

        transactionsByRef[refNo] = TransactionLog({
            sender: msg.sender,
            token: address(0),
            beneficiary: beneficiary,
            amount: amount,
            createdAt: block.timestamp,
            refNo: refNo,
            tranType: tranType
        });


       (bool success, ) = beneficiary.call{value: amount}("");
        require(success, "ETH_TRANSFER_FAILED");
        emit Spent(msg.sender, address(0), beneficiary, amount, refNo, tranType);
    }

    // FIX #14: monthNumber: 0 added to struct literal
    // FIX #15: delete tempLogByRef[refNo] (was delete templog — deletes pointer, not entry)
    // FIX #16: cache spenderAddr before delete; SpendWallet has no .beneficiary field
    function _addSpendWallet(bytes32 refNo) internal {

        
        TempLog storage templog = tempLogByRef[refNo];

        address spenderAddr  = templog.beneficiary; // FIX #16: cache before delete
        address spenderToken = templog.token;
        uint256 _maxLimit    = templog.amount;
        uint256 _dailyLimit  = templog.amount2;
        uint256 _monthlyLimit = templog.amount3;
        require(spenders[spenderAddr].token == address(0), "SPENDER_EXISTS");

        spenders[spenderAddr] = SpendWallet({
            token: spenderToken,
            maxLimit: _maxLimit,
            dailyLimit: _dailyLimit,
            monthlyLimit: _monthlyLimit,
            status: true,
            dayNumber: 0,
            monthNumber: 0, // FIX #14
            dailySpent: 0,
            monthlySpent: 0,
            lastTxTimestamp: 0,
            totalSpent: 0
        });

        delete tempLogByRef[refNo]; // FIX #15
        emit ChangedSpendWalletLimit(refNo, spenderAddr, _maxLimit, _dailyLimit, _monthlyLimit);
    }

    // FIX #15/#16: same fixes as _addSpendWallet
    function _changeSpendWallet(bytes32 refNo) internal {
        TempLog storage templog = tempLogByRef[refNo];
        address spenderAddr   = templog.beneficiary; // FIX #16
        uint256 _maxLimit     = templog.amount;
        uint256 _dailyLimit   = templog.amount2;
        uint256 _monthlyLimit = templog.amount3;

        SpendWallet storage spender = spenders[spenderAddr];
        spender.maxLimit     = _maxLimit;
        spender.dailyLimit   = _dailyLimit;
        spender.monthlyLimit = _monthlyLimit;

        delete tempLogByRef[refNo]; // FIX #15
        emit ChangedSpendWalletLimit(refNo, spenderAddr, _maxLimit, _dailyLimit, _monthlyLimit);
    }

    // FIX #9: new helper for ENABLE_SPEND_WALLET action
    function _enableSpendWallet(address spender, bool status) internal {
        require(spenders[spender].token != address(0), "SPENDER_NOT_FOUND");
        spenders[spender].status = status;
        emit ChangeSpendWalletStatus(spender, status);
    }

    // FIX #10: new helper for ENABLE_APPROVER action
    function _enableApprover(address approver, bool status) internal {
        approvers[approver].status = status;
        emit UpdateApproverStatus(approver,status);
    }

    // FIX #17: added `internal` visibility
    // FIX #18: Approver struct now includes `role` field
    // FIX #19: push to _approverList on first-time add
    function _addApprover(bytes32 refNo) internal {

        

        ActionRequest storage action = actions[refNo];
        address approverAddr = action.addressValue;
        require(approverAddr != owner, "OWNER_CANNOT_BE_APPROVER");
        require(approverAddr != relayer, "RELAYER_CANNOT_BE_APPROVER");

        if (approvers[approverAddr].amount == 0 && !approvers[approverAddr].status) {
            _approverList.push(approverAddr); // FIX #19
        }

        uint256 limit = action.intValue == 0 ? maxTxAmount : action.intValue;

        approvers[approverAddr] = Approver({
            amount: limit,
            status: true // FIX #18: default role for governance-added approvers
        });
    }

    // FIX #17: added `internal` visibility
    // FIX #18: Approver struct now includes `role` field (existing role preserved)
    function _changeApprover(bytes32 refNo) internal {
        ActionRequest storage action = actions[refNo];
        address approverAddr = action.addressValue;
        approvers[approverAddr].amount = action.intValue;

    }

    // ─── Vault Approval ───────────────────────────────────────────────────────

    function approveVaultSpend(
        address token,
        address spender,
        uint256 amount
    ) external onlyOwner whenNotPaused nonReentrant {
        require(allowedTokens[token], "TOKEN_NOT_ALLOWED");
        require(spenders[spender].status, "INVALID_SPENDER");
        require(amount > 0, "ZERO_AMOUNT");
        require(amount <= spenders[spender].maxLimit, "AMOUNT_EXCEEDS_SPENDER_LIMIT");
        require(spenders[msg.sender].status, "Sender is not an active spender");
        require(IERC20(token).balanceOf(address(this)) >= amount, "INSUFFICIENT_BALANCE");
        IERC20(token).forceApprove(spender, amount);

        emit VaultSpendApproved(token, spender, amount);
    }

    // ─── Views: Approvers ─────────────────────────────────────────────────────


    function approverCount() external view returns (uint256) {
        return _approverList.length;
    }

    function _changeTimelock(bytes32 refNo) internal {
        ActionRequest storage action = actions[refNo];

        ActionType targetAction = ActionType(action.intValue);
        uint256 newDelay = action.intValue2;

        require(newDelay <= 7 days, "TIMELOCK_TOO_LONG");
        require(newDelay >= 1 hours, "TIMELOCK_TOO_SHORT");
        require(uint256(action.intValue) <= uint256(ActionType.CHANGE_TIMELOCK), "INVALID_ACTION_TYPE");

        actionTimelock[targetAction] = newDelay;

        emit TimelockChanged(targetAction, newDelay);
    }

    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner whenNotPaused nonReentrant {
        require(to != address(0), "ZERO_ADDRESS");
        require(spenders[to].status, "TO_ADDRESS_NOT_SPENDER");
        // optional safety: prevent draining approved treasury assets
        require(!allowedTokens[token], "CANNOT_RESCUE_ALLOWED_TOKEN");
        
        if(token == address(0)) {
            uint256 ethBalance = address(this).balance;
            require(ethBalance >= amount, "INSUFFICIENT_ETH_BALANCE");
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH_TRANSFER_FAILED");
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            require(balance >= amount, "INSUFFICIENT_BALANCE");
            IERC20(token).safeTransfer(to, amount);
            emit UnsupportedTokenRescued(token, to, amount);
        }
    }

    function getChainId() public view returns (uint256) {
        return block.chainid;
    }

    function getNextSpendNonce(address addr)
        external view returns (uint256 _nonce)
    {
        return (
            spendNonces[addr]
        );
    }

    function getNextApprovalNonce(address addr)
        external view returns (uint256 _nonce)
    {
        return (
            approvalNonces[addr]
        );
    }

    function getSpendWallet(address spender)
        external
        view
        returns (
            address token,
            uint256 maxLimit,
            uint256 _dailyLimit,
            uint256 monthlyLimit,
            bool status,
            uint256 dayNumber,
            uint256 monthNumber,
            uint256 dailySpent,
            uint256 monthlySpent,
            uint256 lastTxTimestamp,
            uint256 totalSpent
        )
    {
        require(spender != address(0), "ZERO_ADDRESS");
        require(spenders[spender].token != address(0), "SPENDER_NOT_FOUND");
        SpendWallet storage s = spenders[spender];

        return (
            s.token,
            s.maxLimit,
            s.dailyLimit,
            s.monthlyLimit,
            s.status,
            s.dayNumber,
            s.monthNumber,
            s.dailySpent,
            s.monthlySpent,
            s.lastTxTimestamp,
            s.totalSpent
        );
    }

    function getTransactionLog(bytes32 refNo)
        external
        view
        returns (
            address sender,
            address token,
            address beneficiary,
            uint256 amount,
            uint256 createdAt,
            bytes32 _refNo,
            TransactionType tranType
        )
    {
        require(refNo != bytes32(0), "INVALID_REF");

        TransactionLog storage t = transactionsByRef[refNo];
        require(t.sender != address(0), "TX_NOT_FOUND");

        return (
            t.sender,
            t.token,
            t.beneficiary,
            t.amount,
            t.createdAt,
            t.refNo,
            t.tranType
        );
    }

    function getApprover(address approver)
        external
        view
        returns (
            uint256 amount,
            bool status
        )
    {
        require(approver != address(0), "ZERO_ADDRESS");
        require(approvers[approver].amount != 0 || approvers[approver].status, "APPROVER_NOT_FOUND");

        Approver storage a = approvers[approver];

        return (
            a.amount,
            a.status
        );
    }

    function getTempLog(bytes32 refNo)
        external
        view
        returns (
            address sender,
            address token,
            address beneficiary,
            uint256 amount,
            bytes32 _refNo,
            TransactionType tranType,
            uint256 amount2,
            uint256 amount3
        )
    {
        require(refNo != bytes32(0), "INVALID_REF");

        TempLog storage t = tempLogByRef[refNo];
        require(t.sender != address(0), "TEMPLOG_NOT_FOUND");

        return (
            t.sender,
            t.token,
            t.beneficiary,
            t.amount,
            t.refNo,
            t.tranType,
            t.amount2,
            t.amount3
        );
    }

   
}
