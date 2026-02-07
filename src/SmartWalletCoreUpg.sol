// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";


contract SmartWalletCoreUpg is Initializable, EIP712, ReentrancyGuard {

    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    enum ActionType {
        ADD_GUARDIAN, // 0
        REMOVE_GUARDIAN, // 1
        ADD_STAFF, // 2
        REMOVE_STAFF, // 3
        INCREASE_LIMIT, // 4
        CHANGE_OWNER // 5
    }

    enum Role
    {
        GUARDIAN,
        STAFF
    }

    struct ActionRequest {
        ActionType actionType;
        address maker;
        address addressValue;
        uint256 intValue;
        uint256 createdAt;
        uint256 executeAfter; // timelock
        uint256 expiry;
        bool executed;
    }

    // Wallet owner
    address public owner;
    address public systemAdmin;

    // Guardian addresses can recover/change owner
    mapping(address => bool) public guardians;
    address[] public guardianList;
    mapping(address => bool) public staffs;
    address[] public staffList;

    // Whitelisted addresses for transfers
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public nonces;
    mapping(uint256 => mapping(address => uint256)) public sessionNonces;
    uint256 public nextSessionId = 1; // auto-incrementing session ID

    // Nonce for meta-transactions
    // Daily transfer limit
    uint256 public dailyLimit;
    mapping(uint256 => uint256) public dailyTransferred; // dayNumber => amount
    mapping(ActionType => uint256) public actionTimelock;
    uint256 public actionCount;
    mapping(uint256 => ActionRequest) public actions;
  
    // Max per transaction
    uint256 public maxTxAmount;

    // Paused state
    bool public paused;

    // EIP-712 domain separator
  
    bytes32 public constant TRANSFER_TYPEHASH =
        keccak256(
        "Transfer(address token,address to,uint256 amount,uint256 nonce,uint256 deadline,uint256 sessionId,bytes32 paymentId)"
        );

    event TransferExecuted(address indexed token, address indexed to, uint256 amount, uint256 sessionId, string paymentId);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event UserAdded(address indexed user);
    event UserRemoved(address indexed user);
    event WhitelistUpdated(address indexed account, bool status);
    event Paused(address indexed guardian);
    event Unpaused(address indexed guardian);
    event ActionProposed(uint256 indexed id, ActionType action, address indexed maker);
    event ActionApproved(uint256 indexed id, address indexed guardian);
    event ActionExecuted(uint256 indexed id, ActionType action);
    event ActionCancelled(uint256 indexed id);
    event Initialized(address owner, uint256 dailyLimit, uint256 maxTxAmount, address guardian);

    
    error InvalidZeroAmount();

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyGuardian() {
        require(guardians[msg.sender], "NOT_GUARDIAN");
        _;
    }

    modifier onlyGuardianOrStaff() {
        require(guardians[msg.sender] || staffs[msg.sender], "Not Guardian or Staff");
        _;
    }

    modifier onlyPowerUser() {
        require(guardians[msg.sender] || staffs[msg.sender] || owner == msg.sender || systemAdmin == msg.sender, "Not Guardian or Staff or owner or system admin");
        _;
    }

    modifier onlyStaffOrOwner() {
        require(owner == msg.sender || staffs[msg.sender], "Staff or owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    
     constructor() EIP712("SmartWalletCore", "1") {}

    function initialize(
        address _owner,
        uint256 _dailyLimit,
        uint256 _maxTxAmount,
        address _guardian
    ) external initializer {

        owner = _owner;
        systemAdmin = msg.sender;
        dailyLimit = _dailyLimit;
        maxTxAmount = _maxTxAmount;
        _addGuardian(_guardian);
        emit Initialized(_owner, _dailyLimit, _maxTxAmount, _guardian);
    }

    /*constructor(address _owner, uint256 _dailyLimit, uint256 _maxTxAmount, address _guardian)
    EIP712("SmartWalletCore", "1") {
        owner = _owner;
        systemAdmin = msg.sender;
        dailyLimit = _dailyLimit;
        maxTxAmount = _maxTxAmount;
        _addGuardian(_guardian);

       
    }*/

   function _addGuardian(address user) internal { 
        require(user != address(0), "ZERO_ADDRESS");
        require(!staffs[user], "Already Staff");
        require(!guardians[user], "Already guardian");
        guardians[user] = true; 
        guardianList.push(user);
        emit UserAdded(user);
    }
    
    function _addStaff(address user) internal 
    { 
        require(user != address(0), "ZERO_ADDRESS");
        require(!guardians[user], "Already guardian");
        require(!staffs[user], "Already Staff");
         
        staffs[user] = true;
        staffList.push(user); 
        emit UserAdded(user); 
    }

    function _removeUser(address user) internal {
        if(staffs[user]) {
            staffs[user] = false;
            for(uint i=0;i<staffList.length;i++){
            if(staffList[i]==user){
                staffList[i] = staffList[staffList.length-1];
                staffList.pop();
                break;
            }
          }
        emit UserRemoved(user);
        } else if(guardians[user]){
            guardians[user] = false;
            for(uint i=0;i<guardianList.length;i++){
                if(guardianList[i]==user){
                    guardianList[i] = guardianList[guardianList.length-1];
                    guardianList.pop();
                    break;
                }
            }
            emit UserRemoved(user);
        }
    }

    function removeUser(address user) external onlyOwner  {
        _removeUser(user);
    }

    function changeOwner(address newOwner) internal {
        require(newOwner != address(0), "ZERO_ADDRESS");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    /*** Pause / Unpause ***/
    function pause() external {
        require(owner == msg.sender || systemAdmin == msg.sender, "Only owner or system admin can pause");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /*** Whitelist Functions ***/
    function setWhitelist(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function executeTransfer(
        address token,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 sessionId,
        string memory paymentId,
        bytes memory signature
    ) external whenNotPaused nonReentrant {
       
        require(block.timestamp <= deadline, "EXPIRED");
        require(amount <= maxTxAmount, "TX_AMOUNT_EXCEEDS_LIMIT");
             
        require(amount > 0, "zero amount");
        
        require(whitelisted[to], "address not whitelisted");
            
        require(staffs[msg.sender] || owner == msg.sender,"not authorized");
       
        // Track daily transfer
        uint256 dayNumber = block.timestamp / 1 days;
           
        require(dailyTransferred[dayNumber] + amount <= dailyLimit, "DAILY_LIMIT_EXCEEDED");
        dailyTransferred[dayNumber] += amount;

        bytes32 paymentIdHash = keccak256(bytes(paymentId));
      
        
        bytes32 structHash = keccak256(abi.encode(
                    TRANSFER_TYPEHASH,
                    token,
                    to,
                    amount,
                    nonce,
                    deadline,
                    sessionId,
                    paymentIdHash
                )
            );
     
        
        bytes32 digest = _hashTypedDataV4(structHash);
       
        
        address signer = ECDSA.recover(digest, signature);
       
        
        //require(signer == msg.sender, "SIGNER_MISMATCH");
        require(staffs[msg.sender] || msg.sender == owner, "RELAYER_NOT_ALLOWED");
        require(signer == owner || staffs[signer], "INVALID_SIGNER");
        
        // Check per-session nonce
      
        
        require(nonce == sessionNonces[sessionId][signer]++, "INVALID_NONCE");
        
        
        // Execute transfer
        if (token == address(0)) {
            (bool sent, ) = payable(to).call{value: amount}("");
            require(sent, "ETH_TRANSFER_FAILED");
        } else {
           // IERC20(token).safeTransfer(to, amount);
           IERC20(token).safeTransferFrom(signer, to, amount);
        }

        emit TransferExecuted(token, to, amount, sessionId, paymentId);
    }
      
    /*** Accept ETH ***/
    receive() external payable {}

    /*** Admin functions to update limits ***/
    function setDailyLimit(uint256 _dailyLimit) external onlyOwner
     { 
        dailyLimit = _dailyLimit;
     }
    function setMaxTxAmount(uint256 _maxTxAmount) external onlyOwner 
    { 
        maxTxAmount = _maxTxAmount;
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function proposeAction(
            ActionType actionType,
            address addressValue,
            uint256 intValue,
            uint256 expiry
        ) external onlyGuardianOrStaff nonReentrant returns (uint256) {

        require(expiry > block.timestamp, "INVALID_EXPIRY");
        require(addressValue != address(0), "ZERO_ADDRESS");
        uint256 id = actionCount++;
        actions[id] = ActionRequest({
            actionType: actionType,
            maker: msg.sender,
            addressValue: addressValue,
            intValue: intValue,
            createdAt: block.timestamp,
            executeAfter: block.timestamp + actionTimelock[actionType],
            expiry: expiry,
            executed: false
        });
        emit ActionProposed(id, actionType, msg.sender);
        return id;
    }

    function executeAction(uint256 actionId) external nonReentrant onlyPowerUser {
        ActionRequest storage action = actions[actionId];

        require(!action.executed, "EXECUTED");
        require(block.timestamp >= action.executeAfter, "TIMELOCK_ACTIVE");
        require(block.timestamp <= action.expiry, "EXPIRED");
        require(action.maker != msg.sender, "Maker cannot be executor");
        action.executed = true;

        if (action.actionType == ActionType.ADD_GUARDIAN) {
            require(msg.sender == owner, "Only Owner can add guardian");
            _addGuardian(action.addressValue);
        } else if (action.actionType == ActionType.REMOVE_GUARDIAN || action.actionType == ActionType.REMOVE_STAFF) {
            _removeUser(action.addressValue);
        } else if (action.actionType == ActionType.ADD_STAFF) {
            require(msg.sender == owner, "Only Owner can add staff");
            _addStaff(action.addressValue);
        }
        else if (action.actionType == ActionType.CHANGE_OWNER) {
            require(systemAdmin == msg.sender || guardians[msg.sender] , "Only guardian or system admin");
            changeOwner(action.addressValue);
         } else {
            revert("INVALID_ACTION");
         }
        emit ActionExecuted(actionId, action.actionType);
    }

    function getLimitsAndNonce()
        external onlyStaffOrOwner
        view
        returns (
        uint256 _dailyLimit,
        uint256 _maxTxAmount,
        uint256 _nonce
        )
    {
        return (dailyLimit, maxTxAmount,nonces[msg.sender]);
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

    function getAction(uint256 actionId)
    external
    view
    returns (
    ActionType actionType,
    address maker,
    address addressValue,
    uint256 intValue,
    uint256 createdAt,
    uint256 executeAfter,
    uint256 expiry,
    bool executed
    )
    {
        ActionRequest storage a = actions[actionId];
        return (
        a.actionType,
        a.maker,
        a.addressValue,
        a.intValue,
        a.createdAt,
        a.executeAfter,
        a.expiry,
        a.executed
        );
    }

    function getGlobalNonce() external onlyStaffOrOwner view returns (uint256) {
        return nonces[msg.sender];
    }

    function createSession() external onlyStaffOrOwner returns (uint256) {
        uint256 sessionId = nextSessionId++;
        return sessionId;
    }


    /**
    * @dev View per-session nonce
    */
    function getSessionNonce(uint256 sessionId, address user) external view returns (uint256) {
        return sessionNonces[sessionId][user];
    }

    // Fetch full list of guardians
    function getAllGuardians() external onlyStaffOrOwner view returns (address[] memory) {
        return guardianList;
    }


    // Fetch full list of staff
    function getAllStaff() external onlyStaffOrOwner view returns (address[] memory) {
        return staffList;
    }
  
}