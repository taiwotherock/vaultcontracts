// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockAccessControlModule {
    address public admin;

    constructor(address _admin) {
        admin = _admin;
    }

    function isAdmin(address account) external view returns (bool) {
        return account == admin;
    }
}