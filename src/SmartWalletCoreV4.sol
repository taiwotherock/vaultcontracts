// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SmartWalletCoreV4 is EIP712, ReentrancyGuard {

    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MAX_DAILY_LIMIT       = 10_000_000 * 1e18;
    uint256 public constant MAX_TX_AMOUNT         = 1_000_000  * 1e18;
    uint256 public constant MAX_GUARDIANS         = 10;
    uint256 public constant MAX_STAFF             = 20;
    uint256 public constant MIN_SESSION_DURATION  = 1  minutes;
    uint256 public constant MAX_SESSION_DURATION  = 30 days;

    // ─── Enums ────────────────────────────────────────────────────────────────
    enum ActionType {
        ADD_GUARDIAN,    // 0
        REMOVE_GUARDIAN, // 1
        ADD_STAFF,       // 2
        REMOVE_STAFF,    // 3
        INCREASE_LIMIT,  // 4
        CHANGE_OWNER     // 5
    }

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct ActionRequest {
        ActionType actionType;
        address maker;
        address addressValue;
        uint256 intValue;
        uint256 createdAt;
        uint256 executeAfter;
        uint256 expiry;
        bool executed;
    }

    struct DepositTransaction {
        address sender;
        address token;
        uint256 amount;
        uint256 createdAt;
        bytes32 refNo;
    }

    // ─── State ────────────────────────────────────────────────────────────────
    address public owner;
    address public systemAdmin;

    mapping(address => bool)    public guardians;
    address[]                   public guardianList;
    mapping(address => bool)    public staffs;
    address[]                   public staffList;

    mapping(bytes32 => DepositTransaction) private depositsByRef;
    mapping(address => bytes32[])          private senderRefs;

    mapping(address => bool)    public whitelisted;

    // Session management — replaces global nonces
    mapping(uint256 => mapping(address => uint256)) public sessionNonces;
    mapping(uint256 => uint256) public sessionExpiry;
    mapping(uint256 => bool)    public sessionClosed;
    mapping(uint256 => address) public sessionCreator;
    uint256 public nextSessionId = 1;

    uint256 public dailyLimit;
    mapping(uint256 => uint256)   public dailyTransferred;
    mapping(ActionType => uint256) public actionTimelock;
    uint256 public actionCount;
    mapping(uint256 => ActionRequest) public actions;

    uint256 public maxTxAmount;
    bool    public paused;

    // ─── EIP-712 ──────────────────────────────────────────────────────────────
    bytes32 public constant TRANSFER_TYPEHASH = keccak256(
        "Transfer(address token,address walletAddress,address to,uint256 amount,"
        "uint256 nonce,uint256 deadline,uint256 sessionId,string paymentId)"
    );

    // ─── Events ───────────────────────────────────────────────────────────────
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, uint256 sessionId, string paymentId);
    event PaymentExecuted(address indexed token, address indexed to, address indexed signer, uint256 amount, uint256 sessionId, string paymentId);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event UserAdded(address indexed user);
    event UserRemoved(address indexed user);
    event WhitelistUpdated(address indexed account, bool status);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event ActionProposed(uint256 indexed id, ActionType action, address indexed maker);
    event ActionApproved(uint256 indexed id, address indexed guardian);
    event ActionExecuted(uint256 indexed id, ActionType action);
    event ActionCancelled(uint256 indexed id);
    event Deposited(address indexed sender, address indexed token, uint256 amount, bytes32 refNo);
    event SystemAdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event DailyLimitChanged(uint256 oldLimit, uint256 newLimit);
    event MaxTxAmountChanged(uint256 oldAmount, uint256 newAmount);
    event SessionCreated(uint256 indexed sessionId, address indexed creator, uint256 expiry);
    event SessionClosed(uint256 indexed sessionId, address indexed closedBy);

    // ─── Errors ───────────────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error OutOfRange();
    error SessionExpired();
    error SessionNotFound();
    error InvalidNonce();

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyGuardian() {
        require(guardians[msg.sender], "NOT_GUARDIAN");
        _;
    }

    modifier onlyGuardianOrStaff() {
        require(guardians[msg.sender] || staffs[msg.sender], "NOT_GUARDIAN_OR_STAFF");
        _;
    }

    modifier onlyPowerUser() {
        require(
            guardians[msg.sender] || staffs[msg.sender] ||
            msg.sender == owner   || msg.sender == systemAdmin,
            "NOT_POWER_USER"
        );
        _;
    }

    modifier onlyStaffOrOwner() {
        require(msg.sender == owner || staffs[msg.sender], "NOT_STAFF_OR_OWNER");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _owner,
        uint256 _dailyLimit,
        uint256 _maxTxAmount,
        address _guardian
    ) EIP712("SmartWalletCoreV4", "1") {
        require(_owner     != address(0),          "ZERO_OWNER");
        require(_dailyLimit > 0,                   "ZERO_DAILY_LIMIT");
        require(_maxTxAmount > 0,                  "ZERO_MAX_TX");
        require(_maxTxAmount <= _dailyLimit,        "MAX_TX_EXCEEDS_DAILY");
        require(_dailyLimit  <= MAX_DAILY_LIMIT,    "DAILY_LIMIT_TOO_HIGH");
        require(_maxTxAmount <= MAX_TX_AMOUNT,      "MAX_TX_TOO_HIGH");

        owner       = _owner;
        systemAdmin = msg.sender;
        dailyLimit  = _dailyLimit;
        maxTxAmount = _maxTxAmount;

        // Default timelocks
        actionTimelock[ActionType.CHANGE_OWNER]    = 2 days;
        actionTimelock[ActionType.ADD_GUARDIAN]    = 1 days;
        actionTimelock[ActionType.REMOVE_GUARDIAN] = 1 days;
        actionTimelock[ActionType.ADD_STAFF]       = 12 hours;
        actionTimelock[ActionType.REMOVE_STAFF]    = 6 hours;
        actionTimelock[ActionType.INCREASE_LIMIT]  = 1 days;

        _addGuardian(_guardian);
    }

    // ─── Guardian / Staff Management ──────────────────────────────────────────
    function _addGuardian(address user) internal {
        require(user != address(0),  "ZERO_ADDRESS");
        require(!staffs[user],       "ALREADY_STAFF");
        require(!guardians[user],    "ALREADY_GUARDIAN");
        require(guardianList.length < MAX_GUARDIANS, "MAX_GUARDIANS_REACHED");
        guardians[user] = true;
        guardianList.push(user);
        emit UserAdded(user);
    }

    function addNewStaff(address staff) external onlyOwner nonReentrant {
        _addStaff(staff);
    }

    function _addStaff(address user) internal {
        require(user != address(0),  "ZERO_ADDRESS");
        require(!guardians[user],    "ALREADY_GUARDIAN");
        require(!staffs[user],       "ALREADY_STAFF");
        require(staffList.length < MAX_STAFF, "MAX_STAFF_REACHED");
        staffs[user] = true;
        staffList.push(user);
        emit UserAdded(user);
    }

    function _removeUser(address user) internal {
        if (staffs[user]) {
            staffs[user] = false;
            for (uint i = 0; i < staffList.length; i++) {
                if (staffList[i] == user) {
                    staffList[i] = staffList[staffList.length - 1];
                    staffList.pop();
                    break;
                }
            }
            emit UserRemoved(user);
        } else if (guardians[user]) {
            guardians[user] = false;
            for (uint i = 0; i < guardianList.length; i++) {
                if (guardianList[i] == user) {
                    guardianList[i] = guardianList[guardianList.length - 1];
                    guardianList.pop();
                    break;
                }
            }
            emit UserRemoved(user);
        }
    }

    function removeUser(address user) external onlyOwner {
        _removeUser(user);
    }

    function changeOwner(address newOwner) internal {
        require(newOwner != address(0), "ZERO_ADDRESS");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    // ─── Pause ────────────────────────────────────────────────────────────────
    function pause() external {
        require(msg.sender == owner || msg.sender == systemAdmin, "NOT_AUTHORIZED");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    function setWhitelist(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function setDailyLimit(uint256 _dailyLimit) external onlyOwner {
        require(_dailyLimit > 0 && _dailyLimit <= MAX_DAILY_LIMIT, "OUT_OF_RANGE");
        emit DailyLimitChanged(dailyLimit, _dailyLimit);
        dailyLimit = _dailyLimit;
    }

    function setMaxTxAmount(uint256 _maxTxAmount) external onlyOwner {
        require(_maxTxAmount > 0 && _maxTxAmount <= MAX_TX_AMOUNT, "OUT_OF_RANGE");
        emit MaxTxAmountChanged(maxTxAmount, _maxTxAmount);
        maxTxAmount = _maxTxAmount;
    }

    function transferSystemAdmin(address newAdmin) external {
        require(msg.sender == systemAdmin, "NOT_SYSTEM_ADMIN");
        require(newAdmin != address(0),    "ZERO_ADDRESS");
        emit SystemAdminTransferred(systemAdmin, newAdmin);
        systemAdmin = newAdmin;
    }

    function setActionTimelock(ActionType actionType, uint256 delay) external onlyOwner {
        require(delay >= 1 hours, "TIMELOCK_TOO_SHORT");
        actionTimelock[actionType] = delay;
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────
    function deposit(
        address token,
        bytes32 refNo,
        uint256 amount
    ) external payable whenNotPaused nonReentrant {
        require(depositsByRef[refNo].sender == address(0), "REF_EXISTS");

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
        }

        depositsByRef[refNo] = DepositTransaction({
            sender:    msg.sender,
            token:     token,
            amount:    actualAmount,
            createdAt: block.timestamp,
            refNo:     refNo
        });
        senderRefs[msg.sender].push(refNo);
        emit Deposited(msg.sender, token, actualAmount, refNo);
    }

    receive() external payable {
        require(msg.value > 0, "ZERO_ETH");
        bytes32 autoRef = keccak256(abi.encodePacked(msg.sender, block.timestamp, msg.value));
        depositsByRef[autoRef] = DepositTransaction({
            sender:    msg.sender,
            token:     address(0),
            amount:    msg.value,
            createdAt: block.timestamp,
            refNo:     autoRef
        });
        senderRefs[msg.sender].push(autoRef);
        emit Deposited(msg.sender, address(0), msg.value, autoRef);
    }

    // ─── Session Management ───────────────────────────────────────────────────
    function createSession(uint256 durationSeconds) external onlyStaffOrOwner returns (uint256) {
        require(
            durationSeconds >= MIN_SESSION_DURATION &&
            durationSeconds <= MAX_SESSION_DURATION,
            "INVALID_DURATION"
        );
        uint256 sessionId        = nextSessionId++;
        sessionExpiry[sessionId] = block.timestamp + durationSeconds;
        sessionCreator[sessionId] = msg.sender;
        emit SessionCreated(sessionId, msg.sender, sessionExpiry[sessionId]);
        return sessionId;
    }

    function closeSession(uint256 sessionId) external {
        require(
            msg.sender == sessionCreator[sessionId] ||
            msg.sender == owner ||
            msg.sender == systemAdmin,
            "NOT_AUTHORIZED"
        );
        require(!sessionClosed[sessionId], "ALREADY_CLOSED");
        sessionClosed[sessionId] = true;
        emit SessionClosed(sessionId, msg.sender);
    }

    // ─── Signature Validation ─────────────────────────────────────────────────
    function _validateSignature(
        address token,
        address walletAddress,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 sessionId,
        string memory paymentId,
        bytes memory signature
    ) internal returns (address signer) {

        // Time
        require(block.timestamp <= deadline,                "EXPIRED");

        // Session
        require(sessionId > 0,                             "INVALID_SESSION");
        require(sessionExpiry[sessionId] > 0,              "SESSION_NOT_FOUND");
        require(!sessionClosed[sessionId],                 "SESSION_CLOSED");
        require(block.timestamp <= sessionExpiry[sessionId],"SESSION_EXPIRED");

        // Amount
        require(amount > 0,                                "ZERO_AMOUNT");
        require(amount <= maxTxAmount,                     "TX_AMOUNT_EXCEEDS_LIMIT");

        // Wallet
        require(walletAddress != address(0),               "ZERO_WALLET");

        // EIP-712
        bytes32 paymentIdHash = keccak256(bytes(paymentId));
        bytes32 structHash = keccak256(abi.encode(
            TRANSFER_TYPEHASH,
            token,
            walletAddress,
            to,
            amount,
            nonce,
            deadline,
            sessionId,
            paymentIdHash
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        signer = ECDSA.recover(digest, signature);

        require(signer != address(0),    "ZERO_SIGNER");
        require(signer == walletAddress, "INVALID_SIGNER");

        // Session-scoped nonce
        require(nonce == sessionNonces[sessionId][signer]++, "INVALID_NONCE");
    }

    // ─── Execute Payment (pull INTO contract) ────────────────────────────────
    function executePayment(
        address token,
        address walletAddress,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 sessionId,
        string memory paymentId,
        bytes memory signature
    ) external payable whenNotPaused nonReentrant {

        address signer = _validateSignature(
            token, walletAddress, to, amount, nonce, deadline, sessionId, paymentId, signature
        );

        require(to == address(this), "NOT_CONTRACT_ADDRESS");
        require(
            staffs[msg.sender]    ||
            msg.sender == owner   ||
            msg.sender == systemAdmin ||
            msg.sender == walletAddress,
            "NOT_AUTHORIZED"
        );

        if (token == address(0)) {
            require(msg.value == amount, "ETH_AMOUNT_MISMATCH");
        } else {
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(walletAddress, address(this), amount);
            uint256 actualReceived = IERC20(token).balanceOf(address(this)) - before;
            require(actualReceived > 0, "ZERO_RECEIVED");
        }

        emit PaymentExecuted(token, to, signer, amount, sessionId, paymentId);
    }

    // ─── Execute Transfer (push OUT of contract) ──────────────────────────────
    function executeTransfer(
        address token,
        address walletAddress,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 sessionId,
        string memory paymentId,
        bytes memory signature
    ) external whenNotPaused nonReentrant {

        _validateSignature(
            token, walletAddress, to, amount, nonce, deadline, sessionId, paymentId, signature
        );

        require(whitelisted[to],                              "NOT_WHITELISTED");
        require(staffs[msg.sender] || msg.sender == owner,    "NOT_AUTHORIZED");

        // Daily limit
        uint256 dayNumber = block.timestamp / 1 days;
        require(
            dailyTransferred[dayNumber] + amount <= dailyLimit,
            "DAILY_LIMIT_EXCEEDED"
        );
        dailyTransferred[dayNumber] += amount;

        if (token == address(0)) {
            require(address(this).balance >= amount, "INSUFFICIENT_ETH_BALANCE");
            (bool sent, ) = payable(to).call{value: amount}("");
            require(sent, "ETH_TRANSFER_FAILED");
        } else {
            require(IERC20(token).balanceOf(address(this)) >= amount, "INSUFFICIENT_TOKEN_BALANCE");
            IERC20(token).safeTransfer(to, amount);
        }

        emit TransferExecuted(token, to, amount, sessionId, paymentId);
    }

    // ─── Actions ──────────────────────────────────────────────────────────────
    function proposeAction(
        ActionType actionType,
        address addressValue,
        uint256 intValue,
        uint256 expiry
    ) external onlyGuardianOrStaff nonReentrant returns (uint256) {

        require(expiry > block.timestamp, "INVALID_EXPIRY");
        require(addressValue != address(0), "ZERO_ADDRESS");

        // Only guardians can propose sensitive actions
        if (
            actionType == ActionType.CHANGE_OWNER    ||
            actionType == ActionType.ADD_GUARDIAN    ||
            actionType == ActionType.REMOVE_GUARDIAN
        ) {
            require(guardians[msg.sender], "GUARDIAN_ONLY_ACTION");
        }

        uint256 id = actionCount++;
        actions[id] = ActionRequest({
            actionType:   actionType,
            maker:        msg.sender,
            addressValue: addressValue,
            intValue:     intValue,
            createdAt:    block.timestamp,
            executeAfter: block.timestamp + actionTimelock[actionType],
            expiry:       expiry,
            executed:     false
        });
        emit ActionProposed(id, actionType, msg.sender);
        return id;
    }

    function executeAction(uint256 actionId) external nonReentrant onlyPowerUser {
        ActionRequest storage action = actions[actionId];

        require(!action.executed,                          "EXECUTED");
        require(block.timestamp >= action.executeAfter,    "TIMELOCK_ACTIVE");
        require(block.timestamp <= action.expiry,          "EXPIRED");
        require(action.maker != msg.sender,                "MAKER_CANNOT_EXECUTE");

        action.executed = true;

        if (action.actionType == ActionType.ADD_GUARDIAN) {
            require(msg.sender == owner, "ONLY_OWNER");
            _addGuardian(action.addressValue);

        } else if (
            action.actionType == ActionType.REMOVE_GUARDIAN ||
            action.actionType == ActionType.REMOVE_STAFF
        ) {
            _removeUser(action.addressValue);

        } else if (action.actionType == ActionType.ADD_STAFF) {
            require(msg.sender == owner, "ONLY_OWNER");
            _addStaff(action.addressValue);

        } else if (action.actionType == ActionType.CHANGE_OWNER) {
            require(
                msg.sender == systemAdmin || guardians[msg.sender],
                "GUARDIAN_OR_ADMIN_ONLY"
            );
            changeOwner(action.addressValue);

        } else if (action.actionType == ActionType.INCREASE_LIMIT) {
            require(msg.sender == owner, "ONLY_OWNER");
            require(action.intValue > 0 && action.intValue <= MAX_DAILY_LIMIT, "OUT_OF_RANGE");
            emit DailyLimitChanged(dailyLimit, action.intValue);
            dailyLimit = action.intValue;

        } else {
            revert("INVALID_ACTION");
        }

        emit ActionExecuted(actionId, action.actionType);
    }

    function cancelAction(uint256 actionId) external nonReentrant {
        ActionRequest storage action = actions[actionId];
        require(!action.executed, "ALREADY_EXECUTED");
        require(
            msg.sender == action.maker ||
            msg.sender == owner        ||
            msg.sender == systemAdmin,
            "NOT_AUTHORIZED"
        );
        action.executed = true;
        emit ActionCancelled(actionId);
    }

    // ─── View Functions ───────────────────────────────────────────────────────
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function getLimitsAndSessionNonce(uint256 sessionId)
        external
        view
        onlyStaffOrOwner
        returns (
            uint256 _dailyLimit,
            uint256 _maxTxAmount,
            uint256 _sessionNonce,
            uint256 _sessionExpiry,
            bool    _sessionClosed
        )
    {
        return (
            dailyLimit,
            maxTxAmount,
            sessionNonces[sessionId][msg.sender],
            sessionExpiry[sessionId],
            sessionClosed[sessionId]
        );
    }

    function getSessionNonce(uint256 sessionId, address user) external view returns (uint256) {
        return sessionNonces[sessionId][user];
    }

    function isGuardianAddress(address user) external view returns (bool) {
        return guardians[user];
    }

    function isStaffAddress(address user) external view returns (bool) {
        return staffs[user];
    }

    function isWhitelistedAddress(address user) external view returns (bool) {
        return whitelisted[user];
    }

    function getAction(uint256 actionId) external view returns (
        ActionType actionType,
        address    maker,
        address    addressValue,
        uint256    intValue,
        uint256    createdAt,
        uint256    executeAfter,
        uint256    expiry,
        bool       executed
    ) {
        ActionRequest storage a = actions[actionId];
        return (
            a.actionType, a.maker, a.addressValue, a.intValue,
            a.createdAt, a.executeAfter, a.expiry, a.executed
        );
    }

    function getAllGuardians() external view onlyStaffOrOwner returns (address[] memory) {
        return guardianList;
    }

    function getAllStaff() external view onlyStaffOrOwner returns (address[] memory) {
        return staffList;
    }

    function getDepositByRef(bytes32 refNo) external view returns (DepositTransaction memory) {
        require(depositsByRef[refNo].sender != address(0), "NOT_FOUND");
        return depositsByRef[refNo];
    }

    function getSenderRefs(address sender) external view onlyStaffOrOwner returns (bytes32[] memory) {
        return senderRefs[sender];
    }
}