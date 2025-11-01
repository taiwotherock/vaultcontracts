// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {TradeEscrowVault} from "../src/TradeEscrowVault.sol";

contract TradeEscrowVaultScript is Script {
    TradeEscrowVault public tradeEscrowVaultModule;

   // You can set these addresses here or pass them via environment variables
    address public _accessControl = 0x9AEb09e5781A6C42D431e078A675582B0d4741fb;
   

    function setUp() public {
        // optional: could read addresses from env variables
        // initialAdmin = vm.envAddress("ADMIN_ADDRESS");
        // multisig = vm.envAddress("MULTISIG_ADDRESS");
    }

    function run() public {
        vm.startBroadcast();

        tradeEscrowVaultModule = new TradeEscrowVault(_accessControl);

        vm.stopBroadcast();
    }
}
