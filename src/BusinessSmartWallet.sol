// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract BusinessSmartWallet is Initializable, EIP712, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    enum ActionType {
        SPEND,
        CHANGE_LIMIT,
        CHANGE_OWNER,
        CHANGE_APPROVER,
        ADD_APPROVER,
        ADD_SPEND_WALLET,
        CHANGE_SPENDER_LIMIT,
        CHANGE_AUTO_APPROVE_LIMIT,
        ENABLE_SPEND_WALLET,
        ENABLE_APPROVER
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
        NON_SPEND
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
        uint256 approvalCount;
    }

    struct Approver {
        uint256 amount;
        bool status;
        UserRole role;
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

    mapping(bytes32 => bool) public paymentIdUsed;
    mapping(bytes32 => TransactionLog) public transactionsByRef;
    mapping(bytes32 => TempLog) public tempLogByRef;
    mapping(bytes32 => ActionRequest) public actions;
    mapping(address => bytes32[]) public senderRefs;
    mapping(address => uint256) public nonces;
    mapping(address => bool) public allowedTokens;
    mapping(address => SpendWallet) public spenders;
    mapping(address => Approver) public approvers;
    mapping(address => mapping(bytes32 => bool)) public approvals;
    mapping(uint256 => uint256) public dailyTransferred;
    mapping(ActionType => uint256) public actionTimelock;

    // alongside existing mappings
    address[] private _approverList;
    
    address[] private _spenderList;
    mapping(address => uint256) private _spenderIdx;     // 1-based


    bytes32[] private _pendingTempRefs;                  // pending temp logs
    mapping(bytes32 => uint256) private _pendingTempIdx; // 1-based

    bytes32[] private _actionRefs;                       // all actions ever proposed
    mapping(bytes32 => uint256) private _actionIdx;      // 1-based

    bytes32 public constant TRANSFER_TYPEHASH = keccak256(
        "Transfer(address token,address walletAddress,address to,uint256 amount,uint256 nonce,uint256 deadline,string paymentId)"
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

    constructor() EIP712("BusinessSmartWallet", "1") {}

    function initialize(
        address _owner,
        address _relayer,
        uint256 _dailyLimit,
        uint256 _maxTxAmount,
        uint256 _approvalThreshold,
        uint256 _noOfApprovals
    ) external initializer {
        require(_owner != address(0), "INVALID_OWNER");
        require(_relayer != address(0), "INVALID_RELAYER");

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

        emit Initialized(_owner, _relayer);
    }

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

    function setActionTimelock(ActionType actionType, uint256 delay) external onlyOwner {
        require(delay >= 1 hours, "TIMELOCK_TOO_SHORT");
        actionTimelock[actionType] = delay;
        emit TimelockChanged(actionType, delay);
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
            lastTxTimestamp: 0
        });

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

    function addApprover(address approver, uint256 amount, UserRole role) external onlyOwner {
        require(approver != address(0), "ZERO_APPROVER");

        approvers[approver] = Approver({
            amount: amount,
            status: true,
            role: role
        });
    }

    function disableApprover(address approver) external onlyOwner {
        approvers[approver].status = false;
        emit DisabledApprover(approver);
    }

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

    function autoSpend(
        bytes32 refNo,
        uint256 amount,
        address token,
        TransactionType tranType
    ) external nonReentrant whenNotPaused {
        require(transactionsByRef[refNo].sender == address(0), "REF_EXISTS");

        SpendWallet storage spender = spenders[msg.sender];

        require(spender.status, "SPENDER_DISABLED");
        require(spender.token == token, "INVALID_TOKEN");
        require(amount <= spender.maxLimit, "MAX_LIMIT_EXCEEDED");

        _enforceCooldown(spender);
        _enforceGlobalDailySpendLimit(amount);
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

        senderRefs[msg.sender].push(refNo);

        uint256 dayNumber = block.timestamp / 1 days;
        dailyTransferred[dayNumber] += amount;

        spender.dailySpent += amount;
        spender.monthlySpent += amount;
        spender.lastTxTimestamp = block.timestamp;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit AutoSpent(msg.sender, token, refNo, amount, tranType);
    }

    function initiateSpend(
        address token,
        uint256 amount,
        address beneficiary,
        bytes32 refNo,
        TransactionType tranType
    ) external onlyPowerUser whenNotPaused nonReentrant {
        require(actions[refNo].maker == address(0), "ACTION_EXISTS");
        require(spenders[beneficiary].status, "INVALID_SPENDER");

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
            approvalCount: 0
        });

        emit ActionProposed(refNo, ActionType.SPEND, msg.sender, executeAfter, beneficiary, amount);
    }

    function proposeAction( ActionType actionType, address addressValue, bytes32 refNo, uint256 intValue, uint256 expiry ) external onlyPowerUser whenNotPause nonReentrant { require(expiry > block.timestamp, "INVALID_EXPIRY"); require(addressValue != address(0), "ZERO_ADDRESS"); actionCount++; if(actionType == ActionType.ADD_APPROVER) { require(!approvers[addressValue].status, "Already an approver"); } else if(actionType == ActionType.CHANGE_APPROVER) { require(!approvers[addressValue].status, "Already an approver"); } actions[refNo] = ActionRequest({ actionType: actionType, maker: msg.sender, refNo: refNo, createdAt: block.timestamp, executeAfter: expiry, executed: false, addressValue: beneficiary, intValue: intValue, approvalCount: 0 }); emit ActionProposed(refNo, ActionType.SPEND, msg.sender,expiry,addressValue, intValue); }

    function approveAction(bytes32 refNo) external onlyApprover whenNotPaused {
        ActionRequest storage action = actions[refNo];

        require(action.maker != address(0), "INVALID_ACTION");
        require(!action.executed, "ALREADY_EXECUTED");
        require(!approvals[msg.sender][refNo], "ALREADY_APPROVED");
        require(action.maker != msg.sender, "MAKER_CANNOT_APPROVE");

        approvals[msg.sender][refNo] = true;
        action.approvalCount += 1;

        emit ActionApproved(refNo, msg.sender, action.approvalCount);
    }

    function executeAction(bytes32 refNo) external whenNotPause nonReentrant { ActionType storage action = actions[refNo]; require(action.maker != address(0), "Invalid Ref No"); require(action.expiry > block.timestamp, "INVALID_EXPIRY"); require(!approvals[msg.sender][refNo], "Already approved"); require(!action.executed, "EXECUTED"); require(block.timestamp >= action.executeAfter, "TIMELOCK_ACTIVE"); require(block.timestamp <= action.expiry, "EXPIRED"); require(action.maker != msg.sender, "MAKER_CANNOT_EXECUTE"); require(action.approvalCount >= APPROVAL_THRESHOLD, "Approval Threshold not reached"); require(msg.sender == relayer || approvers[msg.sender].status, "Not allowed approver or owner"); action.executed = true; if (action.actionType == ActionType.SPEND) { TempLog storage tempLog = tempLogByRef[refNo]; _spend(tempLog.token, tempLog.amount, tempLog.beneficiary,tempLog.refNo, tempLog.tranType); } else if (action.actionType == ActionType.ADD_SPEND_WALLET ) { _addSpendWallet(refNo); } else if (action.actionType == ActionType.ADD_APPROVER ) { _addApprover(refNo); } else if (action.actionType == ActionType.CHANGE_APPROVER ) { _changeApprover(refNo); } else if (action.actionType == ActionType.CHANGE_SPENDER_LIMIT ) { _changeSpendWallet(refNo); } else if (action.actionType == ActionType.ENABLE_SPEND_WALLET ) { _changeSpendWallet(action.addressValue,true); } else if (action.actionType == ActionType.ENABLE_APPROVER ) { _changeApproverStatus(action.addressValue,true); } else { revert("INVALID_ACTION"); } emit ActionExecuted(actionId, action.actionType); }

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

        _enforceGlobalDailySpendLimit(amount);
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

        IERC20(token).safeTransfer(beneficiary, amount);

        emit Spent(msg.sender, token, beneficiary, amount, refNo, tranType);
    }

    function cancelAction(bytes32 refNo) external {
        ActionRequest storage action = actions[refNo];

        require(!action.executed, "ALREADY_EXECUTED");
        require(msg.sender == action.maker || msg.sender == owner, "NOT_AUTHORIZED");

        action.executed = true;

        emit ActionCancelled(refNo);
    }

    function changeOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_OWNER");

        emit OwnerChanged(owner, newOwner);

        owner = newOwner;
    }

    function addSpendWallet(bytes32 refNo, address spender, address token, uint256 maxLimit, uint256 monthlyLimit, uint256 dailyLimit) external whenNotPause nonReentrant onlyOwner { require(spender != address(0), "zero address"); require(token != address(0), "Token zero address"); require(spenders[spender].token == address(0), "existing spender"); require(transactionsByRef[refNo].sender == address(0), "REF_EXISTS"); require(tempLogByRef[refNo].sender == address(0), "REF_EXISTS"); require(actions[refNo].maker == address(0), "REF_EXISTS"); require(allowedTokens[token], "TOKEN_NOT_ALLOWED"); tempLogByRef[refNo] = TempLog({ sender: msg.sender, token: token, beneficiary: spender, amount: maxLimit, refNo: refNo, tranType: tranType, amount2: dailyLimit, amount3: monthlyLimit }); actions[refNo] = ActionRequest({ actionType: ActionType.ADD_SPEND_WALLET, maker: msg.sender, refNo: refNo, createdAt: block.timestamp, executeAfter: expiry, executed: false, addressValue: spender, intValue: maxLimit, approvalCount: 0 }); emit ActionProposed(refNo, ActionType.ADD_SPEND_WALLET, msg.sender,expiry,spender, maxLimit); } function changeSpenderLimit(bytes32 refNo, address spender, address token, uint256 maxLimit, uint256 monthlyLimit, uint256 dailyLimit) external whenNotPause nonReentrant onlyOwner { require(spender != address(0), "zero address"); require(token != address(0), "Token zero address"); require(spenders[spender].token != address(0), "not existing spender"); require(transactionsByRef[refNo].sender == address(0), "REF_EXISTS"); require(tempLogByRef[refNo].sender == address(0), "REF_EXISTS"); require(actions[refNo].maker == address(0), "REF_EXISTS"); require(allowedTokens[token], "TOKEN_NOT_ALLOWED"); tempLogByRef[refNo] = TempLog({ sender: msg.sender, token: token, beneficiary: spender, amount: maxLimit, refNo: refNo, tranType: tranType, amount2: dailyLimit, amount3: monthlyLimit }); actions[refNo] = ActionRequest({ actionType: ActionType.CHANGE_SPENDER_LIMIT, maker: msg.sender, refNo: refNo, createdAt: block.timestamp, executeAfter: expiry, executed: false, addressValue: spender, intValue: maxLimit, approvalCount: 0 }); emit ActionProposed(refNo, ActionType.CHANGE_SPENDER_LIMIT, msg.sender,expiry,spender, maxLimit); } function _addSpendWallet(bytes32 refNo) internal { TempLog storage templog = tempLogByRef[refNo]; spenders[templog.beneficiary] = SpendWallet({ token: templog.token, maxLimit: templog.amount, dailyLimit: templog.amount2, monthlyLimit:templog.amount3, status: true, dayNumber: 0, dailySpent: 0, monthlySpent: 0)}; SpendWallet storage spender = spenders[templog.beneficiary]; delete templog; emit ChangedSpendWalletLimit(refNo, spender.beneficiary, spender.maxLimit,spender.dailyLimit,spender.monthlyLimit); } function _changeSpendWallet(bytes32 refNo) internal { TempLog storage templog = tempLogByRef[refNo]; SpendWallet storage spender = spenders[templog.beneficiary]; spender.maxLimit = templog.amount; spender.dailyLimit = templog.amount2; spender.monthlyLimit = templog.amount3; delete templog; emit ChangedSpendWalletLimit(refNo, spender.beneficiary, spender.maxLimit,spender.dailyLimit,spender.monthlyLimit); } function _addApprover(bytes32 refNo) { ActionRequest storage action = actions[refNo]; approvers[action.addressValue] = Approver({ amount: action.intValue, status: true }); } function _changeApprover(bytes32 refNo) { ActionRequest storage action = actions[refNo]; approvers[action.addressValue] = Approver({ amount: action.intValue, status: true }); if(action.intValue == 0) approvers[action.addressValue].status = false; }

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
        require(block.timestamp <= deadline, "EXPIRED");
        require(walletAddress != address(0), "INVALID_WALLET");
        require(amount > 0, "ZERO_AMOUNT");
        require(nonce == nonces[walletAddress], "INVALID_NONCE");

        bytes32 paymentHash = keccak256(bytes(paymentId));

        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_TYPEHASH,
                token,
                walletAddress,
                to,
                amount,
                nonce,
                deadline,
                paymentHash
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);

        signer = ECDSA.recover(digest, signature);

        require(signer == walletAddress, "INVALID_SIGNER");
    }

    function approveVaultSpend(
        address token,
        address spender,
        uint256 amount
    ) external onlyOwner {
        require(allowedTokens[token], "TOKEN_NOT_ALLOWED");
        require(spender != address(0), "ZERO_SPENDER");
        require(spenders[spender].status, "INVALID_SPENDER");
        IERC20(token).approve(spender, amount);
        emit VaultSpendApproved(token, spender, amount);
    }

    // ─── C1. Approvers ────────────────────────────────────────────────────────

    /// @notice Total number of approvers ever added (including inactive).
    function approverCount() external view returns (uint256) {
        return _approverList.length;
    }

    /// @notice Paginated list of approver addresses.
    /// @param activeOnly  If true, skip addresses whose status is false.
    function getApprovers(
        bool    activeOnly,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory list, uint256 total) {

        total = _approverList.length;
        if (offset >= total) return (new address[](0), total);

        uint256 available = total - offset;
        uint256 size      = (limit == 0 || limit > available) ? available : limit;

        // Pre-scan to find real count when filtering
        uint256 count;
        for (uint256 i = offset; i < total; i++) {
            if (!activeOnly || approvers[_approverList[i]].status) count++;
            if (count == size) break;
        }

        list = new address[](count);
        uint256 j;
        for (uint256 i = offset; i < total && j < count; i++) {
            address addr = _approverList[i];
            if (!activeOnly || approvers[addr].status) {
                list[j++] = addr;
            }
        }
    }

    
}
