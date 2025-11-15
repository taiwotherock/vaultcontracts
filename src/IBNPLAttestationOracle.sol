// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


interface IBNPLAttestationOracle {
    function getAttestation(address borrower) external view returns (
        uint256 creditLimit,
        uint256 creditScore,
        bool kycVerified,
        uint256 utilizedLimit,
        address attestor,
        uint256 updatedAt
    );

    function increaseUsedCredit(address borrower, uint256 amount) external;
    function decreaseUsedCredit(address borrower, uint256 amount) external;
}