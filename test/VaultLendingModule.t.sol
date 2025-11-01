// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/VaultLending.sol";
import "../src/VaultLendingViews.sol";

contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _supply) {
        totalSupply = _supply;
        balanceOf[msg.sender] = _supply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockAccessControl is IAccessControlModule {
    mapping(address => bool) public admins;
    mapping(address => bool) public creditOfficers;

    function setAdmin(address user, bool status) external {
        admins[user] = status;
    }

    function setCreditOfficer(address user, bool status) external {
        creditOfficers[user] = status;
    }

    function isAdmin(address account) external view returns (bool) {
        return admins[account];
    }

    function isCreditOfficer(address account) external view returns (bool) {
        return creditOfficers[account];
    }
}

contract VaultLendingTest is Test {
    VaultLending vaultLending;
    MockERC20 token;
    MockAccessControl accessControl;
    VaultLendingViews vaultLendingViews;

    address admin = address(0xABCD);
    address creditOfficer = address(0xBEEF);
    address borrower = address(0xDEAD);
    address merchant = address(0xCAFE);
    address lender = address(0xFEED);

    function setUp() public {
        accessControl = new MockAccessControl();
        accessControl.setAdmin(admin, true);
        accessControl.setCreditOfficer(creditOfficer, true);

        vaultLending = new VaultLending(address(accessControl));
        token = new MockERC20(1e24); // 1 million tokens

        // Fund lender and borrower
        token.transfer(lender, 1e21);
        token.transfer(borrower, 1e21);

        // Lender approves VaultLending
        vm.prank(lender);
        token.approve(address(vaultLending), type(uint256).max);

        // Borrower approves VaultLending
        vm.prank(borrower);
        token.approve(address(vaultLending), type(uint256).max);

        // Whitelist borrower and merchant
        vm.prank(admin);
        vaultLending.setWhitelist(borrower, true);
        vm.prank(admin);
        vaultLending.setWhitelist(merchant, true);
    }

    function testDepositToVault() public {
        vm.prank(lender);
        vaultLending.depositToVault(address(token), 1e20);

        //(uint256 deposit,,,) = vaultLendingViews.getLenderStats(lender, address(token));
        //assertEq(deposit, 1e20);
    }

    function testWithdrawFromVault() public {

        vm.prank(admin);
        vaultLending.setWhitelist(lender, true);
        vm.prank(lender);
        vaultLending.depositToVault(address(token), 1e20);


        vm.prank(lender);
        vaultLending.withdrawFromVault(address(token), 5e19);

        //(uint256 deposit,,,) = vaultLendingViews.getLenderStats(lender, address(token));
        //assertEq(deposit, 5e19);
    }

    function testCreateLoan() public {
        // Lender deposits to pool
        vm.prank(lender);
        vaultLending.depositToVault(address(token), 1e20);

        // Borrower deposits collateral
        vm.prank(borrower);
        vaultLending.depositToVault(address(token), 5e19);

        bytes32 ref = keccak256(abi.encodePacked(block.timestamp));

        vm.prank(creditOfficer);
        vaultLending.createLoan(
            ref,
            address(token),
            merchant,
            1e20,
            1e19,
            5e19,
            borrower
        );

        //VaultLending.Loan storage loan = vaultLending.loans(ref);
        VaultLending.Loan memory loan = vaultLending.getLoan(ref);
   
        assertEq(loan.principal, 1e20);
        assertEq(loan.borrower, borrower);
        assertEq(loan.active, true);
    }

    function testRepayLoan() public {
        vm.prank(lender);
        vaultLending.depositToVault(address(token), 1e20);

        vm.prank(borrower);
        vaultLending.depositToVault(address(token), 5e19);

        bytes32 ref = keccak256(abi.encodePacked(block.timestamp));

        vm.prank(creditOfficer);
        vaultLending.createLoan(
            ref,
            address(token),
            merchant,
            1e20,
            1e19,
            5e19,
            borrower
        );

        vm.prank(borrower);
        vaultLending.repayLoan(ref, 1e20);

        //VaultLending.Loan memory loan = vaultLending.loans(ref);
        VaultLending.Loan memory loan = vaultLending.getLoan(ref);
        assertEq(loan.outstanding, 0);
        assertEq(loan.active, false);
    }

    function testWithdrawFees() public {
        // Lender deposits
        
        vm.prank(admin);
        vaultLending.setWhitelist(lender, true);
        vm.prank(lender);
        vaultLending.depositToVault(address(token), 1e20);

        // Borrower deposits and takes loan
        vm.prank(admin);
        vaultLending.setWhitelist(borrower, true);
        vm.prank(borrower);
        vaultLending.depositToVault(address(token), 5e19);

        bytes32 ref = keccak256(abi.encodePacked(block.timestamp));

        vm.prank(creditOfficer);
        vaultLending.createLoan(
            ref,
            address(token),
            merchant,
            1e20,
            1e19,
            5e19,
            borrower
        );

        // Repay loan to accrue fees
        vm.prank(borrower);
        vaultLending.repayLoan(ref, 1e20);

        // Withdraw fees
        //vm.prank(lender);
        //vaultLending.withdrawFees(address(token));

        //(uint256 deposit, , uint256 totalFeesEarned, uint256 feesClaimed) = vaultLendingViews.getLenderStats(lender, address(token));
        //assertEq(feesClaimed, totalFeesEarned);
    }
}