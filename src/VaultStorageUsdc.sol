// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./IERC20Permit.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IAccessControlModule {
    function isAdmin(address account) external view returns (bool);
    function isCreditOfficer(address account) external view returns (bool);
}

// ------------------- Storage / Structs -------------------
contract VaultStorageUsdc {

    enum LoanStatus { Active, Defaulted, WrittenOff, Paid }
    struct Loan {
        bytes32 ref;
        address borrower;
        address merchant;
        uint256 principal;
        uint256 outstanding;
        uint256 startedAt;
        uint256 installmentsPaid;
        uint256 fee;
        uint256 totalPaid;
        LoanStatus status;
        uint256 repaidFee;
        uint256 lastPaymentTs;
        bool disbursed;
        uint256 maturityDate;
    }

    struct Timelock {
        uint256 amount;
        address token; // address(0) for ETH
        address to;
        uint256 unlockTime;
        bool executed;
    }

    uint256 internal _platformFee;
    uint256 internal _lenderFee;

    uint256 internal _platformFeeRate;
    uint256 internal _lenderFeeRate;
    uint256 internal _depositContributionPercent;

    mapping(bytes32 => Loan) public loans;
    mapping(address => bytes32[]) internal borrowerLoans;
    mapping(bytes32 => uint256) internal loanIndex;
    bytes32[] public loanRefs;
    

    mapping(address => uint256) public vault; 
    uint256 internal totalMerchantFund;         // total merchant ETH
    mapping(address => uint256) public merchantFund;  // merchant => ETH amount



    uint256 internal constant FEE_PRECISION = 1e6;

    mapping(address => bool) internal isBorrower;
    address[] internal borrowers;

    mapping(address => bool) internal isLender;
    address[] internal lenders;

    mapping(address => bool) public whitelist;
    mapping(address => bool) public blacklist;

    mapping(bytes32 => bool) internal _loanLock;

    bool public paused;
    uint256 internal _locked;

}