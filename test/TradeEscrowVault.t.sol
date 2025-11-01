// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/TradeEscrowVault.sol";
import "./mocks/MockAccessControlModule.sol";
import "./mocks/MockERC20.sol";

contract TradeEscrowVaultTest is Test {
    TradeEscrowVault vault;
    MockAccessControlModule accessControl;
    MockERC20 token;

    address admin = address(0xA1);
    address alice = address(0xB1);
    address bob = address(0xC1);

    function setUp() public {
        accessControl = new MockAccessControlModule(admin);
        vault = new TradeEscrowVault(address(accessControl));
        token = new MockERC20(1_000_000 ether);

        // Give tokens to Alice
        token.transfer(alice, 1000 ether);
        //token.transfer(bob, 1000 ether);

        // Admin whitelists Alice and Bob
        vm.startPrank(admin);
        vault.setWhitelist(alice, true);
        vault.setWhitelist(bob, true);
        vm.stopPrank();

        // Alice approves vault
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function testCreateOffer() public {
        bytes32 ref = keccak256("offer1");

        vm.startPrank(alice);
        vault.createOffer(
            ref,
            bob,
            address(token),
            true, // isBuy
            uint32(block.timestamp + 1 days),
            "USD",
            1000,
            1e18,
            10 ether
        );
        vm.stopPrank();

        (
            address creator,
            address counterparty,
            address tokenAddr,
            bool isBuy,
            uint32 expiry,
            bytes3 fiatSymbol,
            uint256 fiatAmount,
            uint256 rate,
            bool appealed,
            bool paid,
            bool released,
            uint256 tokenAmount,
            bool picked
        ) = vault.getOffer(ref);

        assertEq(creator, alice);
        assertEq(counterparty, bob);
        assertEq(tokenAddr, address(token));
        assertTrue(isBuy);
        assertEq(fiatAmount, 1000);
        assertEq(tokenAmount, 10 ether);
        assertEq(uint256(uint24(fiatSymbol)), uint256(uint24(bytes3("USD"))));
    }

    function testCancelOffer() public {
        bytes32 ref = keccak256("offer2");

       vm.startPrank(alice);
       //vm.startPrank(bob);
        vault.createOffer(
            ref,
            bob,
            address(token),
            true,
            uint32(block.timestamp + 1 days),
            "USD",
            1000,
            1e18,
            10 ether
        );

        vm.startPrank(bob);
        vault.cancelOffer(ref);
        vm.stopPrank();

        // Offer should be deleted
       // (address creator,,,,,,,,,,,) = vault.getOffer(ref);
       // assertEq(creator, address(0));
    }

    function testMarkPaidAndRelease() public {
        bytes32 ref = keccak256("offer3");

        // Alice creates offer
        vm.startPrank(alice);
        vault.createOffer(
            ref,
            bob,
            address(token),
            true,
            uint32(block.timestamp + 1 days),
            "USD",
            1000,
            1e18,
            10 ether
        );
        vm.stopPrank();

        // Bob marks paid
        vm.startPrank(bob);
        vault.markPaid(ref);
        vm.stopPrank();

        // Alice releases
        vm.startPrank(alice);
        vault.releaseOffer(ref);
        vm.stopPrank();

        // Check that Bob received the tokens
        uint256 bal = token.balanceOf(bob);
        assertEq(bal, 10 ether);
    }

    function testPauseAndUnpause() public {
        vm.startPrank(admin);
        vault.pause();
        assertTrue(vault.paused());
        vault.unpause();
        assertFalse(vault.paused());
        vm.stopPrank();
    }

    function testOnlyAdminCanPause() public {
        vm.expectRevert("Only admin");
        vault.pause();
    }
}