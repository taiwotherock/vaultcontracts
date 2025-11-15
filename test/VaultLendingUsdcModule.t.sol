// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VaultLendingUsdc.sol";

contract MockAccessControlModule {
    address public admin;
    address public creditOfficer;

    constructor(address _admin, address _creditOfficer) {
        admin = _admin;
        creditOfficer = _creditOfficer;
    }

    function isAdmin(address u) external view returns (bool) {
        return u == admin;
    }

    function isCreditOfficer(address u) external view returns (bool) {
        return u == creditOfficer;
    }
}

contract VaultLendingUsdcTest is Test {
    VaultLendingUsdc vault;
    MockAccessControlModule ac;

    address admin = address(0xA1);
    address creditOfficer = address(0xC1);
    address lender = address(0xC1);
    address borrower = address(0xB1);
    address merchant = address(0xM1);
    address platformTreasury = address(0xT1);
    address stableCoin = address(0xT1);
    address attestationOracle = address(0xT1);

    function setUp() public {
        ac = new MockAccessControlModule(admin, creditOfficer);
        vault = new VaultLendingUsdc(address(ac), platformTreasury, stableCoin, attestationOracle, "VaultUSD", "vUSDC");

        // whitelist parties
        vm.prank(admin);
        vault.setWhitelist(lender, true);

        vm.prank(admin);
        vault.setWhitelist(borrower, true);

        vm.prank(admin);
        vault.setWhitelist(merchant, true);
    }

    // ----------------------------------------------------------
    // 1. Deposit Test
    // ----------------------------------------------------------
    function testDeposit() public {
        vm.deal(lender, 100 ether);

        vm.prank(lender);
        uint256 shares = vault.deposit{value: 10 ether}();

        assertEq(vault.balanceOf(lender), shares);
        assertEq(vault.availableCash(), 10 ether);
    }

    // ----------------------------------------------------------
    // 2. Set Fee Rate
    // ----------------------------------------------------------
    function testSetFeeRate() public {
        vm.prank(admin);
        vault.setFeeRate(300, 200, 500); // 3%, 2%, 5% reserve

        assertEq(vault.getPlatformFeeRate(), 300);
        assertEq(vault.getLenderFeeRate(), 200);
    }

    // ----------------------------------------------------------
    // 3. Withdraw Test
    // ----------------------------------------------------------
    function testWithdraw() public {
        vm.deal(lender, 50 ether);

        vm.startPrank(lender);
        uint256 shares = vault.deposit{value: 10 ether}();
        vault.withdraw(shares);
        vm.stopPrank();

        assertEq(vault.availableCash(), 0);
        assertEq(vault.balanceOf(lender), 0);
    }

    // ----------------------------------------------------------
    // 4. Create Loan
    // ----------------------------------------------------------
    function testCreateLoan() public {
        vm.deal(lender, 100 ether);
        vm.deal(borrower, 50 ether);

        // borrower deposits 20 ETH
        vm.prank(borrower);
        vault.deposit{value: 20 ether}();

        // pool has 20 ETH
        vm.prank(creditOfficer);
        vault.createLoan(
            bytes32("LN1"),
            merchant,
            30 ether,   // principal
            0,
            20 ether,   // borrower deposit
            borrower,
            30 days
        );

        VaultLendingUsdc.Loan memory L = vault.getLoan(bytes32("LN1"));
        assertEq(L.principal, 30 ether);
        assertEq(L.outstanding, 10 ether);
        assertEq(L.borrower, borrower);
    }

    // ----------------------------------------------------------
    // 5. Repay Loan
    // ----------------------------------------------------------
    function testRepayLoan() public {
        vm.deal(lender, 100 ether);
        vm.deal(borrower, 100 ether);

        // borrower deposits
        vm.prank(borrower);
        vault.deposit{value: 20 ether}();

        // create loan
        vm.prank(creditOfficer);
        vault.createLoan(
            bytes32("LN2"),
            merchant,
            30 ether,
            0,
            20 ether,
            borrower,
            30 days
        );

        vm.prank(borrower);
        vault.repayLoan{value: 10 ether}(bytes32("LN2"));

        VaultLendingUsdc.Loan memory L = vault.getLoan(bytes32("LN2"));
        assertEq(L.outstanding, 0);
        assertEq(L.status, uint8(VaultLendingUsdc.LoanStatus.Paid));
    }

    // ----------------------------------------------------------
    // 6. Withdraw Merchant Fund
    // ----------------------------------------------------------
    function testMerchantWithdraw() public {
        vm.deal(lender, 100 ether);
        vm.deal(borrower, 50 ether);

        // borrower deposit 20
        vm.prank(borrower);
        vault.deposit{value: 20 ether}();

        // create loan (gives merchant settlement)
        vm.prank(creditOfficer);
        vault.createLoan(
            bytes32("MN1"),
            merchant,
            30 ether,
            0,
            20 ether,
            borrower,
            30 days
        );

        uint256 merchantBefore = merchant.balance;

        vm.prank(merchant);
        vault.withdrawMerchantFund();

        uint256 merchantAfter = merchant.balance;
        assertGt(merchantAfter, merchantBefore);
    }

    // ----------------------------------------------------------
    // 7. Withdraw Platform Fees
    // ----------------------------------------------------------
    function testWithdrawPlatformFees() public {
        vm.deal(lender, 100 ether);
        vm.deal(borrower, 100 ether);

        vm.prank(admin);
        vault.setFeeRate(500, 500, 500); // force fees: 5% + 5%

        // borrower deposits
        vm.prank(borrower);
        vault.deposit{value: 20 ether}();

        vm.prank(creditOfficer);
        vault.createLoan(
            bytes32("PL1"),
            merchant,
            30 ether,
            0,
            20 ether,
            borrower,
            30 days
        );

        uint256 feesBefore = vault.getTotalPlatformFee();
        assertGt(feesBefore, 0);

        uint256 treasuryBefore = platformTreasury.balance;

        vm.prank(admin);
        vault.withdrawPlatformFees(feesBefore);

        uint256 treasuryAfter = platformTreasury.balance;
        assertEq(treasuryAfter, treasuryBefore + feesBefore);
    }
}
