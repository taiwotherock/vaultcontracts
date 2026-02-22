// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract SmartWalletEOA {

    // -----------------------------------------------------------------------
    // Storage  (all lives in the EOA's storage via EIP-7702 delegation)
    // -----------------------------------------------------------------------

    /// @notice Replay-protection nonce for execute().
    uint256 public nonce;

    /// @notice USDT contract address — set once in the constructor.
    address public usdtToken;

    address public admin;

    /// @notice Total USDT deposited through this delegate (in USDT decimals = 6).
    uint256 public totalDeposited;

    /// @notice Deposit record keyed by reference number (bytes32 hash).
    mapping(bytes32 => DepositRecord) public deposits;

    /// @notice All reference numbers deposited by a given EOA.
    mapping(address => bytes32[]) public depositsByEOA;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error InvalidSignature();
    error WrongNonce(uint256 expected, uint256 got);
    error CallFailed(uint256 index, bytes returnData);
    error ZeroAmount();
    error ReferenceAlreadyUsed(bytes32 ref);
    error NotOwner();
    error InsufficientBalance(uint256 available, uint256 requested);
    error TransferFailed();
    error InvalidReference();

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event Executed(address indexed sponsor, address indexed owner, uint256 nonce);

    /// @notice Emitted when USDT is deposited with a reference number.
    event UsdtDeposited(
        address indexed depositor,   // validated EOA
        bytes32 indexed refNumber,     // keccak256 of the reference string
        uint256 amount,              // in USDT (6 decimals)
        uint256 timestamp
    );

    /// @notice Emitted when USDT is withdrawn by the owner.
    event UsdtWithdrawn(address indexed to, uint256 amount);

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    struct Call {
        address to;
        uint256 value;
        bytes   data;
    }

    struct DepositRecord {
        address depositor;    // EOA that made the deposit (validated)
        bytes32  refNumber;    // keccak256 of the reference string
        uint256 amount;       // USDT amount (6 decimals)
        uint256 timestamp;    // block.timestamp
        bool    exists;       // guard against zero-value lookup
    }

    // -----------------------------------------------------------------------
    // EIP-712 — for execute() batch signing
    // -----------------------------------------------------------------------

    bytes32 private constant CALL_TYPEHASH =
        keccak256("Call(address to,uint256 value,bytes data)");

    bytes32 private constant EXECUTE_TYPEHASH =
        keccak256(
            "Execute(Call[] calls,uint256 nonce)"
            "Call(address to,uint256 value,bytes data)"
        );

    // EIP-712 type for depositUsdt() signature
    bytes32 private constant DEPOSIT_TYPEHASH =
        keccak256(
            "Deposit(address depositor,bytes32 refNumber,uint256 amount,uint256 deadline)"
        );

    constructor(address _usdtToken,address _admin) {
        require(_usdtToken != address(0), "Invalid USDT address");
        require(_admin != address(0), "Invalid admin address");
        usdtToken = _usdtToken;
        admin = _admin;
    }

    // -----------------------------------------------------------------------
    // EOA Validation helper
    // -----------------------------------------------------------------------

    /**
     * @notice Validate that a signature was produced by `expectedSigner`.
     * @dev    Used internally and also callable externally to pre-validate
     *         an EOA before accepting a deposit.
     *
     * @param  digest          EIP-712 or arbitrary hash the signer signed.
     * @param  expectedSigner  The EOA address we expect to have signed.
     * @param  v, r, s         ECDSA signature components.
     * @return valid           True if the recovered signer matches.
     */
    function validateEOA(
        bytes32 digest,
        address expectedSigner,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) public pure returns (bool valid) {
        if (expectedSigner == address(0)) return false;
        address recovered = ecrecover(digest, v, r, s);
        return recovered == expectedSigner;
    }

    /**
     * @notice Build the EIP-712 digest for a deposit authorisation.
     * @dev    Off-chain: sign this digest with the EOA's private key before
     *         calling depositUsdt().
     */
    function getDepositDigest(
        address depositor,
        bytes32 refNumber,
        uint256 amount,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                DEPOSIT_TYPEHASH,
                depositor,
                refNumber,
                amount,
                deadline
            )
        );
        return keccak256(
            abi.encodePacked("\x19\x01", domainSeparator(), structHash)
        );
    }

    // -----------------------------------------------------------------------
    // USDT Deposit
    // -----------------------------------------------------------------------

    /**
     * @notice Deposit USDT with a reference number.
     *
     * @param  refNumber  Human-readable payment reference (e.g. "INV-2024-001").
     * @param  amount     USDT amount to deposit (6 decimals, e.g. 100e6 = $100).
     * @param  deadline   Unix timestamp after which the signature expires.
     * @param  v, r, s    ECDSA signature from the EOA authorising this deposit.
     *
     * Flow:
     *   1. Caller provides a signature proving the EOA approved this exact
     *      deposit (amount + reference + deadline).
     *   2. Contract validates the signature against msg.sender (the EOA).
     *   3. Reference number is checked for uniqueness.
     *   4. USDT is pulled from msg.sender via transferFrom.
     *   5. Deposit record is stored and event emitted.
     *
     * The EOA must have called USDT.approve(address(this), amount) first.
     */
    function depositUsdt(
        bytes32 refNumber,
        uint256 amount,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        // --- basic checks ---
        if (amount == 0)                    revert ZeroAmount();
        if (refNumber == bytes32(0))        revert InvalidReference();
        if (block.timestamp > deadline)     revert InvalidSignature(); // expired

        // --- validate EOA signature ---
        // The depositor (msg.sender) must have signed a digest approving
        // exactly this (refNumber, amount, deadline) tuple.
        bytes32 digest = getDepositDigest(msg.sender, refNumber, amount, deadline);
        if (!validateEOA(digest, msg.sender, v, r, s)) revert InvalidSignature();

        // --- uniqueness check ---
        if (deposits[refNumber].exists) revert ReferenceAlreadyUsed(refNumber);

        // --- pull USDT from the EOA ---
        _safeTransferFrom(usdtToken, msg.sender, address(this), amount);

        // --- record the deposit ---
        deposits[refNumber] = DepositRecord({
            depositor: msg.sender,
            refNumber: refNumber,
            amount:    amount,
            timestamp: block.timestamp,
            exists:    true
        });

        depositsByEOA[msg.sender].push(refNumber);
        totalDeposited += amount;

        emit UsdtDeposited(msg.sender, refNumber, amount, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Deposit lookup
    // -----------------------------------------------------------------------

    /**
     * @notice Retrieve a deposit record by its reference number string.
     * @param  refNumber  The original reference string (e.g. "INV-2024-001").
     */
    function getDeposit(bytes32 refNumber)
        external
        view
        returns (DepositRecord memory)
    {
        require(deposits[refNumber].exists, "Deposit not found");
        return deposits[refNumber];
    }

    /**
     * @notice Retrieve all reference hashes deposited by a specific EOA.
     */
    function getDepositsByEOA(address depositor)
        external
        view
        returns (bytes32[] memory)
    {
        return depositsByEOA[depositor];
    }

    // -----------------------------------------------------------------------
    // Withdraw (owner only — validated via EIP-7702 delegation)
    // -----------------------------------------------------------------------

    /**
     * @notice Withdraw USDT from this delegate account.
     * @dev    Because this runs via EIP-7702 delegation, address(this) == EOA.
     *         Only the EOA itself can trigger this through execute(), which
     *         already validates the EOA's signature. Alternatively call
     *         directly if the EOA is the msg.sender.
     *
     * @param  to      Recipient address.
     * @param  amount  USDT amount to withdraw (6 decimals).
     */
    function withdrawUsdt(address to, uint256 amount) external {
        
        if (msg.sender != admin) revert NotOwner();

        uint256 bal = IERC20(usdtToken).balanceOf(address(this));
        if (amount > bal) revert InsufficientBalance(bal, amount);

        _safeTransfer(usdtToken, to, amount);
        emit UsdtWithdrawn(to, amount);
    }

    // -----------------------------------------------------------------------
    // EIP-712 domain + helpers (for execute batch)
    // -----------------------------------------------------------------------

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("SmartWalletEOA"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function _hashCall(Call memory c) private pure returns (bytes32) {
        return keccak256(
            abi.encode(CALL_TYPEHASH, c.to, c.value, keccak256(c.data))
        );
    }

    function _hashCalls(Call[] memory calls) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; i++) hashes[i] = _hashCall(calls[i]);
        return keccak256(abi.encodePacked(hashes));
    }

    function getDigest(Call[] memory calls, uint256 _nonce)
        public view returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator(),
                keccak256(abi.encode(EXECUTE_TYPEHASH, _hashCalls(calls), _nonce))
            )
        );
    }

    // -----------------------------------------------------------------------
    // Execute batch (gasless — called by sponsor)
    // -----------------------------------------------------------------------

    function execute(
        Call[] calldata calls,
        uint256 _nonce,
        uint8  v,
        bytes32 r,
        bytes32 s
    ) external payable {
        if (_nonce != nonce) revert WrongNonce(nonce, _nonce);

        bytes32 digest = getDigest(calls, _nonce);
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != address(this)) revert InvalidSignature();

        nonce++;

        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].to.call{value: calls[i].value}(
                calls[i].data
            );
            if (!ok) revert CallFailed(i, ret);
        }

        emit Executed(msg.sender, address(this), _nonce);
    }

    // -----------------------------------------------------------------------
    // Safe ERC-20 transfer helpers
    // (handles non-standard USDT that doesn't return bool on mainnet)
    // -----------------------------------------------------------------------

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    receive() external payable {}
}
