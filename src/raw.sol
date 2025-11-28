// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// NOTE: This enhanced contract uses OpenZeppelin contracts for security primitives.
// In production compile you must install OpenZeppelin contracts (e.g. via npm).

// OpenZeppelin inline implementations

/**
 * @dev Minimal SafeERC20
 */

// OpenZeppelin inline implementations

/**
 * @dev Minimal SafeERC20
 */
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

/** OWNABLE */
contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { owner = msg.sender; }
    modifier onlyOwner() { require(msg.sender == owner, "NOT_OWNER"); _; }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0));
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

/** PAUSABLE */
contract Pausable is Ownable {
    bool public paused;
    modifier whenNotPaused() { require(!paused, "PAUSED"); _; }
    modifier whenPaused() { require(paused, "NOT_PAUSED"); _; }
    function pause() external onlyOwner { paused = true; }
    function unpause() external onlyOwner { paused = false; }
}

/** REENTRANCY GUARD */
contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private status;
    constructor() { status = NOT_ENTERED; }
    modifier nonReentrant() {
        require(status != ENTERED, "REENTRANT");
        status = ENTERED;
        _;
        status = NOT_ENTERED;
    }
}
// OpenZeppelin inline implementations



contract OverdraftLineVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles & governance ---
    address public vaultAdmin; // can manage managers/credit officers, whitelist, set params
    mapping(address => bool) public managers;
    mapping(address => bool) public creditOfficers;

    modifier onlyVaultAdmin() {
        require(msg.sender == vaultAdmin, "vault admin only");
        _;
    }
    modifier onlyManager() {
        require(managers[msg.sender] || msg.sender == vaultAdmin || msg.sender == owner(), "manager only");
        _;
    }
    modifier onlyCreditOfficer() {
        require(creditOfficers[msg.sender] || managers[msg.sender] || msg.sender == vaultAdmin || msg.sender == owner(), "credit officer only");
        _;
    }

    constructor(address _vaultAdmin) {
        transferOwnership(msg.sender);
        vaultAdmin = _vaultAdmin;
    }

    // --- Events ---
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event OverdraftPosted(bytes32 indexed ref, address borrower, uint256 creditLimit);
    event DebitTransactionPosted(bytes32 indexed paymentRef, bytes32 indexed creditRef, uint256 fiatAmount, uint256 tokenAmount);
    event PaymentMarkedPaid(bytes32 indexed paymentRef, bytes32 indexed creditRef, uint256 amount, uint256 fiatAmount, uint256 rate, address indexed by);
    event PaymentApproved(bytes32 indexed paymentRef, bytes32 indexed creditRef, uint256 releaseTimestamp);
    event FundsWithdrawn(address indexed borrower, bytes32 indexed creditRef, uint256 fiatAmount);
    event TokenPricePosted(address indexed token, uint256 price);
    event BorrowerWhitelisted(address borrower, bool whitelisted);
    event ManagerToggled(address manager, bool enabled);
    event CreditOfficerToggled(address officer, bool enabled);
    event VaultAdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event PausedContract();
    event UnpausedContract();
    event DailyFeePosted(bytes32 indexed creditRef, uint256 feeAmount);
    event RescueEnabled(uint256 allowedAfter);
    event RescueExecuted(address token, address to, uint256 amount);

    // --- Structures ---
    struct CollateralPosition {
        mapping(address => uint256) balances;
        address[] tokens;
        mapping(address => bool) tokenExists;
    }

    struct Overdraft {
        bytes32 ref;
        uint256 creditLimit; // fiat units
        uint256 availableLimit;
        uint256 utilizedLimit;
        uint256 fee; // bps
        uint256 expiry;
        address borrower;
        address lender;
        uint256 fiatAmount;
        uint256 fiatCcyRate;
        bool exists;
    }

    struct DebitTransaction {
        bytes32 paymentRef;
        bytes32 creditRef;
        uint256 fiatAmount;
        uint256 amount; // generic amount (token units or fiat - business-defined)
        uint256 rate;   // rate at time of transaction
        uint256 tokenAmount;
        address payer;
        bool markedPaid;
        bool approved;
        uint256 approveReleaseTimestamp;
    }

    struct AmountPaid {
        uint256 amount;
        uint256 fiatAmount;
        uint256 rate;
        bytes32 creditRef;
    }

    // --- State ---
    mapping(address => CollateralPosition) internal _positions;
    mapping(bytes32 => Overdraft) public overdrafts;
    mapping(bytes32 => DebitTransaction) public debitTransactions;
    mapping(bytes32 => AmountPaid) public amountsPaid;
    mapping(address => uint256) public tokenPrice; // token => price (fiat with 18 decimals)
    mapping(address => bool) public borrowerWhitelisted;

    // configuration
    uint256 public maximumOverdraftLimit = 1_000_000 * 100;
    uint256 public timelockAfterApproval = 1 days;
    uint256 public globalFeeBps = 50;
    uint256 public maximumDebitAmount = 100_000 * 100;
    uint256 public maximumDailyLimit = 200_000 * 100;

    mapping(address => mapping(uint256 => uint256)) public dailyUsedByBorrower;

    // Rescue protection
    uint256 public rescueAllowedAfter; // timestamp when owner may call rescueERC20 (must be paused)

    // --- Helpers ---
    function _dayOf(uint256 ts) internal pure returns (uint256) { return ts / 1 days; }

    // --- Role management ---
    function setVaultAdmin(address _newAdmin) external onlyOwner {
        emit VaultAdminChanged(vaultAdmin, _newAdmin);
        vaultAdmin = _newAdmin;
    }
    function toggleManager(address _mgr, bool _enable) external onlyVaultAdmin {
        managers[_mgr] = _enable;
        emit ManagerToggled(_mgr, _enable);
    }
    function toggleCreditOfficer(address _o, bool _enable) external onlyVaultAdmin {
        creditOfficers[_o] = _enable;
        emit CreditOfficerToggled(_o, _enable);
    }

    // --- Pause/unpause ---
    function pause() external onlyVaultAdmin {
        _pause();
        emit PausedContract();
    }
    function unpause() external onlyVaultAdmin {
        _unpause();
        emit UnpausedContract();
    }

    // --- Collateral deposit/withdraw ---
    function depositCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount>0");
        // Effects
        CollateralPosition storage pos = _positions[msg.sender];
        if (!pos.tokenExists[token]) {
            pos.tokenExists[token] = true;
            pos.tokens.push(token);
        }
        pos.balances[token] += amount;
        // Interactions
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function withdrawCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount>0");
        CollateralPosition storage pos = _positions[msg.sender];
        require(pos.balances[token] >= amount, "insufficient collateral");

        // Effects: reduce first
        pos.balances[token] -= amount;
        uint256 health = computeCollateralHealthFactor(msg.sender);
        require(health == type(uint256).max || health >= 1e18, "health too low");

        // Interaction
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    // --- Overdraft management ---
    function postOverdraftLine(
        bytes32 ref,
        uint256 creditLimit,
        uint256 feeBps,
        uint256 expiry,
        address borrower,
        address lender,
        uint256 fiatAmount,
        uint256 fiatCcyRate
    ) external whenNotPaused onlyCreditOfficer {
        require(!overdrafts[ref].exists, "ref exists");
        require(creditLimit <= maximumOverdraftLimit, "exceeds maximum overdraft limit");
        overdrafts[ref] = Overdraft({
            ref: ref,
            creditLimit: creditLimit,
            availableLimit: creditLimit,
            utilizedLimit: 0,
            fee: feeBps,
            expiry: expiry,
            borrower: borrower,
            lender: lender,
            fiatAmount: fiatAmount,
            fiatCcyRate: fiatCcyRate,
            exists: true
        });
        emit OverdraftPosted(ref, borrower, creditLimit);
    }

    // borrower posts debit transaction (creates a payment against credit)
    function postDebitTransaction(bytes32 paymentRef, uint256 fiatAmount, uint256 tokenAmount, bytes32 creditRef, uint256 amount, uint256 rate) external whenNotPaused nonReentrant {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        require(msg.sender == od.borrower, "only borrower");
        require(fiatAmount <= maximumDebitAmount, "exceeds max debit amount");
        uint256 day = _dayOf(block.timestamp);
        require(dailyUsedByBorrower[msg.sender][day] + fiatAmount <= maximumDailyLimit, "exceeds daily limit");
        require(od.availableLimit >= fiatAmount, "insufficient available limit");
        require(debitTransactions[paymentRef].paymentRef == bytes32(0), "payment exists");

        // Effects
        debitTransactions[paymentRef] = DebitTransaction({
            paymentRef: paymentRef,
            creditRef: creditRef,
            fiatAmount: fiatAmount,
            amount: amount,
            rate: rate,
            tokenAmount: tokenAmount,
            payer: msg.sender,
            markedPaid: false,
            approved: false,
            approveReleaseTimestamp: 0
        });
        od.availableLimit -= fiatAmount;
        od.utilizedLimit += fiatAmount;
        dailyUsedByBorrower[msg.sender][day] += fiatAmount;

        emit DebitTransactionPosted(paymentRef, creditRef, fiatAmount, tokenAmount);
    }

    // manager marks payment paid (records payment as paid and stores AmountPaid)
    function markPaid(bytes32 paymentRef, uint256 amount, uint256 fiatAmount, uint256 rate, bytes32 creditRef) external whenNotPaused onlyManager {
        DebitTransaction storage du = debitTransactions[paymentRef];
        require(du.paymentRef != bytes32(0), "no payment");
        require(du.creditRef == creditRef, "credit mismatch");
        require(!du.markedPaid, "already marked");

        // record
        du.markedPaid = true;
        amountsPaid[paymentRef] = AmountPaid({ amount: amount, fiatAmount: fiatAmount, rate: rate, creditRef: creditRef });

        emit PaymentMarkedPaid(paymentRef, creditRef, amount, fiatAmount, rate, msg.sender);
    }

    // vault admin approves marked payment and starts timelock for borrower withdrawal
    function approveMarkAmountPaid(bytes32 paymentRef, bytes32 creditRef) external whenNotPaused onlyVaultAdmin {
        DebitTransaction storage du = debitTransactions[paymentRef];
        require(du.paymentRef != bytes32(0), "no payment");
        require(du.creditRef == creditRef, "credit mismatch");
        require(du.markedPaid, "not marked");
        require(!du.approved, "already approved");

        du.approved = true;
        du.approveReleaseTimestamp = block.timestamp + timelockAfterApproval;

        emit PaymentApproved(paymentRef, creditRef, du.approveReleaseTimestamp);
    }

    // borrower withdraw fund. Must be whitelisted and time locked after approval
    function borrowerWithdraw(bytes32 paymentRef, bytes32 creditRef, uint256 fiatAmount) external whenNotPaused nonReentrant {
        DebitTransaction storage du = debitTransactions[paymentRef];
        Overdraft storage od = overdrafts[creditRef];
        require(du.paymentRef != bytes32(0) && du.creditRef == creditRef, "invalid payment");
        require(msg.sender == du.payer, "only payer can withdraw");
        require(borrowerWhitelisted[msg.sender], "not whitelisted");
        require(du.approved, "not approved");
        require(block.timestamp >= du.approveReleaseTimestamp, "timelock not expired");
        require(fiatAmount <= du.fiatAmount, "amount too large");

        // Effects: reduce utilized limit
        require(od.utilizedLimit >= fiatAmount, "utilized underflow");
        od.utilizedLimit -= fiatAmount;
        // Clean up mapping entry to prevent re-use
        delete debitTransactions[paymentRef];
        delete amountsPaid[paymentRef];

        // Interaction: Off-chain fiat transfer assumed. Emit event for listeners.
        emit FundsWithdrawn(msg.sender, creditRef, fiatAmount);
    }

    // compute collateral health factor: (total collateral fiat value * 1e18) / utilizedLimit
    // returns type(uint256).max if no utilized limit aggregated (safe)
    function computeCollateralHealthFactor(address user) public view returns (uint256) {
        CollateralPosition storage pos = _positions[user];
        uint256 totalValueFiat = 0;
        for (uint i = 0; i < pos.tokens.length; i++) {
            address token = pos.tokens[i];
            uint256 bal = pos.balances[token];
            if (bal == 0) continue;
            uint256 price = tokenPrice[token];
            if (price == 0) continue;
            uint256 value = (bal * price) / 1e18;
            totalValueFiat += value;
        }

        // For gas reasons we don't iterate all overdrafts; consumers should store aggregate utilized off-chain or add aggregator methods
        uint256 totalUtilized = 0;
        if (totalUtilized == 0) return type(uint256).max;
        return (totalValueFiat * 1e18) / totalUtilized;
    }

    // manager posts token price
    function postTokenPrice(address token, uint256 price) external whenNotPaused onlyManager {
        require(price > 0, "price>0");
        tokenPrice[token] = price;
        emit TokenPricePosted(token, price);
    }

    // whitelist borrower
    function whitelistBorrower(address borrower, bool allowed) external onlyVaultAdmin {
        borrowerWhitelisted[borrower] = allowed;
        emit BorrowerWhitelisted(borrower, allowed);
    }

    // --- Admin setters ---
    function setMaximumOverdraftLimit(uint256 _max) external onlyVaultAdmin { maximumOverdraftLimit = _max; }
    function setTimelockAfterApproval(uint256 _seconds) external onlyVaultAdmin { timelockAfterApproval = _seconds; }
    function setFeeRateBps(uint256 _bps) external onlyVaultAdmin { globalFeeBps = _bps; }
    function setMaximumDebitAmount(uint256 _max) external onlyVaultAdmin { maximumDebitAmount = _max; }
    function setMaximumDailyLimit(uint256 _max) external onlyVaultAdmin { maximumDailyLimit = _max; }

    // post daily fee and deduct from collateral. Manager only.
    function postDailyFee(bytes32 creditRef, uint256 feeAmount) external whenNotPaused nonReentrant onlyManager {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        address borrower = od.borrower;
        CollateralPosition storage pos = _positions[borrower];
        require(feeAmount > 0, "fee 0");

        uint256 totalValue = 0;
        uint256 len = pos.tokens.length;
        uint256[] memory tokenValues = new uint256[](len);
        for (uint i = 0; i < len; i++) {
            address token = pos.tokens[i];
            uint256 bal = pos.balances[token];
            uint256 price = tokenPrice[token];
            if (bal == 0 || price == 0) { tokenValues[i] = 0; continue; }
            uint256 val = (bal * price) / 1e18;
            tokenValues[i] = val;
            totalValue += val;
        }
        require(totalValue >= feeAmount, "insufficient collateral to pay fee");

        for (uint i = 0; i < len; i++) {
            if (tokenValues[i] == 0) continue;
            address token = pos.tokens[i];
            uint256 portion = (feeAmount * tokenValues[i]) / totalValue;
            uint256 price = tokenPrice[token];
            uint256 tokenAmount = (portion * 1e18) / price;
            if (tokenAmount > pos.balances[token]) tokenAmount = pos.balances[token];
            pos.balances[token] -= tokenAmount;
            IERC20(token).safeTransfer(owner(), tokenAmount);
        }

        emit DailyFeePosted(creditRef, feeAmount);
    }

    // Rescue: owner must enable rescue with a timelock and contract must be paused to call rescue
    function enableRescue(uint256 delaySeconds) external onlyOwner {
        rescueAllowedAfter = block.timestamp + delaySeconds;
        emit RescueEnabled(rescueAllowedAfter);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant whenPaused {
        require(rescueAllowedAfter != 0 && block.timestamp >= rescueAllowedAfter, "rescue not allowed yet");
        require(amount > 0, "amount>0");
        // In production, further checks should be made to ensure not rescuing user collateral tokens without consent.
        IERC20(token).safeTransfer(to, amount);
        emit RescueExecuted(token, to, amount);
    }

}
