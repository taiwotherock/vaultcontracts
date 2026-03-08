// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FiatStablecoinAMM is Ownable, ReentrancyGuard, EIP712 {

    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // -------------------------------------------------------
    // TOKENS
    // -------------------------------------------------------

    IERC20 public immutable cNGN;
    IERC20 public immutable USD;

    address public platformTreasury;

    // -------------------------------------------------------
    // NONCES (META-TX)
    // -------------------------------------------------------

    mapping(address => uint256) public nonces;

    // -------------------------------------------------------
    // EIP712 TYPEHASH
    // -------------------------------------------------------

    bytes32 public constant SWAP_NGN_TYPEHASH =
        keccak256("SwapNGN(address signer,uint256 ngnAmount,uint256 minUSD,uint256 nonce,uint256 deadline)");

    bytes32 public constant SWAP_USD_TYPEHASH =
        keccak256("SwapUSD(address signer,uint256 usdAmount,uint256 minNGN,uint256 nonce,uint256 deadline)");

    bytes32 public constant ADD_LP_TYPEHASH =
        keccak256("AddLP(address signer,address token,uint256 amount,uint256 nonce,uint256 deadline)");

    bytes32 public constant REMOVE_LP_TYPEHASH =
        keccak256("RemoveLP(address signer,address token,uint256 shares,uint256 nonce,uint256 deadline)");

    bytes32 public constant CLAIM_LP_TYPEHASH =
        keccak256("ClaimLP(address signer,address token,uint256 nonce,uint256 deadline)");

    // -------------------------------------------------------
    // PRICE
    // -------------------------------------------------------

    uint256 public midPrice;
    uint256 public halfSpread = 2e18;

    uint256 public buyRate;
    uint256 public sellRate;

    // -------------------------------------------------------
    // FEES
    // -------------------------------------------------------

    uint256 public constant FEE_DENOM = 10000;

    uint256 public swapFeeBps = 30;
    uint256 public lpShareBps = 7000;
    uint256 public platformShareBps = 3000;

    mapping(address => uint256) public lpFeePool;

    // -------------------------------------------------------
    // LP ACCOUNTING
    // -------------------------------------------------------

    mapping(address => uint256) public totalLPShares;
    mapping(address => mapping(address => uint256)) public lpShares;

    // -------------------------------------------------------
    // LIMIT
    // -------------------------------------------------------

    uint256 public constant MAX_WITHDRAW_BPS = 2000;

    // -------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------

    event Swap(address user,uint256 inAmount,uint256 outAmount,bool meta);
    event LiquidityAdded(address lp,uint256 amount,uint256 shares,bool meta);
    event LiquidityRemoved(address lp,uint256 amount,uint256 shares,bool meta);
    event LPFeeClaimed(address lp,address token,uint256 amount);

    event MetaTxExecuted(address signer,address relayer,bytes32 typehash,uint256 nonce);

    // -------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------

    constructor(
        address _cNGN,
        address _USD,
        address _treasury
    )
        Ownable(msg.sender)
        EIP712("FiatStablecoinAMM","1")
    {
        require(_cNGN!=address(0)&&_USD!=address(0)&&_treasury!=address(0));

        cNGN=IERC20(_cNGN);
        USD=IERC20(_USD);

        platformTreasury=_treasury;
    }

    // -------------------------------------------------------
    // PRICE MANAGEMENT
    // -------------------------------------------------------

    function setPrice(uint256 price) external onlyOwner {

        require(price>0);

        midPrice=price;

        buyRate=midPrice+halfSpread;
        sellRate=midPrice-halfSpread;
    }

    // -------------------------------------------------------
    // DIRECT SWAP
    // -------------------------------------------------------

    function swapNGNtoUSD(
        uint256 ngnAmount,
        uint256 minUSD
    )
        external
        nonReentrant
    {
        _swapNGN(msg.sender,ngnAmount,minUSD,false);
    }

    function swapUSDtoNGN(
        uint256 usdAmount,
        uint256 minNGN
    )
        external
        nonReentrant
    {
        _swapUSD(msg.sender,usdAmount,minNGN,false);
    }

    // -------------------------------------------------------
    // META SWAP
    // -------------------------------------------------------

    function metaSwapNGNtoUSD(
        address signer,
        uint256 ngnAmount,
        uint256 minUSD,
        uint256 nonce,
        uint256 deadline,
        uint8 v,bytes32 r,bytes32 s
    )
        external
        nonReentrant
    {

        _verifyDeadline(deadline);
        _verifyNonce(signer,nonce);

        bytes32 structHash=keccak256(
            abi.encode(
                SWAP_NGN_TYPEHASH,
                signer,
                ngnAmount,
                minUSD,
                nonce,
                deadline
            )
        );

        _verifySig(signer,structHash,v,r,s);

        nonces[signer]++;

        emit MetaTxExecuted(signer,msg.sender,SWAP_NGN_TYPEHASH,nonce);

        _swapNGN(signer,ngnAmount,minUSD,true);
    }

    function metaSwapUSDtoNGN(
        address signer,
        uint256 usdAmount,
        uint256 minNGN,
        uint256 nonce,
        uint256 deadline,
        uint8 v,bytes32 r,bytes32 s
    )
        external
        nonReentrant
    {

        _verifyDeadline(deadline);
        _verifyNonce(signer,nonce);

        bytes32 structHash=keccak256(
            abi.encode(
                SWAP_USD_TYPEHASH,
                signer,
                usdAmount,
                minNGN,
                nonce,
                deadline
            )
        );

        _verifySig(signer,structHash,v,r,s);

        nonces[signer]++;

        emit MetaTxExecuted(signer,msg.sender,SWAP_USD_TYPEHASH,nonce);

        _swapUSD(signer,usdAmount,minNGN,true);
    }

    // -------------------------------------------------------
    // SWAP INTERNAL
    // -------------------------------------------------------

    function _swapNGN(
        address user,
        uint256 ngnAmount,
        uint256 minUSD,
        bool meta
    )
        internal
    {

        uint256 gross=(ngnAmount*1e6)/sellRate;

        (uint256 fee,uint256 lpFee,uint256 platformFee)=_calcFee(gross);

        uint256 net=gross-fee;

        require(net>=minUSD,"slippage");

        uint256 pool=USD.balanceOf(address(this));

        require(net<=pool*MAX_WITHDRAW_BPS/10000,"pool cap");

        cNGN.safeTransferFrom(user,address(this),ngnAmount);

        lpFeePool[address(USD)]+=lpFee;

        USD.safeTransfer(user,net);

        USD.safeTransfer(platformTreasury,platformFee);

        emit Swap(user,ngnAmount,net,meta);
    }

    function _swapUSD(
        address user,
        uint256 usdAmount,
        uint256 minNGN,
        bool meta
    )
        internal
    {

        uint256 gross=(usdAmount*buyRate)/1e6;

        (uint256 fee,uint256 lpFee,uint256 platformFee)=_calcFee(gross);

        uint256 net=gross-fee;

        require(net>=minNGN,"slippage");

        uint256 pool=cNGN.balanceOf(address(this));

        require(net<=pool*MAX_WITHDRAW_BPS/10000,"pool cap");

        USD.safeTransferFrom(user,address(this),usdAmount);

        lpFeePool[address(cNGN)]+=lpFee;

        cNGN.safeTransfer(user,net);

        cNGN.safeTransfer(platformTreasury,platformFee);

        emit Swap(user,usdAmount,net,meta);
    }

    // -------------------------------------------------------
    // LP META
    // -------------------------------------------------------

    function metaAddLiquidity(
        address signer,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint8 v,bytes32 r,bytes32 s
    )
        external
        nonReentrant
    {

        _verifyDeadline(deadline);
        _verifyNonce(signer,nonce);

        bytes32 structHash=keccak256(
            abi.encode(
                ADD_LP_TYPEHASH,
                signer,
                token,
                amount,
                nonce,
                deadline
            )
        );

        _verifySig(signer,structHash,v,r,s);

        nonces[signer]++;

        emit MetaTxExecuted(signer,msg.sender,ADD_LP_TYPEHASH,nonce);

        _addLiquidity(signer,token,amount,true);
    }

    function metaRemoveLiquidity(
        address signer,
        address token,
        uint256 shares,
        uint256 nonce,
        uint256 deadline,
        uint8 v,bytes32 r,bytes32 s
    )
        external
        nonReentrant
    {

        _verifyDeadline(deadline);
        _verifyNonce(signer,nonce);

        bytes32 structHash=keccak256(
            abi.encode(
                REMOVE_LP_TYPEHASH,
                signer,
                token,
                shares,
                nonce,
                deadline
            )
        );

        _verifySig(signer,structHash,v,r,s);

        nonces[signer]++;

        emit MetaTxExecuted(signer,msg.sender,REMOVE_LP_TYPEHASH,nonce);

        _removeLiquidity(signer,token,shares,true);
    }

    // -------------------------------------------------------
    // LP CORE
    // -------------------------------------------------------

    function _addLiquidity(
        address lp,
        address token,
        uint256 amount,
        bool meta
    )
        internal
    {

        uint256 pool=IERC20(token).balanceOf(address(this));

        uint256 shares;

        if(totalLPShares[token]==0) shares=amount;
        else shares=(amount*totalLPShares[token])/pool;

        totalLPShares[token]+=shares;
        lpShares[token][lp]+=shares;

        IERC20(token).safeTransferFrom(lp,address(this),amount);

        emit LiquidityAdded(lp,amount,shares,meta);
    }

    function _removeLiquidity(
        address lp,
        address token,
        uint256 shares,
        bool meta
    )
        internal
    {

        require(lpShares[token][lp]>=shares,"shares");

        uint256 pool=IERC20(token).balanceOf(address(this));

        uint256 amount=(shares*pool)/totalLPShares[token];

        lpShares[token][lp]-=shares;
        totalLPShares[token]-=shares;

        IERC20(token).safeTransfer(lp,amount);

        emit LiquidityRemoved(lp,amount,shares,meta);
    }

    // -------------------------------------------------------
    // CLAIM LP FEE
    // -------------------------------------------------------

    function claimLPFee(address token) external nonReentrant {

        _claimLP(msg.sender,token);
    }

    function metaClaimLPFee(
        address signer,
        address token,
        uint256 nonce,
        uint256 deadline,
        uint8 v,bytes32 r,bytes32 s
    )
        external
        nonReentrant
    {

        _verifyDeadline(deadline);
        _verifyNonce(signer,nonce);

        bytes32 structHash=keccak256(
            abi.encode(
                CLAIM_LP_TYPEHASH,
                signer,
                token,
                nonce,
                deadline
            )
        );

        _verifySig(signer,structHash,v,r,s);

        nonces[signer]++;

        emit MetaTxExecuted(signer,msg.sender,CLAIM_LP_TYPEHASH,nonce);

        _claimLP(signer,token);
    }

    function _claimLP(address lp,address token) internal {

        uint256 shares=lpShares[token][lp];
        uint256 total=totalLPShares[token];

        if(shares==0||total==0) return;

        uint256 pool=lpFeePool[token];

        uint256 claim=(pool*shares)/total;

        if(claim==0) return;

        lpFeePool[token]-=claim;

        IERC20(token).safeTransfer(lp,claim);

        emit LPFeeClaimed(lp,token,claim);
    }

    // -------------------------------------------------------
    // FEES
    // -------------------------------------------------------

    function _calcFee(uint256 amount)
        internal
        view
        returns(uint256 total,uint256 lpFee,uint256 platformFee)
    {

        total=(amount*swapFeeBps)/FEE_DENOM;

        lpFee=(total*lpShareBps)/FEE_DENOM;

        platformFee=total-lpFee;
    }

    // -------------------------------------------------------
    // META HELPERS
    // -------------------------------------------------------

    function _verifyDeadline(uint256 deadline) internal view {

        require(block.timestamp<=deadline,"expired");
    }

    function _verifyNonce(address signer,uint256 nonce) internal view {

        require(nonces[signer]==nonce,"nonce");
    }

    function _verifySig(
        address signer,
        bytes32 structHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        internal
        view
    {

        bytes32 digest=_hashTypedDataV4(structHash);

        address recovered=ECDSA.recover(digest,v,r,s);

        require(recovered==signer,"sig");
    }

}