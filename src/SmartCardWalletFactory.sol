// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./SmartCardWallet.sol";

contract SmartCardWalletFactory {

    using Clones for address;
    address public immutable implementation;

    /// customerHash => deployed wallet
    mapping(bytes32 => address) public customerWallet;
    bytes32[] public customerIds;

    event WalletDeployed(
        string customerId,
        address wallet,
        address owner,
        bytes32 salt,
        address cardProcessor
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
        address cardProcessor,
        address guardian,
        address riskManager
    ) external returns (address wallet) {

        bytes32 salt = _saltFromCustomer(customerId);

        // Prevent duplicate deployment
        require(customerWallet[salt] == address(0), "WALLET_ALREADY_EXISTS");

        // Deploy deterministic clone
        wallet = implementation.cloneDeterministic(salt);

        // Initialize clone
        SmartCardWallet(payable(wallet)).initialize(
            owner,
            dailyLimit,
            maxTxAmount,
            cardProcessor,
         guardian,
         riskManager
        );

        // Store mapping
        customerWallet[salt] = wallet;
        customerIds.push(salt);

        emit WalletDeployed(customerId, wallet, owner, salt, cardProcessor);
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

    function getWalletsByRange(uint256 start, uint256 end)
        external
        view
        returns (address[] memory)
    {
        require(end <= customerIds.length, "Out of bounds");
        require(start < end, "Invalid range");

        uint256 size = end - start;
        address[] memory wallets = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            bytes32 id = customerIds[start + i];
            wallets[i] = customerWallet[id];
        }

        return wallets;
    }
}