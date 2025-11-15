// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;


import "./VaultStorage.sol";
import "./SimpleERC20.sol";
import "./SimpleOwnable.sol";
//import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
//import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//import "@openzeppelin/contracts/access/Ownable.sol";

contract VaultLendingV6 is VaultStorage, SimpleERC20, SimpleOwnable {

   
    uint256 private nextLoanId = 1;
    IERC20 public immutable depositToken; 
     // --- Configurable parameters ---
    uint256 public reserveRateBP = 500; // basis points: 500 = 5%
    uint256 public writeOffDays = 180;   // days after which loan may be written off
    uint256 public constant BP_DIVISOR = 10000;
    uint256 public constant DECIMAL_MULTIPLIER = 1e18;

    // --- Reentrancy guard ---
    uint8 private _status;
    uint8 private constant _NOT_ENTERED = 1;
    uint8 private constant _ENTERED = 2;

    // --- Pool accounting ---
    uint256 public poolCash;            // liquid cash available in pool (wei)
    uint256 public reserveBalance;      // reserve for bad debt (wei)
    uint256 public totalPrincipalOutstanding; // sum of active loan principals not yet repaid (wei)
    uint256 public totalDistributableEarnings; // earnings available (interest minus reserve cuts), included in poolCash
     // platform treasury where platform fees will be sent on withdraw
    address public platformTreasury;
    uint256 private loanCounter = 0;
    uint256 private totalDisbursedToMerchant = 0;

    IAccessControlModule public immutable accessControl;
    
   
    // Events
   
    event LoanCreated(bytes32 loanId, address borrower, uint256 principal, uint256 fee,
    uint256 depositAmount,uint256 lenderFundDeducted, uint256 merchantSettledFund);
    event LoanDisbursed(bytes32 loanId, address borrower, uint256 amount);
    event LoanRepaid(bytes32 loanId, address indexed borrower, uint256 indexed amount, uint256 indexed lenderFee,uint256 platformFee);
    event LoanClosed(bytes32 loanId, address indexed borrower,uint256 indexed lenderFee,uint256 indexed platformFee);
    event FeesWithdrawn(address indexed lender, address indexed token, uint256 indexed amount);
    event Deposited(address indexed user, uint256 indexed amount, uint256 indexed sharesMinted);
    event Withdrawn(address indexed user, uint256 indexed amount, uint256 indexed sharesBurned);
    
    event InstallmentRecorded(uint256 indexed loanId, uint256 principalPaid, uint256 feePaid, uint256 reserveCut);
    event LoanDefaulted(bytes32 indexed loanId,address indexed borrower, uint256 indexed outstanding);
    event LoanWrittenOff(bytes32 indexed loanId, uint256 indexed lossCoveredByReserve, uint256 indexed lossToPool);


    event Paused();
    event Unpaused();
    event Whitelisted(address indexed user, bool status);
    event Blacklisted(address indexed user, bool status);
    event FeeRateChanged(uint256 platformFeeRate, uint256 lenderFeeRate);
    event DepositContributionChanged(uint256 depositContributionPercent);
    event MerchantWithdrawn(address indexed merchant, address indexed token, uint256 amount);

    event PlatformFeeWithdrawn(address indexed platformTreasury, uint256 indexed amount);
  
    event TimelockCreated(bytes32 indexed id, address token, address to, uint256 amount, uint256 unlockTime);
    event TimelockExecuted(bytes32 indexed id);

    constructor(address _accessControl, address _depositToken,  address _platformTreasury, 
    string memory name_, string memory symbol_)
     SimpleERC20(name_, symbol_, 6) {
        require(_accessControl != address(0), "Invalid access control");
       require(_depositToken != address(0), "invalid token");
        depositToken = IERC20(_depositToken);
        accessControl = IAccessControlModule(_accessControl);
        platformTreasury = _platformTreasury;
        _locked = 1;
    }

    // ====== Reentrancy Guard ======
    modifier nonReentrant() {
        require(_locked == 1, "ReentrancyGuard: reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ====== Modifiers ======
    modifier onlyAdmin() {
        require(accessControl.isAdmin(msg.sender), "Only admin");
        _;
    }

    modifier onlyCreditOfficer() {
        require(accessControl.isCreditOfficer(msg.sender), "Only credit officer");
        _;
    }

    modifier onlyWhitelisted(address user) {
        require(whitelist[user], "User not whitelisted");
        _;
    }

    modifier notBlacklisted(address user) {
        require(!blacklist[user], "User is blacklisted");
        _;
    }

    modifier loanExists(bytes32 ref) {
        require(loans[ref].borrower != address(0), "Loan does not exist");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    modifier nonReentrantLoan(bytes32 ref) {
        require(!_loanLock[ref], "ReentrancyGuard: loan locked");
        _loanLock[ref] = true;
        _;
        _loanLock[ref] = false;
    }

    modifier onlyActiveLoan(bytes32 ref) {
        require(loans[ref].status == LoanStatus.Active, "Loan not active");
        _;
    }

    modifier onlyAuthorized() {
        
         require( accessControl.isAdmin(msg.sender) || accessControl.isCreditOfficer(msg.sender)
        , "permission denied");
        
         _;
    }

    // ====== Admin: Whitelist / Blacklist ======
    function setWhitelist(address user, bool status) external onlyAdmin {
        whitelist[user] = status;
        emit Whitelisted(user, status);
    }

    function setBlacklist(address user, bool status) external onlyAdmin {
        blacklist[user] = status;
        emit Blacklisted(user, status);
    }

    // ====== Admin: Pause / Unpause ======
    function pause() external onlyAdmin {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused();
    }

    function setPlatformTreasury(address t) external onlyOwner {
        require(t != address(0), "zero");
        platformTreasury = t;
    }

    function setReserveRateBP(uint256 bp) external onlyOwner {
        require(bp <= BP_DIVISOR, "bad bp");
        reserveRateBP = bp;
    }


    // -----------------------
    // NAV & share price
    // -----------------------
    /// @notice NAV = poolCash + outstanding principal + reserve
    function _nav() internal view returns (uint256) {
        return poolCash + totalPrincipalOutstanding + reserveBalance;
    }

    function nav() external view returns (uint256) {
        return _nav();
    }

    /// @notice share price scaled by 1e18
    function sharePrice() external view returns (uint256) {
        if (totalSupply == 0) return DECIMAL_MULTIPLIER;
        return (_nav() * DECIMAL_MULTIPLIER) / totalSupply;
    }

    function setFeeRate(uint256 platformFeeRate, uint256 lenderFeeRate,uint256 bp) external onlyAdmin {
        require(platformFeeRate + lenderFeeRate <= FEE_PRECISION, "Invalid fee setup");
        require(bp <= BP_DIVISOR, "bad bp");
        reserveRateBP = bp;
        _platformFeeRate = platformFeeRate;
        _lenderFeeRate = lenderFeeRate;
        emit FeeRateChanged(platformFeeRate, lenderFeeRate);
    }

    function setDepositContributionPercent(uint256 depositContributionPercent) external onlyAdmin {
        _depositContributionPercent = depositContributionPercent;
        emit DepositContributionChanged(depositContributionPercent);
    }

    /* ========== VAULT FUNCTIONS ========== */

    function deposit(address token,uint256 amount) external returns (uint256 sharesMinted) {
        require(amount > 0, "zero deposit");
        uint256 supply = totalSupply;
        uint256 nav2 = _nav();

        require(depositToken.transferFrom(msg.sender, address(this), amount), "transfer failed");

        uint256 shares;
        if (supply == 0 || nav2 == 0) {
            shares = amount * (10 ** decimals);
        } else {
            shares = (amount * supply) / nav2;
        }

        _mint(msg.sender, shares);
         // --- Update multi-token pool variables ---
        pool[token] += amount;                     // total pool liquidity
        vault[msg.sender][token] += amount;       // user’s deposited balance
        lenderContribution[msg.sender][token] += amount;  // lender contribution

        poolCash += amount; // overall pool cash for NAV

        emit Deposited(msg.sender, amount, shares);
        return shares;
    }


    function withdraw(address token,uint256 sharesToBurn) external
    whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) nonReentrant  {
        require(sharesToBurn > 0, "zero shares");
        require(sharesToBurn <= balanceOf[msg.sender], "insufficient shares");
        
        uint256 supply = totalSupply;
        uint256 amount = (poolCash * sharesToBurn) / supply;
        require(amount > 0, "nothing to withdraw");
        require(vault[msg.sender][token] >= amount, "insufficient vault balance");

        _burn(msg.sender, sharesToBurn);
        poolCash -= amount;
        require(depositToken.transfer(msg.sender, amount), "transfer failed");

        emit Withdrawn(msg.sender, amount, sharesToBurn);
    }

   
    function _safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransfer: failed");
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransferFrom: failed");
    }

    /* ========== LOAN FUNCTIONS ========== */

    function createLoan(bytes32 ref,address token, address merchant, uint256 principal,
     uint256 fee, uint256 depositAmount, address borrower, uint256 maturitySeconds)
     external onlyCreditOfficer {

        require(poolCash >= principal, "insufficient pool cash");
        require(pool[token] >= principal, "Insufficient pool liquidity");
        require(whitelist[borrower], "Borrower not whitelisted");
        require(whitelist[merchant], "Merchant not whitelisted");
        require(vault[borrower][token] >= depositAmount, "Insufficient vault balance");
        require(merchant != address(0), "Invalid merchant");

         // ---- Calculate components ----
        uint256 platformFee = (principal * _platformFeeRate) / BP_DIVISOR;
        uint256 lenderFee = (principal * _lenderFeeRate) / BP_DIVISOR;
        uint256 depositRequired = (principal * _depositContributionPercent) / BP_DIVISOR;
        require(depositAmount >= depositRequired, "Deposit too low");

        uint256 lenderFundDeducted = principal - depositAmount;
        uint256 merchantSettledFund = principal - platformFee - lenderFee;

        // lender and platform earn fee from deposit made, some part of deposit is earmarket for reserve
        uint256 platformFeeEarn = (depositAmount * _platformFeeRate) / BP_DIVISOR;
        uint256 lenderFeeEarn = (depositAmount * _lenderFeeRate) / BP_DIVISOR;

        if (reserveRateBP > 0) {
            uint256 reserveCut = (lenderFeeEarn * reserveRateBP) / BP_DIVISOR;
            reserveBalance += reserveCut;
            lenderFeeEarn = lenderFeeEarn - reserveCut;
        }

        // ---- Update storage ----
        _platformFee += platformFeeEarn;
        _lenderFee += lenderFeeEarn; //lender fee earned
        merchantFund[merchant][token] += merchantSettledFund;
        totalMerchantFund[token] += merchantSettledFund;

        Loan storage l = loans[ref];
        l.ref = ref;
        l.borrower = borrower;
        l.token = token;
        l.merchant = merchant;
        l.principal = principal;
        l.outstanding = principal - depositAmount;
        l.startedAt = block.timestamp;
        l.installmentsPaid = 0;
        l.fee = platformFee + lenderFee;
        l.totalPaid = depositAmount;
        l.status = LoanStatus.Active;
        l.repaidFee = platformFeeEarn + lenderFeeEarn;
        l.disbursed = false;
        l.maturityDate = block.timestamp + maturitySeconds;
        l.lastPaymentTs = block.timestamp;

        loanCounter++;
        loanRefs.push(ref);
        loanIndex[ref] = loanRefs.length - 1;



        // Disburse principal to borrower vault
        //pool[token] -= principal;
        //vault[msg.sender][token] += principal;
        //vault[borrower][token] -= depositAmount;
        //lenderContribution[borrower][token] -= depositAmount;
        //poolCash -= principal;
        totalPrincipalOutstanding += (principal - depositAmount);
        //totalPoolContribution[token] -= depositAmount

        emit LoanCreated(ref, borrower, principal, fee,depositAmount,lenderFundDeducted,merchantSettledFund);
        
       
    }

    function withdrawMerchantFund(address token) external 
    whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) nonReentrant  {
        address merchant = msg.sender;
        uint256 available = merchantFund[merchant][token];
        require(available > 0, "No funds to withdraw");

        // Reset balance BEFORE external call (prevents reentrancy)
        merchantFund[merchant][token] = 0;
        totalMerchantFund[token] -= available;

         // Decrease global liquidity to reflect outgoing funds
        pool[token] = pool[token] >= available ? pool[token] - available : 0;
        poolCash = poolCash >= available ? poolCash - available : 0;
        totalDisbursedToMerchant += available;


        // Execute safe TRC20 transfer
        IERC20 tokenA = IERC20(token);
         (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector, merchant, available)
         );
        //bool success = IERC20(token).transfer(merchant, available);
        require(success, "Token transfer failed");

        emit MerchantWithdrawn(merchant, token, available);
    }

    function repayLoan(bytes32 ref, uint256 amount) external nonReentrant  {
        Loan storage loan = loans[ref];
        require(loan.status == LoanStatus.Active, "Loan is closed");
        require(loan.borrower == msg.sender, "Not borrower");
        require(amount > 0, "Amount must be > 0");
        require(loan.outstanding > 0, "Outstanding must be > 0");

        uint256 remaining = amount;
        //uint256 outstanding = loan.outstanding;

        // Use external transfer if needed
         IERC20(loan.token).transferFrom(msg.sender, address(this), remaining);
         //vault[msg.sender][loan.token] += remaining;

         // ---- 2. Fee split ----
        uint256 platformFee = (amount * _platformFeeRate) / 1e6;
        uint256 lenderFee = (amount * _lenderFeeRate) / 1e6;
        uint256 netAmount = amount - platformFee - lenderFee;

        _platformFee += platformFee;
        _lenderFee += lenderFee;
        totalPrincipalOutstanding -=amount;

        pool[loan.token] += netAmount;
        totalPoolContribution[loan.token] += netAmount;
        poolCash += netAmount;
        
        loan.outstanding -= amount;
        loan.totalPaid += amount;
        loan.repaidFee += platformFee + lenderFee;

        if (loan.outstanding == 0) {
            loan.status = LoanStatus.Paid;
            _removeLoanFromBorrower(ref);
            emit LoanClosed(ref, msg.sender,lenderFee,platformFee);
        }
        else
          emit LoanRepaid(ref, msg.sender, amount,lenderFee,platformFee);
    }

    // -----------------------
    // Defaults & Write-offs
    // -----------------------

    /// @notice Mark a loan as defaulted (called by owner/credit officer after delinquency)
    function markDefault(bytes32 ref) external onlyCreditOfficer whenNotPaused {
        Loan storage loan = loans[ref];
        require(loan.status == LoanStatus.Active, "not active");
        loan.status = LoanStatus.Defaulted;
        emit LoanDefaulted(ref, loan.borrower, loan.outstanding);
    }

    /// @notice Write off a defaulted loan. Uses reserve first, then poolCash. Reduces NAV.
    function writeOffLoan(bytes32 ref) external onlyOwner whenNotPaused nonReentrant {
        Loan storage loan = loans[ref];
        require(loan.status == LoanStatus.Defaulted, "not defaulted");

        uint256 loss = loan.outstanding;
        if (loss == 0) {
            loan.status = LoanStatus.WrittenOff;
            emit LoanWrittenOff(ref, 0, 0);
            return;
        }

        // zero out outstanding
        loan.outstanding = 0;
        loan.status = LoanStatus.WrittenOff;

        // reduce totalPrincipalOutstanding
        if (totalPrincipalOutstanding >= loss) {
            totalPrincipalOutstanding -= loss;
        } else {
            totalPrincipalOutstanding = 0;
        }

        uint256 coveredByReserve = 0;
        uint256 lossToPool = 0;

        // consume reserve
        if (reserveBalance >= loss) {
            reserveBalance -= loss;
            coveredByReserve = loss;
            lossToPool = 0;
        } else {
            coveredByReserve = reserveBalance;
            uint256 remaining = loss - reserveBalance;
            reserveBalance = 0;

            // consume poolCash
            if (poolCash >= remaining) {
                poolCash -= remaining;
                lossToPool = remaining;
            } else {
                // if insufficient poolCash, consume what's left and remaining is implicit NAV reduction
                lossToPool = poolCash;
                poolCash = 0;
                // implicit remaining loss reduces future NAV (because outstanding was already removed)
            }
        }

        emit LoanWrittenOff(ref, coveredByReserve, lossToPool);
    }


    function _removeLoanFromBorrower(bytes32 ref) internal {
        uint256 index = loanIndex[ref];
        uint256 lastIndex = loanRefs.length - 1;

        if (index != lastIndex) {
            bytes32 lastRef = loanRefs[lastIndex];
            loanRefs[index] = lastRef;
            loanIndex[lastRef] = index;
        }

        loanRefs.pop();
        delete loanIndex[ref];
        }

    /* ========== FEE WITHDRAWAL ========== */
    /// @notice Withdraw accrued platform fees to platform treasury (owner only)
    function withdrawPlatformFees(uint256 amount,address token) external onlyOwner nonReentrant {
        require(amount > 0, "zero");
        require(amount <=_platformFee , "exceeds accrued");
        _platformFee -= amount;

        // Execute safe TRC20 transfer
        IERC20 tokenA = IERC20(token);
         (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector, platformTreasury, amount)
         );
        //bool success = IERC20(token).transfer(merchant, available);
        require(success, "Token transfer failed");
        emit PlatformFeeWithdrawn(platformTreasury, amount);
    }

    /* ========== VIEW FUNCTIONS ========== */

   

    function getAllBorrowers() external view returns (address[] memory) {
        return borrowers;
    }

    function getAllLenders() external view returns (address[] memory) {
        return lenders;
    }


    // 🔹 INTERNAL function — reusable inside contract
    function _getTotalOutstanding(address borrower) internal view returns (uint256 totalOutstanding) {
        bytes32[] storage ids = borrowerLoans[borrower];
        uint256 len = ids.length;

        for (uint256 i = 0; i < len; i++) {
            Loan storage l = loans[ids[i]];
            if (l.status == LoanStatus.Active) {
                totalOutstanding += l.outstanding;
            }
        }
    }

    // 🔹 EXTERNAL function — exposed to other contracts or frontends
    function getTotalOutstanding(address borrower) external view returns (uint256) {
        return _getTotalOutstanding(borrower);
    }

   
    function getLoans(address borrower, uint256 offset, uint256 limit) 
        external view returns (Loan[] memory result, uint256 totalLoans, uint256 nextOffset)
    {
        bytes32[] storage ids = borrowerLoans[borrower];
        totalLoans = ids.length;

        if (offset >= totalLoans) {
            // Return empty result if offset is out of bounds
           // return ; // (new Loan()[0] , totalLoans, totalLoans);
        }

        uint256 end = offset + limit;
        if (end > totalLoans) {
            end = totalLoans;
        }

        uint256 length = end - offset;
        result = new Loan[](length);

        for (uint256 i = 0; i < length; i++) {
            result[i] = loans[ids[offset + i]];
        }

        nextOffset = end;
    }

    // ====== Public Read Functions ======
    function getPlatformFeeRate() external view returns (uint256) {
        return _platformFeeRate;
    }

    function getLenderFeeRate() external view returns (uint256) {
        return _lenderFeeRate;
    }

    function getDepositContributionPercent() external view returns (uint256) {
        return _depositContributionPercent;
    }

    function getTotalPlatformFee() external view returns (uint256) {
        return _platformFee;
    }

    function getTotalLenderFee() external view returns (uint256) {
        return _lenderFee;
    }

    function getMerchantFund(address merchant, address token) external view onlyWhitelisted(msg.sender) returns (uint256) {
        return merchantFund[merchant][token];
    }
     
     function getTotalMerchantFund(address token) external view onlyAuthorized() returns (uint256)
     { 
        return totalMerchantFund[token];
     }

     function getLoan(bytes32 ref) external view returns (Loan memory) {
        return loans[ref];
     }

      function getBorrowerAt(uint256 index) external view returns (address) {
        require(index < borrowers.length, "Out of range");
        return borrowers[index];
    }
     function getBorrowerLoansLength(address borrower) external view returns (uint256) {
        return borrowerLoans[borrower].length;
    }

    function getBorrowerLoanAt(address borrower, uint256 index) external view returns (bytes32) {
        require(index < borrowerLoans[borrower].length, "Out of range");
        return borrowerLoans[borrower][index];
    }

    function getLendersLength() external view returns (uint256) {
        return lenders.length;
    }

    function getLenderAt(uint256 index) external view returns (address) {
        require(index < lenders.length, "Out of range");
        return lenders[index];
    }

    function getLoanData(bytes32 ref)
        external
        view
        returns (
            address borrower,
            address merchant,
            uint256 principal,
            uint256 outstanding,
            uint256 totalPaid,
            uint256 maturityDate,
            string memory status

        )
    {
        Loan storage l = loans[ref];
        borrower = l.borrower;
        merchant = l.merchant;
        principal = l.principal;
        outstanding = l.outstanding;
        totalPaid = l.totalPaid;
        maturityDate = l.maturityDate;
        status = _loanStatusToString(l.status);
    }

    function _loanStatusToString(LoanStatus s)
    internal
    pure
    returns (string memory)
    {
        
        if (s == LoanStatus.Active) return "Active";
        if (s == LoanStatus.Paid) return "Paid";
        if (s == LoanStatus.Defaulted) return "Defaulted";
        if (s == LoanStatus.WrittenOff) return "WrittenOff";
        return "Unknown";
    }

    function getVaultBalance(address borrower, address token) external view returns (uint256) {
        return vault[borrower][token];
    }

    function isWhitelisted(address user) external view returns (bool) {
        return whitelist[user];
    }

    function isCreditOfficer(address user) external view returns (bool) {
        return whitelist[user];
    }

    // -----------------------
    // 4️⃣ availableCash() — liquid pool balance
    // -----------------------
    function availableCash() external view returns (uint256) {
        return poolCash;
    }

    // -----------------------
    // 6️⃣ loanCounter() — number of loans
    // -----------------------
    function getLoanCounter() external view returns (uint256) {
        return loanCounter;
    }

    // -----------------------
    // 7️⃣ totalPrincipalOutstanding()
    // -----------------------
    function getTotalPrincipalOutstanding() external view returns (uint256) {
        return totalPrincipalOutstanding;
    }

    function fetchDashboardView() external view returns ( uint256 noOfLoans, uint256 poolBalance,
    uint256 totalPrincipal, uint256 poolCashTotal,uint256 totalPaidToMerchant,
    uint256 totalReserveBalance,
    uint256 totalPlatformFees,uint256 totalLenderFees,uint256 totalPastDue) {
        
        noOfLoans = loanRefs.length;
        totalPlatformFees = _platformFee;
        totalLenderFees = _lenderFee;
        poolBalance = _nav();
        totalPastDue = 0;
        totalPaidToMerchant = totalDisbursedToMerchant;
        poolCashTotal = poolCash;
        totalPrincipal= totalPrincipalOutstanding;
        totalReserveBalance = reserveBalance;
        //totalPrincipalOutstanding,totalDisbursedToMerchant,poolCash,reserveBalance


        for (uint256 i = 0; i < noOfLoans; i++) {
            Loan storage l = loans[loanRefs[i]];
            if (l.status == LoanStatus.Active && block.timestamp > l.maturityDate) {
                totalPastDue += l.outstanding;
                
            }
        }
    }

    function fetchRateSettings() external view returns ( uint256 lenderFeeRate, uint256 platformFeeRate,
    uint256 depositContributionRate, uint256 defaultBaseRate) {
        
        lenderFeeRate = _lenderFeeRate;
        platformFeeRate = _platformFeeRate;
        depositContributionRate = _depositContributionPercent;
        defaultBaseRate = reserveRateBP;
        
    }
    
}
