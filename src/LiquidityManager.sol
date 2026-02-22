// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import './ISwapRouter.sol';
import './TransferHelper.sol';
import './IUniswapV3SwapCallback.sol';

interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external;
}


contract LiquidityManager is EIP712,ReentrancyGuard {

    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    bytes32 public constant META_SWAP_TYPEHASH = keccak256(
        "MetaSwap("
            "address signer,"
            "address tokenIn,"
            "address tokenOut,"
            "uint24 fee,"
            "uint256 amountIn,"
            "uint256 amountOutMinimum,"
            "address recipient,"
            "uint256 nonce,"
            "uint256 deadline"
        ")"
    );
    mapping(address => uint256) public nonces;

    ISwapRouter  public immutable swapRouter;
    //IQuoterV2    public immutable quoter;
    bytes32 public immutable DOMAIN_SEPARATOR;
    
    // Wallet owner
    address public owner;
    address public systemAdmin;

    event Swapped(
        address indexed signer,
        address indexed relayer,        // address(0) for direct swaps
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address _owner, address _swapRouter, address _quoter) EIP712("LiquidityManager", "1") {
        owner = _owner;
        
        //quoter = IQuoterV2(_quoter);

        require(_swapRouter != address(0), "zero swapRouter");
        require(_quoter     != address(0), "zero quoter");

        swapRouter = ISwapRouter(_swapRouter);

        // Build EIP-712 domain once at deploy time
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256(
                "EIP712Domain("
                    "string name,"
                    "string version,"
                    "uint256 chainId,"
                    "address verifyingContract"
                ")"
            ),
            keccak256(bytes("LiquidityManager")),
            keccak256(bytes("1")),
            _chainId(),
            address(this)
        ));
    
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

     function exactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        amountOut = _exactInputSingle(
            msg.sender, tokenIn, tokenOut, fee,
            amountIn, amountOutMinimum, recipient
        );
        emit Swapped(msg.sender, address(0), tokenIn, tokenOut, fee, amountIn, amountOut);
    }


    function exactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountOut,
        uint256 amountInMaximum,
        address recipient
    ) external nonReentrant returns (uint256 amountIn) {
        amountIn = _exactOutputSingle(
            msg.sender, tokenIn, tokenOut, fee,
            amountOut, amountInMaximum, recipient
        );
    }

    function metaExactInputSingle(
        address signer,
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external nonReentrant returns (uint256 amountOut) {
        require(block.timestamp <= deadline, "signature expired");

        _verifySignature(
            signer, tokenIn, tokenOut, fee,
            amountIn, amountOutMinimum, recipient,
            deadline, v, r, s
        );

        amountOut = _exactInputSingle(
            signer, tokenIn, tokenOut, fee,
            amountIn, amountOutMinimum, recipient
        );

        emit Swapped(signer, msg.sender, tokenIn, tokenOut, fee, amountIn, amountOut);
    }


    function metaExactInputSingleWithPermit(
        address signer,
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 permitDeadline,
        uint8 pV, bytes32 pR, bytes32 pS,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external nonReentrant returns (uint256 amountOut) {
        require(block.timestamp <= deadline, "signature expired");

        // Step 1 — apply ERC-2612 permit (skips gracefully if unsupported)
        try IERC20Permit(tokenIn).permit(
            signer, address(this), amountIn, permitDeadline, pV, pR, pS
        ) {} catch {}

        // Step 2 — verify MetaSwap EIP-712 signature
        _verifySignature(
            signer, tokenIn, tokenOut, fee,
            amountIn, amountOutMinimum, recipient,
            deadline, v, r, s
        );

        // Step 3 — execute swap, pulling tokens from signer
        amountOut = _exactInputSingle(
            signer, tokenIn, tokenOut, fee,
            amountIn, amountOutMinimum, recipient
        );

        emit Swapped(signer, msg.sender, tokenIn, tokenOut, fee, amountIn, amountOut);
    }

    function getNonce(address account) external view returns (uint256) {
        return nonces[account];
    }

    function _exactInputSingle(
        address from,
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient
    ) internal returns (uint256 amountOut) {
        require(tokenIn  != address(0), "zero tokenIn");
        require(tokenOut != address(0), "zero tokenOut");
        require(tokenIn  != tokenOut,   "identical tokens");
        require(amountIn  > 0,          "zero amountIn");
        require(recipient != address(0),"zero recipient");

        // Pull tokenIn from signer/caller into this contract
        TransferHelper.safeTransferFrom(tokenIn, from, address(this), amountIn);

        // Approve the Uniswap V3 router to spend tokenIn
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountIn);

        // Build params struct — identical to official Uniswap V3 example
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee,
                recipient:         recipient,       // tokenOut goes directly here
                deadline:          block.timestamp,
                amountIn:          amountIn,
                amountOutMinimum:  amountOutMinimum,
                sqrtPriceLimitX96: 0               // no price limit
            });

        // Execute the swap via the official Uniswap V3 router
        amountOut = swapRouter.exactInputSingle(params);
    }

    function _exactOutputSingle(
        address from,
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountOut,
        uint256 amountInMaximum,
        address recipient
    ) internal returns (uint256 amountIn) {
        require(tokenIn  != address(0),  "zero tokenIn");
        require(tokenOut != address(0),  "zero tokenOut");
        require(tokenIn  != tokenOut,    "identical tokens");
        require(amountOut > 0,           "zero amountOut");
        require(recipient != address(0), "zero recipient");

        // Pull maximum tokenIn from caller
        TransferHelper.safeTransferFrom(tokenIn, from, address(this), amountInMaximum);

        // Approve router for the maximum
        TransferHelper.safeApprove(tokenIn, address(swapRouter), amountInMaximum);

        ISwapRouter.ExactOutputSingleParams memory params =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn:          tokenIn,
                tokenOut:         tokenOut,
                fee:              fee,
                recipient:        recipient,
                deadline:         block.timestamp,
                amountOut:        amountOut,
                amountInMaximum:  amountInMaximum,
                sqrtPriceLimitX96: 0
            });

        // Execute — returns the actual tokenIn spent
        amountIn = swapRouter.exactOutputSingle(params);

        // Refund unspent tokenIn back to caller (same as official example)
        if (amountIn < amountInMaximum) {
            TransferHelper.safeApprove(tokenIn, address(swapRouter), 0);
            TransferHelper.safeTransfer(tokenIn, from, amountInMaximum - amountIn);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal — EIP-712 signature verification
    // ─────────────────────────────────────────────────────────────────────────
    function _verifySignature(
        address signer,
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) internal {
        bytes32 structHash = keccak256(abi.encode(
            META_SWAP_TYPEHASH,
            signer,
            tokenIn,
            tokenOut,
            fee,
            amountIn,
            amountOutMinimum,
            recipient,
            nonces[signer]++,   // consumes nonce — prevents replay attacks
            deadline
        ));

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0) && recovered == signer, "invalid signature");
    }

    // Inline chainId helper — assembly required in Solidity 0.7.x
    function _chainId() internal view returns (uint256 id) {
        assembly { id := chainid() }
    }
}