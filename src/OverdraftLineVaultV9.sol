// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./Ownable.sol";
import "./Pausable.sol";
import "./OverdraftLineVaultStorageV3.sol";
import "./ReentrancyGuard.sol";



contract OverdraftLineVaultV9 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    //IERC20 public immutable token;
    address token;

    //mapping(address => CollateralPosition) internal _positions;
    mapping(address => uint256) public balances;
    mapping(bytes32 => Overdraft) public overdrafts;
    mapping(bytes32 => CreditLimitAdjustment) public creditLimitAdjustments;
    //mapping(address => bool) private hasActiveOverdraft;
    //mapping(address => bytes32[]) private borrowerOverdraftRefs;
    mapping(address => bytes32) public activeOverdraftByBorrower;
    mapping(bytes32 => DebitTransaction) public debitTransactions;
    mapping(bytes32 => RepaymentTransaction) public amountsPaid;
    mapping(address => Staff) public staffs;
    mapping(bytes32 => StaffChange) public staffChangeProposals;
    //mapping(address => uint256) public tokenPrice; // token => price (fiat with 18 decimals)
    //mapping(address => bool) public userWhitelisted;
    mapping(address => bool) public userWhitelisted;
    
    // configuration
    uint256 public activeOverdraftCount;
    uint256 public maximumOverdraftLimit = 100 * 1e18; // fiat amount (e.g. cents);
    uint256 public timelockAfterApproval = 1 days;
    uint256 public globalFeeBps = 50;
    uint256 public maximumDebitAmount = 10* 1e18; // fiat amount (e.g. cents)   ;
    uint256 public maximumDailyLimit = 100 * 1e18;
    uint256 public constant BASIS_POINT_PERCENT = 10000;
    uint256 public constant MAX_DAILY_FEE_BATCH = 100;
    uint256 public maxRateChangeBps = 1000; // 10%
    uint256 public nativeDecimal= 1e18;
    uint256 public tokenDecimal=1e6;
    uint256 public tokenToFiatRate = 1478 * 1e18; // fiat per token (e.g. 1478 NGN per USDT)
    uint256 public totalFeeCollected;
    address public platformFeeAddress;
    address public contractOwner;
    uint256 public totalUserBalances;
   

    mapping(address => mapping(uint256 => uint256)) public dailyUsedByBorrower;
    mapping(bytes32 => mapping(uint256 => bool)) public dailyOverdraftFee;
    mapping(uint256 => uint256) public vaultDailyWithdrawn; // day => total withdrawn from vault
    mapping(uint256 => uint256) public vaultDailyWithdrawCap; // day => max withdrawable

    // Rescue protection
    uint256 public rescueAllowedAfter; // timestamp when owner may call rescueERC20 (must be paused)
    uint256 public constant STAFF_CHANGE_TIMELOCK = 24 hours;

    // --- Roles & governance ---
    //address public vaultAdmin; // can manage managers/credit officers, whitelist, set params
    //mapping(address => bool) public managers;
    //mapping(address => bool) public creditOfficers;
    //mapping(address => bool) public rateOracles;
    //mapping(address => bool) public vaultAdmins;
   
    
    modifier onlyVaultAdmin() {
        require(staffs[msg.sender].role == 4 && staffs[msg.sender].status, "vault admin only");
        _;
    }

    modifier onlyVaultAdminOrManager() {
        require((staffs[msg.sender].role == 4 || staffs[msg.sender].role == 1)  && staffs[msg.sender].status, "vault admin or manager only");
        _;
    }
    
    modifier onlyManager() {
        require(staffs[msg.sender].role == 1 && staffs[msg.sender].status, "manager only");
        _;
    }
    modifier onlyRateOracle() {
        require(staffs[msg.sender].role == 3 && staffs[msg.sender].status, "rate oracle only");
        _;
    }
    modifier onlyCreditOfficer() {
        require(staffs[msg.sender].role == 2 && staffs[msg.sender].status, "credit officer only");
        _;
    }

    modifier onlyWhitelistedUser() {
        require(userWhitelisted[msg.sender] , "user not whitelisted");
        _;
    }

    constructor(address _vaultAdmin, address _token, uint256 _tokenDecimal, 
    uint256 _nativeDecimal, address _platformFeeAddress, address manager,
    address creditOfficer, address rateOracle) {
        transferOwnership(msg.sender);
        
        token = _token;
        tokenDecimal = _tokenDecimal;
        nativeDecimal = _nativeDecimal;
        platformFeeAddress = _platformFeeAddress;
        contractOwner = msg.sender;

        staffs[msg.sender] = Staff({
            status: true,
            addedBy: msg.sender,
            timestamp: block.timestamp,
            role: 4 // vault admin
         });

         staffs[_vaultAdmin] = Staff({
            status: true,
            addedBy: msg.sender,
            timestamp: block.timestamp,
            role: 4 // vault admin
         });

         staffs[manager] = Staff({
            status: true,
            addedBy: msg.sender,
            timestamp: block.timestamp,
            role: 1 // manager
         });

         staffs[creditOfficer] = Staff({
            status: true,
            addedBy: msg.sender,
            timestamp: block.timestamp,
            role: 2 // credit officer
         });

         staffs[rateOracle] = Staff({
            status: true,
            addedBy: msg.sender,
            timestamp: block.timestamp,
            role: 3 // rate oracle
         });
    }
    
    // --- Helpers ---
    function _dayOf(uint256 ts) internal pure returns (uint256) { return ts / 1 days; }

    // --- Role management ---
    function disableStaff(address staff) external onlyVaultAdmin {
        require(staffs[staff].role != 4 , "cannot disable vault admin");
        staffs[staff].status = false;
        emit StaffDisabled(staff);  
    }
   
    // --- Pause/unpause ---
    function pause() external onlyVaultAdmin 
    { paused = true; }
    function unpause() external onlyVaultAdmin { paused = false; }

    // SETTER FUNCTIONS (ADMIN ONLY)

    // Set maximum overdraft limit
    function setMaximumOverdraftLimit(uint256 newLimit) external onlyVaultAdmin {
        require(newLimit > 0, "INVALID_LIMIT");
        maximumOverdraftLimit = newLimit;
    }

    // Set timelock (in seconds)
    function setTimelockAfterApproval(uint256 newTimelock) external onlyVaultAdmin {
        require(newTimelock <= 30 days, "TIMELOCK_TOO_LONG");
        timelockAfterApproval = newTimelock;
    }

    // Set fee rate (basis points)
    function setGlobalFeeBps(uint256 newFeeBps) external onlyVaultAdmin {
        require(newFeeBps <= 1000, "FEE_TOO_HIGH"); // max 10%
        globalFeeBps = newFeeBps;
    }

    // Set max debit amount per transaction
    function setMaximumDebitAmount(uint256 newMaxDebit) external onlyVaultAdmin {
        require(newMaxDebit > 0, "INVALID_DEBIT");
        maximumDebitAmount = newMaxDebit;
    }

    // Set daily spending limit
    function setMaximumDailyLimit(uint256 newDailyLimit) external onlyVaultAdmin {
        require(newDailyLimit > 0, "INVALID_DAILY_LIMIT");
        maximumDailyLimit = newDailyLimit;
    }

    // Set daily spending limit
    function setTokenToFiatRate(uint256 newRate) external onlyRateOracle {
        require(newRate > 0, "INVALID_RATE");

        uint256 oldRate = tokenToFiatRate;

        // Allow first-time initialization without bounds
        if (oldRate != 0) {
            uint256 diff =
                newRate > oldRate
                    ? newRate - oldRate
                    : oldRate - newRate;

            // diff / oldRate <= 5%
            require(
                diff * 10_000 <= oldRate * maxRateChangeBps,
                "RATE_CHANGE_TOO_LARGE"
            );
        }

        tokenToFiatRate = newRate;

        emit TokenToFiatRateUpdated(oldRate, newRate);
    }


    // Set daily spending limit
    function setRatesAndLimits(uint256 _newDailyLimit, uint256 _newMaxDebit,uint256 _newLimit,uint256 _newFeeBps ) external onlyVaultAdmin {
        require(_newDailyLimit > 0, "INVALID_DAILY_LIMIT");
        require(_newMaxDebit > 0, "INVALID_DEBIT");
        require(_newLimit > 0, "INVALID_LIMIT");
        require(_newFeeBps <= 1000, "FEE_TOO_HIGH");
        
        maximumDebitAmount = _newMaxDebit;
        maximumOverdraftLimit = _newLimit;
        globalFeeBps = _newFeeBps;
        maximumDailyLimit = _newDailyLimit;
       
    }

     // --- Internal function to apply change ---
    function _setStaffStatus(address staffAddress, bool enable, uint32 role, address addedBy) internal {
        staffs[staffAddress] = Staff({
            status: enable,
            addedBy: addedBy,
            timestamp: block.timestamp,
            role: role
        });
    }

    //Overdraft storage od = overdrafts[creditRef];

    // --- External function to propose enabling/disabling staff ---
    function proposeStaffChange(address staffAddress, bool enable, uint32 role) external whenNotPaused onlyVaultAdmin {
        require(msg.sender != staffAddress, "cannot propose self");
        require(role > 0 && role <= 4, "invalid role");

        bytes32 changeId = keccak256(abi.encodePacked(staffAddress, enable, msg.sender, block.timestamp));
        require(!staffChangeProposals[changeId].exists, "proposal exists");

        staffChangeProposals[changeId] = StaffChange({
            staffAddress: staffAddress,
            enable: enable,
            approved: false,
            proposedBy: msg.sender,
            timestamp: block.timestamp,
            exists: true,
            role: role
        });

        emit StaffChangeProposed(staffAddress, enable, msg.sender, changeId);
    }

    // --- External function to approve a proposed change ---
    function approveStaffChange(bytes32 changeId) external whenNotPaused onlyVaultAdmin {
        StaffChange storage change = staffChangeProposals[changeId];
        require(change.exists, "proposal not found");
        require(!change.approved, "already approved");
        require(msg.sender != change.proposedBy, "proposer cannot approve");
        require(change.role > 0 && change.role <= 4, "invalid role");
        require(block.timestamp >= change.timestamp + STAFF_CHANGE_TIMELOCK, "TIMELOCK_ACTIVE");


        // Apply the change
        _setStaffStatus(change.staffAddress, change.enable, change.role, change.proposedBy);
        change.approved = true;

        emit StaffChangeApproved(change.staffAddress, change.enable, msg.sender, changeId);
    }

    function getStaffDetail(address staffAddr) external view returns (bool status, address addedBy, uint256 timestamp, uint32 role) {
        Staff storage s = staffs[staffAddr];
        return (s.status, s.addedBy, s.timestamp, s.role);
    }


    // --- Collateral deposit/withdraw ---
    function depositCollateral(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount > 0");
        // Effects
       
        //require(SafeERC20(token).safeTransferFrom(msg.sender, address(this), amount), "transfer failed");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        totalUserBalances += amount;
        // Interactions
        //IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function withdrawCollateral(uint256 amount) external whenNotPaused nonReentrant onlyWhitelistedUser  {
    
        _releaseFund(amount, msg.sender);
        emit CollateralWithdrawn(msg.sender, token, amount);
    }
   

    function _releaseFund(uint256 amount, address user) internal {
        require(amount > 0, "AMOUNT_ZERO");
        require(balances[user] >= amount, "INSUFFICIENT_COLLATERAL");
        require(tokenToFiatRate > 0, "RATE_ZERO");
        require(tokenDecimal > 0, "TOKEN_DECIMAL_ZERO");

        // --- Collateral lock check ---
        (uint256 totalUtilized,) = _totalUtilizedLimit(user);
        uint256 requiredToken =
            _utilizedAmountInToken(totalUtilized, tokenToFiatRate);

        require(
            balances[user] - requiredToken >= amount,
            "COLLATERAL_LOCKED"
        );

        // --- Global daily vault withdrawal limit (snapshot) ---
        uint256 day = _dayOf(block.timestamp);

        // Snapshot vault cap once per day
        if (vaultDailyWithdrawCap[day] == 0) {
            uint256 vaultBalance =
                IERC20(token).balanceOf(address(this));

            vaultDailyWithdrawCap[day] =
                (vaultBalance * 30) / 100; // 30% cap
        }

        require(
            vaultDailyWithdrawn[day] + amount
                <= vaultDailyWithdrawCap[day],
            "VAULT_DAILY_WITHDRAW_LIMIT"
        );

        bytes32 ref = activeOverdraftByBorrower[user];
        if (ref != bytes32(0)) {
            Overdraft storage od = overdrafts[ref];
            require(
                od.utilizedLimit == 0 && od.interestAccrued == 0,
                "ACTIVE_OVERDRAFT_COLLATERAL_LOCKED"
            );
        }

        // --- Effects ---
        vaultDailyWithdrawn[day] += amount;
        balances[user] -= amount;
        totalUserBalances -= amount;

        // --- Interaction ---
        IERC20(token).safeTransfer(user, amount);
    }


    // --- Overdraft management ---
    function postOverdraftLine(
        bytes32 ref,
        uint256 creditLimit,
        uint256 feeBps,
        uint256 expiry,
        address borrower,
        address lender,
        uint256 tokenAmount,
        uint256 _tokenToFiatRate,
        uint256 _depositCollateralPercent,
        uint256 rateBps
    ) external whenNotPaused onlyCreditOfficer {
        require(!overdrafts[ref].exists, "ref exists");
        require(creditLimit <= maximumOverdraftLimit, "exceeds maximum overdraft limit");
        //require(!hasActiveOverdraft[borrower], "Borrower has overdraft already");
        require(borrower != address(0), "Invalid borrower address");
        require(lender != address(0), "Invalid lender address");
        //require(balances[borrower] >= tokenAmount,"insufficient collateral borrower deposit");
        require(feeBps > 0, "Daily rate fee not set");
        require(_tokenToFiatRate > 0, "rate is zero");
        require(tokenAmount > 0, "Token amount is zero");
        require(creditLimit > 0, "Credit Limit is zero");
        require(expiry > 0, "Expiry date is zero");

        require(msg.sender != borrower, "credit officer cannot be owner of loan");
        require(msg.sender != lender, "credit officer cannot be lender of loan");
        
        require(
            activeOverdraftByBorrower[borrower] == bytes32(0),
            "BORROWER_ALREADY_HAS_OVERDRAFT"
        );

        uint256 depositAmountToken = (creditLimit * _depositCollateralPercent) / (100 * _tokenToFiatRate / tokenDecimal);

        require(balances[borrower] >= depositAmountToken,"insufficient collateral borrower deposit");

        overdrafts[ref] = Overdraft({
            ref: ref,
            creditLimit: creditLimit,
            availableLimit: creditLimit,
            utilizedLimit: 0,
            interestAccrued: 0,
            fee: feeBps,
            rate: rateBps,
            expiry: expiry,
            borrower: borrower,
            lender: lender,
            tokenAmount: tokenAmount,
            tokenToFiatRate: _tokenToFiatRate,
            exists: true,
            approved: false
        });
        activeOverdraftByBorrower[borrower] = ref;
        activeOverdraftCount += 1;
        emit OverdraftPosted(ref, borrower, creditLimit);
    }

    function approveOverdraftLine(bytes32 creditRef) external whenNotPaused nonReentrant onlyVaultAdminOrManager {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        require(!od.approved , "overdraft already approved");
        require(msg.sender != od.borrower, "approver cannot be owner of loan");
        require(msg.sender != od.lender, "approver cannot be lender of loan");

        od.approved = true;

        emit OverdraftApproved(creditRef, od.borrower);
    }

    // borrower posts debit transaction (creates a payment against credit)
    function postDebitTransaction(bytes32 paymentRef, uint256 fiatAmount, bytes32 creditRef, uint256 amount, uint256 rate) external whenNotPaused nonReentrant  {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        require(msg.sender == od.borrower || staffs[msg.sender].role == 1 || staffs[msg.sender].role == 4, "only borrower or vault admin or manager");
        require(fiatAmount > 0, "fiatAmount zero");
        require(fiatAmount <= maximumDebitAmount, "exceeds max debit amount");
        uint256 day = _dayOf(block.timestamp);
        require(dailyUsedByBorrower[od.borrower][day] + fiatAmount <= maximumDailyLimit, "exceeds daily limit");
        require(od.availableLimit >= fiatAmount, "insufficient available limit");
        require(!debitTransactions[paymentRef].exists , "payment exists");
        require(block.timestamp <= od.expiry, "OVERDRAFT_EXPIRED");
        require(od.approved, "overdraft not approved");

        //The collateral check is removed to allow flexibility in collateral management. 
        //Under collateralization is allowed but will affect health factor and risk profile.
        //uint256 tokenValueUsed = _utilizedAmountInToken(od.utilizedLimit,od.tokenToFiatRate);
        //require(balances[od.borrower] >= tokenValueUsed, "insufficient collateral");
        //uint256 availableBalance = balances[od.borrower] - tokenValueUsed;
        //require(availableBalance >= amount, "insufficient balance");

        // Effects
        debitTransactions[paymentRef] = DebitTransaction({
            creditRef: creditRef,
            fiatAmount: fiatAmount,
            amount: amount,
            rate: rate,
            payer: msg.sender,
            markedPaid: false,
            approved: false,
            approveReleaseTimestamp: 0,
            exists: true
        });
        od.availableLimit -= fiatAmount;
        od.utilizedLimit += fiatAmount;
        dailyUsedByBorrower[od.borrower][day] += fiatAmount;

        emit DebitTransactionPosted(paymentRef, creditRef, fiatAmount,amount,rate);
    }

    // manager post repayment paid (records payment as paid and stores AmountPaid)
    function postRepayment(bytes32 paymentRef, address borrower, uint256 fiatAmount, uint256 amount, uint256 rate, bytes32 creditRef) external whenNotPaused onlyVaultAdminOrManager {
        
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        require(borrower == od.borrower, "not borrower");
        require(!amountsPaid[paymentRef].exists , "payment exists");
        require(od.approved, "overdraft line not approved");
        
        amountsPaid[paymentRef] = RepaymentTransaction({tranRef: paymentRef, borrower: borrower,
        amount: amount, fiatAmount: fiatAmount, rate: rate, creditRef: creditRef, exists:true,
        approved:false,postedBy: msg.sender });

        emit PaymentMarkedPaid(paymentRef, creditRef, amount, fiatAmount, rate, msg.sender);
    }

    // vault admin approves marked payment and starts timelock for borrower withdrawal
    function approveRepayment(bytes32 paymentRef, bytes32 creditRef) external whenNotPaused onlyVaultAdmin {
        RepaymentTransaction storage tp = amountsPaid[paymentRef];
        require(tp.exists, "no payment");
        require(tp.creditRef == creditRef, "credit mismatch");
        //require(du.markedPaid, "not marked");
        require(!tp.approved, "already approved");
        require(tp.postedBy != msg.sender, "same address cannot post and approve");

        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
   
        //od.availableLimit += tp.fiatAmount;
        //od.utilizedLimit -= tp.fiatAmount;

         uint256 remaining = tp.fiatAmount;

        // Pay interest first
        if (od.interestAccrued > 0) {
            if (remaining >= od.interestAccrued) {
                remaining -= od.interestAccrued;
                od.interestAccrued = 0;
            } else {
                od.interestAccrued -= remaining;
                remaining = 0;
            }
        }

        // Pay principal
        if (remaining > 0) {
            //require(od.utilizedLimit >= remaining, "OVERPAY");
            od.utilizedLimit -= remaining;
            od.availableLimit += remaining;
        }

        // 3️⃣ Clear active flag ONLY when fully settled
        if (od.utilizedLimit == 0 && od.interestAccrued == 0) {
            activeOverdraftByBorrower[od.borrower] = bytes32(0);
            if (activeOverdraftCount > 0) {
                activeOverdraftCount -= 1;
            }
        }

        tp.approved = true;

        //du.approveReleaseTimestamp = block.timestamp + timelockAfterApproval;

        emit PaymentApproved(paymentRef, creditRef);
    }

   function repayOverdraftWithToken(
        bytes32 creditRef,
        uint256 tokenAmount
    ) external whenNotPaused nonReentrant onlyWhitelistedUser {
        require(tokenAmount > 0, "AMOUNT_ZERO");

        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "OVERDRAFT_NOT_FOUND");
        require(od.approved, "OVERDRAFT_NOT_APPROVED");
        require(msg.sender == od.borrower, "NOT_BORROWER");
        require(tokenToFiatRate > 0, "RATE_ZERO");
        require(tokenDecimal > 0, "TOKEN_DECIMAL_ZERO");

        // Pull tokens in first (effects-before-interactions protected by nonReentrant)
        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            tokenAmount
        );

        // Convert token → fiat
        uint256 fiatAmount =
            _collateralTokenAmountInFiat(tokenAmount, tokenToFiatRate);
        require(fiatAmount > 0, "FIAT_ZERO");

        uint256 remainingFiat = fiatAmount;
        uint256 interestPaid;
        uint256 principalPaid;

        // 1️⃣ Pay interest first
        if (od.interestAccrued > 0 && remainingFiat > 0) {
            uint256 interestToPay = remainingFiat > od.interestAccrued
                ? od.interestAccrued
                : remainingFiat;

            interestPaid = interestToPay;
            od.interestAccrued -= interestToPay;
            remainingFiat -= interestToPay;
        }

        // 2️⃣ Pay principal (CAPPED — never revert)
        if (od.utilizedLimit > 0 && remainingFiat > 0) {
            uint256 principalToPay = remainingFiat > od.utilizedLimit
                ? od.utilizedLimit
                : remainingFiat;

            principalPaid = principalToPay;
            od.utilizedLimit -= principalToPay;
            od.availableLimit += principalToPay;
            remainingFiat -= principalToPay;
        }

        // 3️⃣ Close overdraft if fully settled
        if (od.utilizedLimit == 0 && od.interestAccrued == 0) {
            activeOverdraftByBorrower[od.borrower] = bytes32(0);
            if (activeOverdraftCount > 0) {
                activeOverdraftCount -= 1;
            }
        }

        // 4️⃣ Refund excess tokens (if user overpaid)
        if (remainingFiat > 0) {
            
            uint256 refundTokenAmount =
                _collateralTokenAmountInFiat(
                    remainingFiat,
                    tokenToFiatRate
                );

            if (refundTokenAmount > 0) {
                IERC20(token).safeTransfer(
                    platformFeeAddress,
                    refundTokenAmount
                );
            }
        }

        emit OverdraftRepaidByBorrower(
            msg.sender,
            creditRef,
            tokenAmount,
            fiatAmount,
            interestPaid,
            principalPaid
        );
    }



   
    // whitelist borrower
    function whitelistUser(address borrower, bool allowed) external onlyVaultAdminOrManager {
        userWhitelisted[borrower] = allowed;
        emit UserWhitelisted(borrower, allowed);
    }

    function isUserWhitelisted(address user) external view returns (bool) {
        return userWhitelisted[user];
    }

    function postDailyFee(bytes32 creditRef) external whenNotPaused nonReentrant onlyVaultAdminOrManager {
        _postDailyFee(creditRef);
    }   

    // post daily fee and deduct from collateral. Manager only.
    function _postDailyFee(bytes32 creditRef) internal {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        address borrower = od.borrower;
               
        require(od.utilizedLimit > 0, "no utilized fund");
        
        uint256 day = _dayOf(block.timestamp);
        //daily fee amount
        // daily fee in fiat
        uint256 feeAmtFiat = (od.utilizedLimit * od.fee) / BASIS_POINT_PERCENT;
        require(feeAmtFiat > 0, "ZERO_INTEREST");
        //uint256 feeAmt =  (od.utilizedLimit * od.fee) / 10000;
        // convert fee to token units (6 decimals)
        uint256 feeAmtToken = _utilizedAmountInToken(feeAmtFiat,od.tokenToFiatRate);
        require(balances[borrower] >= feeAmtToken,"INSUFFICIENT_COLLATERAL");

        require(!dailyOverdraftFee[od.ref][day], "daily fee already posted");
        require(balances[borrower] >= feeAmtToken, "insufficient collateral balance");
        require(od.availableLimit >= feeAmtFiat, "insufficient available limit");

        // Deduct
        balances[borrower] -= feeAmtToken;
        totalUserBalances -= feeAmtToken;
        //od.availableLimit -= feeAmtFiat;
        od.interestAccrued += feeAmtFiat;       // track interest separately

         // ✅ INTEREST CAP — MUST BE HERE
            require(
                od.interestAccrued <= od.utilizedLimit * 2,
                "INTEREST_CAP"
            );
 
        totalFeeCollected += feeAmtToken;
        dailyOverdraftFee[od.ref][day] = true;
        emit DailyFeePosted(creditRef, feeAmtToken);
    }

    function processBorrowersDailyFee(address[] calldata borrowers)
        external
        onlyManager
    {
        uint256 day = _dayOf(block.timestamp);
        uint256 len = borrowers.length;
        require(len <= MAX_DAILY_FEE_BATCH, "BATCH_TOO_LARGE");

        for (uint256 i = 0; i < len; i++) {
            address borrower = borrowers[i];
            bytes32 ref = activeOverdraftByBorrower[borrower];
            if (ref == bytes32(0)) {
                //emit BorrowerDailyFeeProcessed(borrower, ref, false, "NO_ACTIVE_OVERDRAFT");
                continue;
            }

            Overdraft storage od = overdrafts[ref];
            if (!od.exists) {
                //emit BorrowerDailyFeeProcessed(borrower, ref, false, "OVERDRAFT_NOT_FOUND");
                continue;
            }

            if (dailyOverdraftFee[ref][day]) {
                //emit BorrowerDailyFeeProcessed(borrower, ref, false, "FEE_ALREADY_POSTED");
                continue;
            }

            if (block.timestamp > od.expiry) {
                emit BorrowerDailyFeeProcessed(borrower, ref, false, "OVERDRAFT_EXPIRED");
                continue;
            }

            if (od.utilizedLimit == 0) {
                //emit BorrowerDailyFeeProcessed(borrower, ref, false, "ZERO_UTILIZED_LIMIT");
                continue;
            }

            uint256 feeAmtFiat = (od.utilizedLimit * od.fee) / BASIS_POINT_PERCENT;
            uint256 feeAmtToken = _utilizedAmountInToken(feeAmtFiat, od.tokenToFiatRate);

            if (balances[borrower] < feeAmtToken) {
                emit BorrowerDailyFeeProcessed(borrower, ref, false, "INSUFFICIENT_COLLATERAL");
                continue;
            }

            // All checks passed → post daily fee
            _postDailyFee(ref);
            emit BorrowerDailyFeeProcessed(borrower, ref, true, "SUCCESS");
        }
    }

    
    function withdrawFee(uint256 amount) external whenNotPaused nonReentrant onlyVaultAdmin {
        require(totalFeeCollected > 0, " Fee > 0");
        require(amount <= totalFeeCollected, "INSUFFICIENT_FEES");
        uint256 vaultBalance =
                IERC20(token).balanceOf(address(this));
        require(amount <= vaultBalance, "INSUFFICIENT_VAULT_BALANCE");
        
        totalFeeCollected -= amount;
        //require(IERC20(token).transfer(platformFeeAddress, amount),"token transfer failed");
        IERC20(token).safeTransfer(platformFeeAddress, amount);

        emit PlatformFeeWithdrawn(platformFeeAddress, amount);
    }

    function computeDepositAmountToken(
        uint256 creditLimit,               // fiat amount (e.g. cents)
        uint256 depositCollateralPercent,  // e.g. 120 = 120%
        uint256 _tokenToFiatRate            // fiat per token
    ) external view returns (uint256 depositAmountToken) {
        require(creditLimit > 0, "ZERO_CREDIT_LIMIT");
        require(depositCollateralPercent > 0, "ZERO_PERCENT");
        require(_tokenToFiatRate > 0, "ZERO_RATE");
        require(tokenDecimal > 0, "TOKEN_DECIMAL_ZERO");

        // fiat collateral required
        uint256 collateralFiat =
            (creditLimit * depositCollateralPercent) / 100;

        // convert fiat → token
        depositAmountToken =
            (collateralFiat * tokenDecimal) / _tokenToFiatRate;
    }

    function modifyOverdraftLine(
        bytes32 ref,
        bytes32 tranRef,
        bool topup,
        uint256 fiatAmount,
        uint256 feeBps,
        uint256 expiry,
        uint256 tokenAmount,
        uint256 _tokenToFiatRate,
        uint256 _depositCollateralPercent,
        uint256 rateBps
    ) external whenNotPaused onlyCreditOfficer {

        Overdraft storage od = overdrafts[ref];
        require(od.exists, "no overdraft");
        require(!creditLimitAdjustments[tranRef].exists, "tranref exists");
        require(block.timestamp <= od.expiry, "OVERDRAFT_EXPIRED");

        uint256 depositAmountToken = (od.creditLimit * _depositCollateralPercent) / (100 * _tokenToFiatRate / tokenDecimal);
        require(balances[od.borrower] >= depositAmountToken,"insufficient collateral borrower deposit");

           creditLimitAdjustments[tranRef] = CreditLimitAdjustment({
                creditRef: ref,
                tranRef: tranRef,
                topup: topup,
                amount: tokenAmount,
                fiatAmount: fiatAmount,
                rate: _tokenToFiatRate,
                exists: true,
                approved: false
            }); 

            if(topup) {
                od.creditLimit += fiatAmount;
                od.availableLimit += fiatAmount;
            }
            else 
            {
                if(od.creditLimit >=fiatAmount)
                    od.creditLimit -= fiatAmount;

                if(od.availableLimit >=fiatAmount)
                    od.availableLimit -= fiatAmount;
            }
            od.fee = feeBps;
            od.expiry = expiry;
            od.approved = false;
            od.tokenAmount = tokenAmount;
            od.tokenToFiatRate = _tokenToFiatRate;
            od.rate = rateBps;
            

        emit CreditLimitAdjusted( ref, tranRef, topup,  fiatAmount,  feeBps,  _tokenToFiatRate);
           
    }
 
    function _computeHealthFactor(
        uint256 tokenAmount,  // 6 decimals
        uint256 utilizedAmount             // 18 decimals
    )  internal view returns (uint256) {
       
        require(tokenToFiatRate > 0, "RATE_ZERO");       // Ensure rate is set
        require(tokenDecimal > 0, "UTILIZED_ZERO");  
        // Convert collateral to NGN (no decimals added)
        uint256 collateralValue = (tokenAmount * tokenToFiatRate) / tokenDecimal;

        // Scale collateral to 18 decimals to match utilized amount
        collateralValue = collateralValue * nativeDecimal;
        if(utilizedAmount == 0)
           return 100;

        // HF = collateral / utilized, scaled to 1e18
        return collateralValue * 100 / utilizedAmount;
    }

    function computeHealthFactor(uint256 tokenAmount,uint256 utilizedAmount)  external view returns (uint256) {
        return _computeHealthFactor(tokenAmount,utilizedAmount);
    }

    function overdraftLineHealthFactor(bytes32 creditRef)  external view returns (uint256) {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        return _computeHealthFactor(balances[od.borrower],od.utilizedLimit + od.interestAccrued);
    }

    function _collateralTokenAmountInFiat(uint256 tokenAmount, uint256 _tokenToFiatRate)  internal view returns (uint256) {
        // GBP = (USDT * 1e18) / rate
        //(usdtAmount6 * rate) / DECIMALS_6
        require(tokenDecimal > 0, "Token Decimal is zero"); // prevent divide by zero
        return (tokenAmount * _tokenToFiatRate) / tokenDecimal;
    }

    function _utilizedAmountInToken(uint256 utilizedAmount, uint256 _tokenToFiatRate)  internal view returns (uint256) {
       require(_tokenToFiatRate > 0, "token to fiat rate is zero"); // prevent divide by zero
       return (utilizedAmount * tokenDecimal) / _tokenToFiatRate;
    }

    function utilizedAmountInToken(uint256 utilizedAmount,uint256 _tokenToFiatRate)  external view returns (uint256) {
       
       require(_tokenToFiatRate > 0, "token to fiat rate is zero");
       return (utilizedAmount * tokenDecimal) / _tokenToFiatRate;
    }

    function _totalUtilizedLimit(address borrower)
        internal
        view
        returns (uint256 totalUtilized, uint256 totalTokenAmount)
    {
        bytes32 ref = activeOverdraftByBorrower[borrower];
        if (ref != bytes32(0)) {
            Overdraft storage od = overdrafts[ref];
            if (od.exists) {
                totalUtilized = od.utilizedLimit + od.interestAccrued;
                totalTokenAmount = od.tokenAmount;
            }
        }
    }

    function vaultSolvency() external view returns (uint256 vaultBalance, uint256 liabilities, uint256 userBalances, bool isSolvent) {
         uint256 vaultBal = IERC20(token).balanceOf(address(this));
       
        // optionally add estimated user balances offchain
        return (vaultBal, totalFeeCollected,totalUserBalances, vaultBal >= (totalFeeCollected + totalUserBalances));
    }



    function getTotalUtilizedLimit(address borrower) external view returns (uint256 totalUtilized,
    uint256 totalTokenAmount) {
       (totalUtilized,totalTokenAmount) = _totalUtilizedLimit(borrower);
    }
    function getUtilizedAmountInToken(uint256 utilizedAmount,uint256 _tokenToFiatRate) external view returns (uint256) {
       
       require(_tokenToFiatRate > 0, "token to fiat rate is zero");
       return (utilizedAmount * tokenDecimal) / _tokenToFiatRate;
    }

    function fetchBorrowerDepositCollateral(address borrower) external view returns (uint256) {
       
       return balances[borrower];
    }

    function fetchOverdraft(bytes32 ref) 
        external 
        view 
        returns (
            bytes32 refOut,
            uint256 creditLimit,
            uint256 availableLimit,
            uint256 utilizedLimit,
            uint256 fee,
            uint256 expiry,
            address borrower,
            address lender,
            uint256 tokenAmount,
            uint256 _tokenToFiatRate,
            uint256 healthFactor,
            uint256 tokenBalance,
            uint256 interestAccrued,
            bool approved,
            uint256 rate
        ) 
    {
        Overdraft storage od = overdrafts[ref];
        require(od.exists, "OVERDRAFT_NOT_FOUND");
        uint256 hf = _computeHealthFactor(balances[od.borrower],od.utilizedLimit);

        return (
            od.ref,
            od.creditLimit,
            od.availableLimit,
            od.utilizedLimit,
            od.fee,
            od.expiry,
            od.borrower,
            od.lender,
            od.tokenAmount,
            od.tokenToFiatRate,
            hf, 
            balances[od.borrower],
            od.interestAccrued,
            od.approved,
            od.rate
        );
    }

    function fetchDebitTransaction(bytes32 paymentRef) 
        external 
        view 
        returns (
            bytes32 creditRef,
            uint256 fiatAmount,
            uint256 amount,
            uint256 rate,
            address payer,
            bool markedPaid,
            bool approved,
            uint256 approveReleaseTimestamp,
            bool exists
        ) 
    {
        DebitTransaction storage dt = debitTransactions[paymentRef];
        require(dt.exists, "DEBIT_TRANSACTION_NOT_FOUND");

        return (
            dt.creditRef,
            dt.fiatAmount,
            dt.amount,
            dt.rate,
            dt.payer,
            dt.markedPaid,
            dt.approved,
            dt.approveReleaseTimestamp,
            dt.exists
        );
    }

    function fetchRepaymentTransaction(bytes32 tranRef) 
        external 
        view 
        returns (
            bytes32 tranRefOut,
            address borrower,
            uint256 amount,
            uint256 fiatAmount,
            uint256 rate,
            bytes32 creditRef,
            bool exists,
            bool approved
        ) 
    {
        RepaymentTransaction storage rp = amountsPaid[tranRef];
        require(rp.exists, "REPAYMENT_TRANSACTION_NOT_FOUND");

        return (
            rp.tranRef,
            rp.borrower,
            rp.amount,
            rp.fiatAmount,
            rp.rate,
            rp.creditRef,
            rp.exists,
            rp.approved
        );
    }

    function fetchVaultSettings() 
        external 
        view 
        returns (
            uint256 noOfOverdrafts,
            uint256 _maximumOverdraftLimit,
            uint256 _globalFeeBps,
            uint256 _maximumDebitAmount,
            uint256 _maximumDailyLimit,
            uint256 _tokenToFiatRate,
            uint256 _totalFeeCollected,
            uint256 _tokenDecimal,
            uint256 _vaultBalance,
            uint256 _totalUserBalances
            
        ) 
    {
       uint256 totalVaultBalance = IERC20(token).balanceOf(address(this));
        return (
           
             activeOverdraftCount,
             maximumOverdraftLimit,
             globalFeeBps,
            maximumDebitAmount,
            maximumDailyLimit,
            tokenToFiatRate,
            totalFeeCollected,
            tokenDecimal,
            totalVaultBalance,
            totalUserBalances
        );
    }


}