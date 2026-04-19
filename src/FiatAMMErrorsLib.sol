// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================
// AMMErrorsLib — Custom errors for FiatStablecoinAMMV2
// Replaces all require() string messages to reduce contract size
// =============================================================

error NotWhitelisted();
error SwapsPausedError();
error PriceStale();
error InvalidToken();
error ZeroAddress();
error ZeroAmount();
error ZeroShares();
error BelowMinTradeUSD();
error BelowMinTradeLCY();
error BelowMinSlippage();
error ZeroOutput();
error InsufficientUSDPool();
error InsufficientLCYPool();
error PoolCapExceeded();
error InsufficientBuffer();
error EpochUSDCapExceeded();
error EpochLCYCapExceeded();
error SwapTooLarge();
error OneTradePerBlock();
error FeeRoundsToZero();
error BadNonce();
error TxExpired();
error BadSignature();
error NoPendingPrice();
error DelayNotElapsed();
error SignerNotWhitelisted();
error VaultNotSet();
error NotPendingTreasury();
error NotPendingOracle();
error NotPaused();
error PriceMustExceedSpread();
error PriceOutOfBounds();
error FeeVaultNotContract();
error FeeTooHigh();
error ZeroFeeRate();
error ExceedsDenom();
error InvalidAge();
error InvalidDelay();
error InvalidWindow();
error SwapCapBelowMin();
error SwapCapAboveMax();
error ZeroDuration();
error DurationExceedsMax();
error CooldownActive();
error LiquidityNotRecovered();
error InsufficientShares();
error ZeroSharesForToken();
error ZeroWithdrawal();
error PoolTooSmall();
error SpreadTooLarge();
error RangeError();
error RangeTooWide();
error MinTradeTooSmall();
error LCYMusBe6Decimals();
error USDMustBe6Decimals();
