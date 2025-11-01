// IVaultCore.sol
pragma solidity ^0.8.23;

interface IVaultCore {
    // auto-generated getter for mapping(bytes32 => Loan) returns the tuple:
    function loans(bytes32) external view returns (
        bytes32 ref,
        address borrower,
        address token,
        address merchant,
        uint256 principal,
        uint256 outstanding,
        uint256 startedAt,
        uint256 installmentsPaid,
        uint256 fee,
        uint256 totalPaid,
        bool active,
        bool disbursed
    );

    function vault(address user, address token) external view returns (uint256);
    function cumulativeFeePerToken(address token) external view returns (uint256);
    function feeDebt(address lender, address token) external view returns (uint256);

    // small array getters you added
    function getBorrowersLength() external view returns (uint256);
    function getBorrowerAt(uint256 idx) external view returns (address);
    function getBorrowerLoansLength(address borrower) external view returns (uint256);
    function getBorrowerLoanAt(address borrower, uint256 idx) external view returns (bytes32);
    function getLendersLength() external view returns (uint256);
    function getLenderAt(uint256 idx) external view returns (address);

    // Slimmed down Loan view
    function getLoanData(bytes32 ref)
        external
        view
        returns (
            address borrower,
            address token,
            uint256 principal,
            uint256 outstanding,
            uint256 totalPaid
        );
}