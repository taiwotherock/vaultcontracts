// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {AccessControlModule} from "../src/AccessControlModule.sol";

contract AccessControlModuleScript is Script {
    AccessControlModule public accessControlModule;

   // You can set these addresses here or pass them via environment variables
    address public initialAdmin = 0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B;
    address public multisig = 0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B;

    function setUp() public {
        // optional: could read addresses from env variables
        // initialAdmin = vm.envAddress("ADMIN_ADDRESS");
        // multisig = vm.envAddress("MULTISIG_ADDRESS");
    }

    function run() public {
        vm.startBroadcast();

        accessControlModule = new AccessControlModule(initialAdmin, multisig);

        vm.stopBroadcast();
    }
}
