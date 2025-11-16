## Introduction

BNPL Liquidity Pool Contract

A Solidity implementation of a Buy-Now-Pay-Later (BNPL) liquidity pool / vault that allows lenders to deposit USDC (or a compatible stable token), mint LP shares, earn fees from loans disbursed to merchants/borrowers, and allows credit officers to originate loans against borrower attestations (credit score, limit, KYC). The contract contains vault accounting (NAV & share price), deposit/withdraw logic, loan lifecycle (create, disburse, repay, default, write-off), fee accounting and merchant withdrawals.

Quick highlights

Solidity ^0.8.23

Uses an ERC20 deposit token (USDC-style) with IERC20Permit support for permit-based repayments.

Role-based access control via an IAccessControlModule (Admin / CreditOfficer)

Attestation oracle for borrower credit score, credit limit and KYC (IBNPLAttestationOracle)

NAV calculation and LP shares (share price scaled by 1e18)

Reserve balance for bad-debt protection (reserveRateBP)

Platform fees + lender fees accounting and withdrawal

Reentrancy protection and several safety checks (whitelist/blacklist, pause, roles)

Contract overview

VaultLendingUsdcV2 extends:

VaultStorageUsdc — storage definitions for loans, vaults, lists, mappings (not included here).

SimpleERC20 — used to mint LP shares (decimals set to 6 in constructor).

SimpleOwnable — owner functionality.

Dependencies (expected interfaces):

IAccessControlModule — roles & permissions

IERC20 / IERC20Permit — deposit token (USDC-like)

IBNPLAttestationOracle — provides getAttestation(), increaseUsedCredit(), decreaseUsedCredit().

Constructor requires:

_accessControl address

_platformTreasury address

_stable token address (USDC)

_attestationOracle address

name_, symbol_ for LP token

Primary actors & roles

Lender — deposits USDC into the vault, receives LP shares, can withdraw funds + earned share of fees.

Borrower — must be whitelisted and KYC-verified via the attestation oracle. Borrows funds to purchase goods, repays loans.

Merchant — receives settled funds from loans and can withdraw merchant funds.

Credit Officer — role allowed to create loans and mark defaults; interacts with attestation oracle.

Admin / Owner — can pause/unpause, black/whitelist, change fee parameters, withdraw platform fees, write-off loans.

Core features / flows

Deposit: deposit(amount) — lender transfers USDC → contract; LP shares minted based on NAV.

Withdraw: withdraw(shares) — burns LP shares, transfers proportional NAV value in USDC to caller (whitelisted and not blacklisted).

Create Loan: createLoan(ref, merchant, principal, fee, depositAmount, borrower, maturitySeconds) — credit officer creates loan after oracle checks (credit score, limit, KYC). Part of borrower deposit can be applied. Platform & lender fees are accounted.

Repay: repayLoan(ref, amount) or repayLoanWithPermit(...) — borrower repays; fees split to platform and lenders, outstanding principal updated; poolCash increases with net.

Mark Default / Write Off: markDefault(ref) and writeOffLoan(ref) — credit officer/admin can mark defaulted loans and write them off; reserve consumed first then poolCash.

Merchant withdrawal: withdrawMerchantFund() — merchant withdraws their settled funds.

Fee withdrawal: owner can withdraw platform fees via withdrawPlatformFees(amount).

Important functions (summary)

deposit(uint256 amount) returns (uint256 sharesMinted)

withdraw(uint256 sharesToBurn) — requires not paused, not blacklisted, onlyWhitelisted

createLoan(bytes32 ref, address merchant, uint256 principal, uint256 fee, uint256 depositAmount, address borrower, uint256 maturitySeconds) — onlyCreditOfficer

repayLoan(bytes32 ref, uint256 amount)

repayLoanWithPermit(bytes32 loanRef, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)

withdrawMerchantFund()

markDefault(bytes32 ref) — onlyCreditOfficer

writeOffLoan(bytes32 ref) — onlyOwner

setFeeRate(uint256 platformFeeRate, uint256 lenderFeeRate, uint256 bp) — onlyAdmin

setReserveRateBP(uint256 bp) — onlyOwner

nav() / _nav() — poolCash + totalPrincipalOutstanding + reserveBalance

sharePrice() — (nav * 1e18) / totalSupply

view helpers: getLoan, getLoans, fetchDashboardView, fetchRateSettings, getVaultBalance, etc.

Events

Key events emitted by the contract:

LoanCreated

LoanDisbursed

LoanRepaid

LoanClosed

LoanDefaulted

LoanWrittenOff

Deposited

Withdrawn

MerchantWithdrawn

FeesWithdrawn

PlatformFeeWithdrawn

Paused, Unpaused, Whitelisted, Blacklisted, FeeRateChanged, DepositContributionChanged, MinimumCreditScoreChanged

Timelock related: TimelockCreated, TimelockExecuted

Calculations & formulas

NAV: NAV = poolCash + totalPrincipalOutstanding + reserveBalance

Share price: if totalSupply == 0 => 1e18; else (NAV * 1e18) / totalSupply

Platform fee / Lender fee (examples in code):

During loan creation: platformFee = (principal * _platformFeeRate) / BP_DIVISOR; (note: unit depends on _platformFeeRate)

During repayment: platformFee = (amount * _platformFeeRate) / 1e6; ← inconsistency (see Security notes)

Reserve cut: reserveCut = (lenderFeeEarn * reserveRateBP) / BP_DIVISOR

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
