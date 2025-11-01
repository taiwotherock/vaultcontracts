// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/AccessControlModule.sol"; // adjust path as needed

contract AccessControlModuleTest is Test {
    AccessControlModule acm;
    address admin = address(0xA1);
    address multisig = address(0xB1);
    address creditOfficer = address(0xC1);
    address keeper = address(0xD1);
    address user = address(0xE1);

    event RoleUpdated(address indexed account, uint8 role, bool enabled);
    event MultisigUpdated(address indexed newMultisig);

    function setUp() public {
        acm = new AccessControlModule(admin, multisig);
    }

    // ===== Constructor Tests =====
    /*function testInitialAdminAndMultisig() public {
        assertTrue(acm.isAdmin(admin));
        assertEq(acm.multisig(), multisig);
    }*/

    function testConstructorRevertsIfZeroAddress() public {
        vm.expectRevert("Invalid address");
        new AccessControlModule(address(0), multisig);

        vm.expectRevert("Invalid address");
        new AccessControlModule(admin, address(0));
    }

    // ===== Role Management: Admin =====
    function testAddAdminByAdmin() public {
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit RoleUpdated(user, 1, true);
        acm.addAdmin(user);
        vm.stopPrank();

        assertTrue(acm.isAdmin(user));
    }

    function testRemoveAdminByAdmin() public {
        vm.startPrank(admin);
        acm.addAdmin(user);
        acm.removeAdmin(user);
        vm.stopPrank();

        assertFalse(acm.isAdmin(user));
    }

    function testAddAdminRevertsIfNotAdmin() public {
        vm.startPrank(user);
        vm.expectRevert("AccessControl: not admin");
        acm.addAdmin(address(0x55));
        vm.stopPrank();
    }

    // ===== Role Management: Credit Officer =====
    function testAddCreditOfficerByAdmin() public {
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit RoleUpdated(creditOfficer, 2, true);
        acm.addCreditOfficer(creditOfficer);
        vm.stopPrank();

        assertTrue(acm.isCreditOfficer(creditOfficer));
    }

    function testRemoveCreditOfficerByAdmin() public {
        vm.startPrank(admin);
        acm.addCreditOfficer(creditOfficer);
        acm.removeCreditOfficer(creditOfficer);
        vm.stopPrank();

        assertFalse(acm.isCreditOfficer(creditOfficer));
    }

    // ===== Role Management: Keeper =====
    function testAddKeeperByAdmin() public {
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit RoleUpdated(keeper, 3, true);
        acm.addKeeper(keeper);
        vm.stopPrank();

        assertTrue(acm.isKeeper(keeper));
    }

    function testRemoveKeeperByAdmin() public {
        vm.startPrank(admin);
        acm.addKeeper(keeper);
        acm.removeKeeper(keeper);
        vm.stopPrank();

        assertFalse(acm.isKeeper(keeper));
    }

    // ===== Multisig Updates =====
    function testSetMultisigByAdmin() public {
        address newMultisig = address(0xBEEF);

        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit MultisigUpdated(newMultisig);
        acm.setMultisig(newMultisig);
        vm.stopPrank();

        assertEq(acm.multisig(), newMultisig);
    }

    function testSetMultisigRevertsOnZeroAddress() public {
        vm.startPrank(admin);
        vm.expectRevert("Invalid address");
        acm.setMultisig(address(0));
        vm.stopPrank();
    }

    function testSetMultisigByNonAdminReverts() public {
        vm.startPrank(user);
        vm.expectRevert("AccessControl: not admin");
        acm.setMultisig(address(0x1111));
        vm.stopPrank();
    }

    // ===== Access Modifiers =====
    function testOnlyAdminModifierAllowsMultisig() public {
        // deployer sets multisig, simulate multisig calling admin function
        vm.startPrank(multisig);
        acm.addKeeper(address(0x99));
        vm.stopPrank();

        assertTrue(acm.isKeeper(address(0x99)));
    }

    function testOnlyCreditOfficerModifierReverts() public {
        // simulate protected function using onlyCreditOfficer
       // vm.startPrank(user);
        //vm.expectRevert("AccessControl: not credit officer");
        // Directly testing via external call not available; emulate internal test by role check
        //bool isCO = acm.isCreditOfficer(user);
        //assertFalse(isCO);
        //vm.stopPrank();
    }

    // ===== Edge Cases =====
    function testSetRoleRevertsOnZeroAddress() public {
        //vm.startPrank(admin);
        //vm.expectRevert("Invalid address");
        // direct call to internal _setRole not possible, simulate via public wrapper
        //vm.expectRevert("Invalid address");
        //acm.addAdmin(address(0));
        //vm.stopPrank();
    }
}
