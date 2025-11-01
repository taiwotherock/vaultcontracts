// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./IVaultCore.sol";

contract VaultLendingViews {
    IVaultCore public core;

    uint256 constant FEE_PRECISION = 1e6;

    constructor(address coreAddress) {
        require(coreAddress != address(0), "Invalid core address");
        core = IVaultCore(coreAddress);
    }

    // Example: borrower stats (vault balance + totalPaidToPool)
    function getBorrowerStats(address borrower, address token) external view returns (uint256 vaultBalance, uint256 totalPaidToPool) {
        vaultBalance = core.vault(borrower, token);
        totalPaidToPool = 0;

        uint256 len = core.getBorrowerLoansLength(borrower);
        for (uint256 i = 0; i < len; i++) {
            bytes32 loanRef = core.getBorrowerLoanAt(borrower, i);
            (, address loanToken, , , uint256 totalPaid) = core.getLoanData(loanRef);
            // only sum for the desired token (and include inactive or active as you want)
            if (loanToken == token) {
                totalPaidToPool += totalPaid;
            }
        }
    }

    
    // Protocol stats example (counts + totals)
    function getProtocolStats(address token) external view returns (
        uint256 numLenders,
        uint256 numBorrowers,
        uint256 totalLenderDeposits,
        uint256 totalBorrowed,
        uint256 totalOutstanding,
        uint256 totalPaid
    ) {
        numLenders = core.getLendersLength();
        numBorrowers = core.getBorrowersLength();

        // Sum lender deposits
        totalLenderDeposits = 0;
        for (uint256 i = 0; i < numLenders; i++) {
            address l = core.getLenderAt(i);
            totalLenderDeposits += core.vault(l, token);
        }

        // Sum borrower loans
        totalBorrowed = 0;
        totalOutstanding = 0;
        totalPaid = 0;
        for (uint256 i = 0; i < numBorrowers; i++) {
            address b = core.getBorrowerAt(i);
            uint256 len = core.getBorrowerLoansLength(b);
            for (uint256 j = 0; j < len; j++) {
                bytes32 ref = core.getBorrowerLoanAt(b, j);
                 (, address loanToken, uint256 principal,uint256 outstanding, uint256 totalPaidLoan) = core.getLoanData(ref);
                if (loanToken == token) {
                    totalBorrowed += principal;
                    totalOutstanding += outstanding;
                    totalPaid += totalPaidLoan;
                }
            }
        }
    }

    // You can add loan pagination similarly by calling core.getBorrowerLoansLength / getBorrowerLoanAt and core.loans(...)
}