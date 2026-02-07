// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./SmartWalletCoreUpg.sol";

contract SmartWalletCoreFactory {

    using Clones for address;
    address public immutable implementation;

    /// customerHash => deployed wallet
    mapping(bytes32 => address) public customerWallet;

    event WalletDeployed(
        string customerId,
        address wallet,
        address owner,
        bytes32 salt
    );

    constructor(address _implementation) {
        implementation = _implementation;
    }

    /**
     * Convert customerId into deterministic salt
     */
    function _saltFromCustomer(string memory customerId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(customerId));
    }

    /**
     * Deploy wallet clone for customerId
     */
    function deployWalletForCustomer(
        string memory customerId,
        address owner,
        uint256 dailyLimit,
        uint256 maxTxAmount,
        address guardian
    ) external returns (address wallet) {

        bytes32 salt = _saltFromCustomer(customerId);

        // Prevent duplicate deployment
        require(customerWallet[salt] == address(0), "WALLET_ALREADY_EXISTS");

        // Deploy deterministic clone
        wallet = implementation.cloneDeterministic(salt);

        // Initialize clone
        SmartWalletCoreUpg(payable(wallet)).initialize(
            owner,
            dailyLimit,
            maxTxAmount,
            guardian
        );

        // Store mapping
        customerWallet[salt] = wallet;

        emit WalletDeployed(customerId, wallet, owner, salt);
    }

    /**
     * Predict wallet address before deployment
     */
    function predictWalletAddress(string memory customerId)
        external
        view
        returns (address predicted)
    {
        bytes32 salt = _saltFromCustomer(customerId);

        predicted = implementation.predictDeterministicAddress(
            salt,
            address(this)
        );
    }

    /**
     * Fetch deployed wallet for customerId
     */
    function getWallet(string memory customerId)
        external
        view
        returns (address)
    {
        bytes32 salt = _saltFromCustomer(customerId);
        return customerWallet[salt];
    }
}