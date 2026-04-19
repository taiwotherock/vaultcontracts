// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {BfpOFTAdapter} from "../src/BfpOFTAdapter.sol";

contract DeployOApp is Script {
    function run() external {
        // Replace these env vars with your own values
        address endpoint = vm.envAddress("ENDPOINT_ADDRESS");
        address owner    = vm.envAddress("OWNER_ADDRESS");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        MyOApp oapp = new MyOApp(endpoint, owner);
        vm.stopBroadcast();

        console.log("MyOApp deployed to:", address(oapp));
    }
}