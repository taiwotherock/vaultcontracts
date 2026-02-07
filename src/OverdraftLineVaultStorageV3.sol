// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "TRANSFER_FAIL");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "TRANSFER_FROM_FAIL");
    }
    
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

    // --- Events ---
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event OverdraftPosted(bytes32 indexed ref, address borrower, uint256 creditLimit);
    event DebitTransactionPosted(bytes32 indexed paymentRef, bytes32 indexed creditRef, uint256 fiatAmount, uint256 tokenAmount,uint256 rate);
    event PaymentMarkedPaid(bytes32 indexed paymentRef, bytes32 indexed creditRef, uint256 amount, uint256 fiatAmount, uint256 rate, address indexed by);
    event PaymentApproved(bytes32 indexed paymentRef, bytes32 indexed creditRef);
    event FundsWithdrawn(address indexed borrower, bytes32 indexed creditRef, uint256 fiatAmount);
    event TokenPricePosted(address indexed token, uint256 price);
    event UserWhitelisted(address borrower, bool whitelisted);
    event ManagerToggled(address manager, bool enabled);
    event CreditOfficerToggled(address officer, bool enabled);
    event VaultAdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event PausedContract();
    event UnpausedContract();
    event DailyFeePosted(bytes32 indexed creditRef,uint256 amount);
    event DailyBulkFeePosted(uint256 totalFee,uint256 amount);
    event PlatformFeeWithdrawn(address receiver, uint256 amount);
    event CreditLimitAdjusted(bytes32 indexed ref, bytes32 indexed tranRef, bool topup, uint256  fiatAmount, uint256  feeBps, uint256  fiatRate);
    event RescueEnabled(uint256 allowedAfter);
    event RescueExecuted(address token, address to, uint256 amount);
    event OverdraftRepaid(
                bytes32 indexed creditRef,
                uint256 fiatAmount,
                uint256 utilizedLimit,
                uint256 interestAccrued
            );
    // --- Events ---
    event StaffChangeProposed(address indexed staffAddress, bool enable, address indexed proposedBy, bytes32 changeId);
    event StaffChangeApproved(address indexed staffAddress, bool enable, address indexed approvedBy, bytes32 changeId);
    event StaffDisabled(address indexed staffAddress);
    event OverdraftApproved(bytes32 indexed creditRef, address borrower);
    event TokenToFiatRateUpdated(uint256 indexed oldOracle, uint256 indexed newOracle);
    
  
  // max borrowers to process in one call to avoid gas limit issues
    

    event BorrowerDailyFeeProcessed(address borrower, bytes32 creditRef, bool success, string reason);

    event OverdraftRepaidByBorrower(
        address indexed borrower,
        bytes32 indexed creditRef,
        uint256 tokenAmount,
        uint256 fiatAmountApplied,
        uint256 interestPaid,
        uint256 principalPaid
    );


    struct Overdraft {
        bytes32 ref;
        uint256 creditLimit; // fiat units
        uint256 availableLimit;
        uint256 utilizedLimit;
        uint256 interestAccrued;    // interest accumulated (fiat)
        uint256 fee; // bps
        uint256 rate;
        uint256 expiry;
        address borrower;
        address lender;
        uint256 tokenAmount;
        uint256 tokenToFiatRate;
        bool exists;
        bool approved;
    }

    struct DebitTransaction {
        bytes32 creditRef;
        uint256 fiatAmount;
        uint256 amount; // generic amount (token units or fiat - business-defined)
        uint256 rate;   // rate at time of transaction
        address payer;
        bool markedPaid;
        bool approved;
        uint256 approveReleaseTimestamp;
        bool exists; 
    }

    struct RepaymentTransaction {
        bytes32 tranRef;
        address borrower;
        uint256 amount;
        uint256 fiatAmount;
        uint256 rate;
        bytes32 creditRef;
        bool exists;
        bool approved; 
        address postedBy;
    }

    struct CreditLimitAdjustment {
        bytes32 creditRef;
        bytes32 tranRef;
        bool topup;
        uint256 amount;
        uint256 fiatAmount;
        uint256 rate;
        bool exists;
        bool approved; 
    }

    struct Staff {
        bool status;        // active or inactive
        address addedBy;    // who added the staff
        uint256 timestamp;  // when added or changed
        uint32 role;        // 1=manager, 2=credit officer, 3=rate oracle, 4=vault admin
    }

    struct StaffChange {
        address staffAddress;
        bool enable;        // true=enable, false=disable
        bool approved;      // has another admin approved
        address proposedBy; // proposer
        uint256 timestamp;
        bool exists;
        uint32 role;        // 1=manager, 2=credit officer, 3=rate oracle, 4=vault admin       
    }

    // --- State ---
   


