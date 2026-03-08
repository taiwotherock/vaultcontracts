// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  BFPay — Borderless Fuse Pay
 * @notice B2B cross-border lending protocol with correct integrations:
 *
 *  ✅ USYC via Hashnote Teller contract
 *     - deposit: teller.deposit(usdcAmount, receiver) → returns usycShares
 *     - redeem:  teller.redeem(usycShares, receiver, account) → returns usdcOut
 *     - Teller testnet: 0x96424C885951ceb4B79fecb934eD857999e6f82B
 *     - USYC testnet:   0x38D3A3f8717F4DB1CcB4Ad7D8C755919440848A3
 *     - USDC testnet:   0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
 *
 *  ✅ StableFX is a Circle REST API — NOT an onchain contract
 *     - Rate is obtained offchain via POST /v1/exchange/stablefx/quotes
 *     - Trade is executed via POST /v1/exchange/stablefx/trades
 *     - Funded via EIP-712 Permit2 signatures
 *     - BFPay oracle writes the locked rate onchain after the API call
 *     - The rate written here becomes the immutable reference for this deal
 *
 *  ✅ JNVA fiat collateral attested by oracle (GBP/USD/EUR stays offchain)
 *  ✅ Health factor computed onchain every 60s
 *  ✅ Margin call → 4hr grace → liquidation state machine
 */

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @notice Hashnote USYC Teller — the real subscribe/redeem interface
 * @dev    Teller testnet: 0x96424C885951ceb4B79fecb934eD857999e6f82B
 *
 *         deposit: send USDC → receive USYC shares
 *         redeem:  send USYC shares → receive USDC + accrued yield
 */
interface ITeller {
    /**
     * @notice Subscribe USDC to receive USYC
     * @param _assets   USDC amount (6 decimals) e.g. 100 * 1e6 = $100
     * @param _receiver Address that will receive the USYC tokens
     * @return          USYC shares minted
     */
    function deposit(uint256 _assets, address _receiver) external returns (uint256);

    /**
     * @notice Redeem USYC shares back to USDC
     * @param _shares   USYC amount to redeem
     * @param _receiver Address that will receive the USDC payout
     * @param _account  Address that currently holds the USYC shares
     * @return          USDC returned (original + accrued yield)
     */
    function redeem(
        uint256 _shares,
        address _receiver,
        address _account
    ) external returns (uint256);
}

// ─── Contract ─────────────────────────────────────────────────────────────────

contract B2BLending4 {

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant PRECISION   = 1e18;
    uint256 public constant USDC_DEC    = 1e6;
    uint256 public constant MAX_FEE_BPS = 30;  // 0.30%/day max

    // ── Testnet addresses (Hashnote + USDC) ───────────────────────────────────
    // Override via setAddresses() for mainnet deployment
    address public teller   = 0x96424C885951ceb4B79fecb934eD857999e6f82B;
    address public usyc     = 0x38D3A3f8717F4DB1CcB4Ad7D8C755919440848A3;
    address public usdc     = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    // ── Enums ─────────────────────────────────────────────────────────────────
    enum DealStatus  { OPEN, MATCHED, ACTIVE, REPAID, LIQUIDATED }
    enum RfqType  { LEND,BORROW }
    enum CollType    { USYC, USDC_ONLY, GBP_FIAT, USD_FIAT, EUR_FIAT }
    enum HealthState { HEALTHY, WARNING, MARGIN_CALL, LIQUIDATING }

    // ── Structs ───────────────────────────────────────────────────────────────

    /**
     * @dev Onchain collateral position.
     *      For USYC: usycShares held by this contract, deposited via Teller.
     *      For USDC_ONLY: raw USDC locked (no yield).
     *      For GBP/USD/EUR fiat: offchain JNVA — only attested value stored.
     */
    struct CollateralPosition {
        CollType collType;
        uint256  usycShares;       // USYC shares from teller.deposit()
        uint256  usdcLocked;       // USDC locked for USDC_ONLY deals
        uint256  usdcDepositedAmt; // original USDC deposited (for yield calc)
        uint256  depositedAt;
    }

    /**
     * @dev StableFX rate locked offchain and written onchain by oracle.
     *
     *      How it gets here:
     *      1. Backend calls POST /v1/exchange/stablefx/quotes
     *      2. Backend calls POST /v1/exchange/stablefx/trades → gets firm rate
     *      3. Oracle signs and calls writeFXRate() on this contract
     *      4. Rate is stored immutably per deal — used for all NGN calculations
     *
     *      stableFXTradeId: the Circle trade UUID stored for audit trail
     *      rateUsdc6:       how many NGN per 1 USDC, scaled × 1e6
     *                       e.g. 1,580 NGN/$  →  1_580_000_000
     */
    struct LockedFXRate {
        string  stableFXQuoteId;   // Circle quote UUID — audit trail
        string  stableFXTradeId;   // Circle trade UUID — audit trail
        uint256 rateUsdc6;         // NGN per USDC × 1e6
        uint256 lockedAt;
        bool    active;
    }

    struct RFQ {
        bytes32  id;
        address  borrower;
        uint256  amountNGN;      // whole Naira requested
        uint256  tenorDays;
        uint256  maxFeeBPS;      // borrower's ceiling
        CollType collateral;
        uint256  collateralUSD;  // USD × 1e6
        uint256  createdAt;
        RfqType  rfqType;
        bool     open;
    }

    struct Quote {
        bytes32 rfqId;
        address lender;
        uint256 feeBPS;
        uint256 validUntil;
        bool    accepted;
    }

    struct Deal {
        bytes32    id;
        bytes32    rfqId;
        address    borrower;
        address    lender;
        uint256    amountNGN;
        uint256    collateralUSD;  // USD × 1e6, updated live for USYC
        uint256    feeBPS;
        uint256    openedAt;
        uint256    tenorDays;
        uint256    healthFactor;   // × 1e18
        uint8      healthState;
        uint8      collType;
        DealStatus status;
        string     fiatPayoutRef;
        string     fiatRepayRef;
    }

    struct Attestation {
        bytes32 dealId;
        uint256 collateralUSD;    // USD × 1e6
        uint256 drawnNGN;
        uint256 yieldUSDC;        // yield accrued since deposit (1e6)
        uint256 netFeeNGN;        // gross fee minus yield offset in NGN
        uint256 healthFactor;     // × 1e18
        uint8   healthState;
        uint256 timestamp;
        address oracle;
    }

    // ── Protocol state ─────────────────────────────────────────────────────────
    address public owner;
    uint256 public ltvBPS      = 8000;  // 80% LTV
    uint256 public gracePeriod = 4 hours;
    uint256 public totalVolume;
    uint256 public totalDeals;
    uint256 public totalCollateral;
    uint256 public activeDealsTotal;
    uint256 public activeDealsCount;



    mapping(address  => bool)    public isOracle;
    mapping(address  => bool)    public isKYB;

    mapping(bytes32  => RFQ)     public rfqs;
    bytes32[]                    public rfqList;

    mapping(bytes32  => Quote[]) public quotes;
    mapping(bytes32  => Deal)    public deals;
    bytes32[]                    public dealList;

    mapping(bytes32  => CollateralPosition) public positions;
    mapping(bytes32  => LockedFXRate)       public fxRates;
    mapping(bytes32  => Attestation[])      public history;
    mapping(bytes32  => uint256)            public marginCallAt;
    mapping(address  => uint256)            public oracleNonce;

    // ── Events ────────────────────────────────────────────────────────────────
    event KYBApproved    (address indexed user);
    event RFQCreated     (bytes32 indexed id, address borrower, uint256 amountNGN, uint8 collType);
    event QuoteSubmitted (bytes32 indexed rfqId, address lender, uint256 feeBPS);
    event DealOpened     (bytes32 indexed dealId, address borrower, address lender);

    // USYC Teller events
    event USYCDeposited  (bytes32 indexed dealId, uint256 usdcIn, uint256 usycSharesReceived);
    event USYCRedeemed   (bytes32 indexed dealId, address recipient, uint256 usycShares, uint256 usdcOut);

    // USDC collateral events
    event USDCLocked     (bytes32 indexed dealId, uint256 amount);
    event USDCReleased   (bytes32 indexed dealId, address recipient, uint256 amount);

    // StableFX events — rate written onchain after offchain API call
    event FXRateWritten  (bytes32 indexed dealId, string quoteId, string tradeId, uint256 rateUsdc6);
    event YieldOffset    (bytes32 indexed dealId, uint256 yieldUSDC, uint256 yieldNGN, uint256 netFeeNGN);

    // Settlement events
    event PayoutConfirmed(bytes32 indexed dealId, string fiatRef);
    event Repaid         (bytes32 indexed dealId, string fiatRef);
    event Attested       (bytes32 indexed dealId, uint256 healthFactor, uint8 state);
    event MarginCall     (bytes32 indexed dealId, uint256 endsAt);
    event Liquidated     (bytes32 indexed dealId);

    // ── Modifiers ─────────────────────────────────────────────────────────────
    modifier onlyOwner()  { require(msg.sender == owner,  "BFP: not owner");  _; }
    modifier onlyOracle() { require(isOracle[msg.sender], "BFP: not oracle"); _; }
    modifier onlyKYB()    { require(isKYB[msg.sender],    "BFP: not KYB");    _; }

    constructor(address _usyc, address _usdc,address _teller,address _oracle) {
        teller = _teller;
        owner = msg.sender;
        usyc = _usyc;
        usdc = _usdc;
        isOracle[_oracle] = true;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION A — ADMIN
    // ══════════════════════════════════════════════════════════════════════════

    function addOracle(address _o)    external onlyOwner { isOracle[_o] = true; }
    function removeOracle(address _o) external onlyOwner { isOracle[_o] = false; }

    function approveKYB(address _u) external onlyOwner {
        isKYB[_u] = true;
        emit KYBApproved(_u);
    }

    function setLTV(uint256 _bps) external onlyOwner {
        require(_bps <= 9500, "BFP: LTV too high");
        ltvBPS = _bps;
    }

    /**
     * @notice Update Teller / USYC / USDC addresses for mainnet deployment
     * @param _teller  Hashnote Teller contract
     * @param _usyc    USYC ERC-20 token
     * @param _usdc    USDC ERC-20 token
     */
    function setAddresses(address _teller, address _usyc, address _usdc)
        external onlyOwner
    {
        teller = _teller;
        usyc   = _usyc;
        usdc   = _usdc;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION B — USYC DEPOSIT via Teller
    //
    //  Real Teller API:
    //    usdc.approve(teller, amount)
    //    uint256 shares = teller.deposit(amount, receiver)
    //
    //  USYC appreciates in value. shares × pricePerShare = current USDC value.
    //  Yield offsets the daily borrowing fee.
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit USDC → Teller mints USYC shares → locked in this contract
     *
     * @param _dealId       Matched deal to back with collateral
     * @param _usdcAmount   USDC to deposit (6 dec). e.g. 100_000 * 1e6 = $100K
     *
     * Requires: borrower has called usdc.approve(BFPay, _usdcAmount) first
     *
     * Flow:
     *   1. Pull USDC from borrower into BFPay
     *   2. BFPay approves Teller to spend USDC
     *   3. Call teller.deposit(usdcAmount, address(this))
     *      → Teller converts USDC → USYC shares, sends shares to BFPay
     *   4. Store usycShares per deal for later redemption
     */
    function depositUSYC(bytes32 _dealId, uint256 _usdcAmount) external onlyKYB {
        require(_usdcAmount > 0, "BFP: zero amount");

        Deal storage d = deals[_dealId];
        require(d.borrower == msg.sender,              "BFP: not borrower");
        require(d.status   == DealStatus.MATCHED,      "BFP: wrong status");
        require(d.collType == uint8(CollType.USYC),    "BFP: not USYC deal");
        require(positions[_dealId].usycShares == 0,    "BFP: already deposited");

        // 1. Pull USDC from borrower
        require(
            IERC20(usdc).transferFrom(msg.sender, address(this), _usdcAmount),
            "BFP: USDC pull failed"
        );

        // 2. Approve Teller to spend USDC
        IERC20(usdc).approve(teller, _usdcAmount);

        // 3. Teller.deposit → BFPay receives USYC shares
        //    Receiver is address(this) so shares stay in this contract
        uint256 sharesReceived = ITeller(teller).deposit(_usdcAmount, address(this));
        require(sharesReceived > 0, "BFP: Teller minted zero shares");

        // 4. Record position
        positions[_dealId] = CollateralPosition({
            collType:          CollType.USYC,
            usycShares:        sharesReceived,
            usdcLocked:        0,
            usdcDepositedAmt:  _usdcAmount,
            depositedAt:       block.timestamp
        });

        d.collateralUSD = _usdcAmount; // Initial value; updated by oracle attestation

        emit USYCDeposited(_dealId, _usdcAmount, sharesReceived);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION C — USYC REDEEM via Teller
    //
    //  Real Teller API:
    //    usyc.approve(teller, shares)  ← BFPay approves teller to pull its USYC
    //    uint256 usdcOut = teller.redeem(shares, receiver, account)
    //      receiver = who gets the USDC
    //      account  = who holds the USYC (address(this))
    //
    //  Called automatically on repayment. Can also be called manually by oracle.
    //  On REPAID  → USDC + yield goes to borrower
    //  On LIQUIDATED → USDC goes to lender as compensation
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Redeem USYC shares → USDC + yield via Teller
     *         Normally auto-triggered by confirmRepayment().
     *         Oracle can call directly for emergency releases.
     */
    function redeemUSYC(bytes32 _dealId) external onlyOracle {
        Deal storage d = deals[_dealId];
        require(
            d.status == DealStatus.REPAID || d.status == DealStatus.LIQUIDATED,
            "BFP: deal not settled"
        );
        _executeRedeem(_dealId);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION D — USDC COLLATERAL (raw, no yield)
    // ══════════════════════════════════════════════════════════════════════════

    function depositUSDCCollateral(bytes32 _dealId, uint256 _amount) external onlyKYB {
        Deal storage d = deals[_dealId];
        require(d.borrower == msg.sender,                "BFP: not borrower");
        require(d.status   == DealStatus.MATCHED,        "BFP: wrong status");
        require(d.collType == uint8(CollType.USDC_ONLY), "BFP: not USDC deal");

        require(
            IERC20(usdc).transferFrom(msg.sender, address(this), _amount),
            "BFP: USDC pull failed"
        );

        positions[_dealId] = CollateralPosition({
            collType:         CollType.USDC_ONLY,
            usycShares:       0,
            usdcLocked:       _amount,
            usdcDepositedAmt: _amount,
            depositedAt:      block.timestamp
        });

        d.collateralUSD = _amount;
        emit USDCLocked(_dealId, _amount);
    }

    function releaseUSDCCollateral(bytes32 _dealId) external onlyOracle {
        Deal storage d = deals[_dealId];
        require(d.status == DealStatus.REPAID, "BFP: not repaid");
        _releaseUSDC(_dealId, d.borrower);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION E — STABLEFX RATE (written onchain by oracle after API call)
    //
    //  StableFX is a Circle REST API — there is NO onchain StableFX contract
    //  to call directly from Solidity.
    //
    //  How the rate gets onchain:
    //  1. Backend (TypeScript) calls:
    //       POST /v1/exchange/stablefx/quotes  → gets quoteId + rate
    //       POST /v1/exchange/stablefx/trades  → creates trade, confirms rate
    //  2. Backend generates EIP-712 Permit2 signature to fund the trade
    //  3. Backend calls POST /v1/exchange/stablefx/fund to settle
    //  4. Oracle then calls writeFXRate() here to record the rate onchain
    //     This creates an immutable audit trail linking Circle's tradeId to the deal
    //
    //  rateUsdc6: NGN per 1 USDC, scaled × 1e6
    //             e.g. 1580 NGN per $1 USDC → rateUsdc6 = 1_580_000_000
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Oracle writes the StableFX locked rate onchain after the API trade is confirmed.
     *         This is the single source of truth for NGN/USDC conversion in this deal.
     *
     * @param _dealId         Deal being backed
     * @param _quoteId        Circle StableFX quote UUID (audit trail)
     * @param _tradeId        Circle StableFX trade UUID (audit trail)
     * @param _rateUsdc6      NGN per 1 USDC × 1e6
     * @param _nonce          Oracle replay-protection nonce
     * @param _sig            Oracle ECDSA signature
     */
    function writeFXRate(
        bytes32        _dealId,
        string calldata _quoteId,
        string calldata _tradeId,
        uint256        _rateUsdc6,
        uint256        _nonce,
        bytes calldata  _sig
    ) external onlyOracle {
        require(_rateUsdc6 > 0,              "BFP: zero rate");
        require(!fxRates[_dealId].active,    "BFP: rate already locked");
        require(_nonce == oracleNonce[msg.sender], "BFP: bad nonce");
        oracleNonce[msg.sender]++;

        // Verify oracle signed this exact payload
        bytes32 h = _prefixed(keccak256(abi.encodePacked(
            _dealId, _rateUsdc6, _nonce, block.chainid
        )));
        require(_recover(h, _sig) == msg.sender, "BFP: bad signature");

        fxRates[_dealId] = LockedFXRate({
            stableFXQuoteId: _quoteId,
            stableFXTradeId: _tradeId,
            rateUsdc6:       _rateUsdc6,
            lockedAt:        block.timestamp,
            active:          true
        });

        emit FXRateWritten(_dealId, _quoteId, _tradeId, _rateUsdc6);
    }

    /**
     * @notice Compute NGN credit line from locked StableFX rate
     *         creditNGN = (collateralUSD × rateUsdc6 × LTV) / (1e6 × 10000)
     */
    function getCreditLineNGN(bytes32 _dealId) external view returns (uint256 creditNGN) {
        Deal memory d     = deals[_dealId];
        LockedFXRate memory r = fxRates[_dealId];
        require(r.active, "BFP: no FX rate");
        // collateralUSD (1e6) × rateUsdc6 (1e6) = 1e12; divide out 1e12 and LTV divisor
        creditNGN = (d.collateralUSD * r.rateUsdc6 * ltvBPS) / (1e12 * 10000);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION F — RFQ
    // ══════════════════════════════════════════════════════════════════════════

    function createRFQ(
        uint256  _amountNGN,
        uint256  _tenorDays,
        uint256  _maxFeeBPS,
        CollType _collateral,
        uint256  _collateralUSD  // USD × 1e6
    ) external onlyKYB returns (bytes32 id) {
        require(_amountNGN > 0 && _tenorDays > 0, "BFP: invalid params");
        require(_maxFeeBPS <= MAX_FEE_BPS,         "BFP: fee too high");

        id = keccak256(abi.encodePacked(msg.sender, block.timestamp, _amountNGN));

        rfqs[id] = RFQ({
            id:            id,
            borrower:      msg.sender,
            amountNGN:     _amountNGN,
            tenorDays:     _tenorDays,
            maxFeeBPS:     _maxFeeBPS,
            collateral:    _collateral,
            collateralUSD: _collateralUSD,
            createdAt:     block.timestamp,
            open:          true,
            rfqType:       RfqType.BORROW
        });
        rfqList.push(id);
        emit RFQCreated(id, msg.sender, _amountNGN, uint8(_collateral));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION G — QUOTE
    // ══════════════════════════════════════════════════════════════════════════

    function submitQuote(bytes32 _rfqId, uint256 _feeBPS, uint256 _validSecs)
        external onlyKYB
    {
        RFQ storage rfq = rfqs[_rfqId];
        require(rfq.open,                  "BFP: RFQ closed");
        require(_feeBPS <= rfq.maxFeeBPS,  "BFP: fee exceeds ceiling");

        quotes[_rfqId].push(Quote({
            rfqId:      _rfqId,
            lender:     msg.sender,
            feeBPS:     _feeBPS,
            validUntil: block.timestamp + _validSecs,
            accepted:   false
        }));
        emit QuoteSubmitted(_rfqId, msg.sender, _feeBPS);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION H — ACCEPT QUOTE → opens Deal
    // ══════════════════════════════════════════════════════════════════════════

    function acceptQuote(bytes32 _rfqId, uint256 _idx)
        external
        returns (bytes32 dealId)
    {
        RFQ storage rfq = rfqs[_rfqId];
        Quote storage quote = quotes[_rfqId][_idx];

        require(msg.sender == rfq.borrower,          "BFP: not borrower");
        require(rfq.open,                            "BFP: RFQ closed");
        require(!quote.accepted,                     "BFP: already accepted");
        require(block.timestamp <= quote.validUntil, "BFP: quote expired");

        quote.accepted = true;
        rfq.open       = false;

        dealId = keccak256(abi.encodePacked(_rfqId, quote.lender, block.timestamp));

        deals[dealId] = Deal({
            id:            dealId,
            rfqId:         _rfqId,
            borrower:      rfq.borrower,
            lender:        quote.lender,
            amountNGN:     rfq.amountNGN,
            collateralUSD: rfq.collateralUSD,
            feeBPS:        quote.feeBPS,
            openedAt:      block.timestamp,
            tenorDays:     rfq.tenorDays,
            healthFactor:  PRECISION,
            healthState:   uint8(HealthState.HEALTHY),
            collType:      uint8(rfq.collateral),
            status:        DealStatus.MATCHED,
            fiatPayoutRef: "",
            fiatRepayRef:  ""
        });
        dealList.push(dealId);

        // Note: StableFX rate is written separately by oracle after
        // the offchain API trade is confirmed. See writeFXRate().
        emit DealOpened(dealId, rfq.borrower, quote.lender);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION I — FIAT SETTLEMENT
    // ══════════════════════════════════════════════════════════════════════════

    function confirmPayout(bytes32 _dealId, string calldata _fiatRef)
        external onlyOracle
    {
        Deal storage d = deals[_dealId];
        require(d.status == DealStatus.MATCHED, "BFP: wrong status");
        d.status        = DealStatus.ACTIVE;
        d.fiatPayoutRef = _fiatRef;
        emit PayoutConfirmed(_dealId, _fiatRef);
    }

    /**
     * @notice Confirm NGN repayment received.
     *         Automatically redeems USYC → USDC+yield to borrower.
     *         Emits YieldOffset showing how much the USYC yield saved.
     */
    function confirmRepayment(bytes32 _dealId, string calldata _fiatRef)
        external onlyOracle
    {
        Deal storage d = deals[_dealId];
        require(d.status == DealStatus.ACTIVE, "BFP: not active");
        d.status       = DealStatus.REPAID;
        d.fiatRepayRef = _fiatRef;
        emit Repaid(_dealId, _fiatRef);

        CollateralPosition storage pos = positions[_dealId];

        // Auto-release onchain collateral
        if (pos.collType == CollType.USYC && pos.usycShares > 0) {
            _executeRedeem(_dealId); // returns USDC + yield to borrower
        } else if (pos.collType == CollType.USDC_ONLY && pos.usdcLocked > 0) {
            _releaseUSDC(_dealId, d.borrower);
        }
        // Fiat (GBP/USD/EUR): banking partner releases JNVA offchain
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION J — ORACLE ATTESTATION
    //
    //  Oracle polls JNVA banking API every 60s, computes health factor,
    //  signs the data, and calls this function.
    //  For USYC deals: live value is oracle-reported (Teller has no price feed
    //  callable from here without a custom oracle integration).
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @param _dealId         Deal to attest
     * @param _collateralUSD  Live collateral value in USD × 1e6
     *                        For USYC: current redemption value from Teller
     *                        For fiat: JNVA balance from banking API
     * @param _drawnNGN       Outstanding NGN draw (whole units, no decimals)
     * @param _ngnUsdRate     Live NGN per USD × 1e6  (from market or StableFX)
     * @param _nonce          Oracle replay nonce
     * @param _sig            Oracle ECDSA signature
     */
    function attest(
        bytes32 _dealId,
        uint256 _collateralUSD,
        uint256 _drawnNGN,
        uint256 _ngnUsdRate,
        uint256 _nonce,
        bytes calldata _sig
    ) external onlyOracle {
        require(_nonce == oracleNonce[msg.sender], "BFP: bad nonce");
        oracleNonce[msg.sender]++;

        bytes32 h = _prefixed(keccak256(abi.encodePacked(
            _dealId, _collateralUSD, _drawnNGN, _ngnUsdRate, _nonce, block.chainid
        )));
        require(_recover(h, _sig) == msg.sender, "BFP: bad signature");

        Deal storage d = deals[_dealId];
        CollateralPosition storage pos = positions[_dealId];

        // Health factor: (collUSD × LTV) / drawnUSD
        // drawnUSD = drawnNGN / ngnPerUsd
        uint256 drawnUSD = _drawnNGN > 0 ? (_drawnNGN * USDC_DEC) / _ngnUsdRate : 0;
        uint256 hf       = drawnUSD == 0
            ? type(uint256).max
            : (_collateralUSD * ltvBPS * PRECISION) / (drawnUSD * 10000);

        uint8 state = _computeHealthState(_dealId, hf);
        d.healthFactor  = hf;
        d.healthState   = state;
        d.collateralUSD = _collateralUSD;

        // Compute USYC yield offset against outstanding fee
        uint256 yieldUSDC;
        uint256 netFeeNGN;
        uint256 daysOpen = (block.timestamp - d.openedAt) / 1 days;
        uint256 grossFee = (d.amountNGN * d.feeBPS * daysOpen) / 10000;

        if (pos.collType == CollType.USYC && pos.usycShares > 0) {
            // Yield = current value - original deposit
            yieldUSDC = _collateralUSD > pos.usdcDepositedAmt
                ? _collateralUSD - pos.usdcDepositedAmt : 0;

            // Convert yield to NGN using locked StableFX rate
            LockedFXRate memory rate = fxRates[_dealId];
            if (rate.active && yieldUSDC > 0) {
                // yieldUSDC (1e6) × rateUsdc6 (1e6) / 1e12 = whole NGN
                uint256 yieldNGN = (yieldUSDC * rate.rateUsdc6) / 1e12;
                netFeeNGN        = grossFee > yieldNGN ? grossFee - yieldNGN : 0;
                emit YieldOffset(_dealId, yieldUSDC, yieldNGN, netFeeNGN);
            } else {
                netFeeNGN = grossFee;
            }
        } else {
            netFeeNGN = grossFee;
        }

        // Store attestation
        history[_dealId].push(Attestation({
            dealId:        _dealId,
            collateralUSD: _collateralUSD,
            drawnNGN:      _drawnNGN,
            yieldUSDC:     yieldUSDC,
            netFeeNGN:     netFeeNGN,
            healthFactor:  hf,
            healthState:   state,
            timestamp:     block.timestamp,
            oracle:        msg.sender
        }));

        emit Attested(_dealId, hf, state);

        // Auto-liquidate if grace period expired
        if (state == uint8(HealthState.LIQUIDATING)) {
            d.status = DealStatus.LIQUIDATED;
            if (pos.collType == CollType.USYC && pos.usycShares > 0) {
                _executeRedeem(_dealId); // USYC redeemed → sent to lender
            }
            emit Liquidated(_dealId);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SECTION K — VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Fee breakdown: gross fee, USYC yield offset, net fee owed
     */
    function calculateFee(bytes32 _dealId)
        external view
        returns (
            uint256 grossFeeNGN,
            uint256 yieldOffsetNGN,
            uint256 netFeeNGN,
            uint256 daysElapsed
        )
    {
        Deal memory d     = deals[_dealId];
        daysElapsed       = (block.timestamp - d.openedAt) / 1 days;
        grossFeeNGN       = (d.amountNGN * d.feeBPS * daysElapsed) / 10000;

        CollateralPosition memory pos = positions[_dealId];
        LockedFXRate memory rate      = fxRates[_dealId];

        if (pos.collType == CollType.USYC && pos.usycShares > 0 && rate.active) {
            // Oracle reports current USYC value in attestations
            // Here we use the last attested collateralUSD vs deposit for yield est.
            uint256 lastAttestedUSD = d.collateralUSD;
            uint256 yieldUSDC_      = lastAttestedUSD > pos.usdcDepositedAmt
                ? lastAttestedUSD - pos.usdcDepositedAmt : 0;
            yieldOffsetNGN = (yieldUSDC_ * rate.rateUsdc6) / 1e12;
            netFeeNGN      = grossFeeNGN > yieldOffsetNGN ? grossFeeNGN - yieldOffsetNGN : 0;
        } else {
            netFeeNGN = grossFeeNGN;
        }
    }

    // Read helpers
    function getQuotes       (bytes32 id) external view returns (Quote[]       memory) { return quotes[id];   }
    function getHistory      (bytes32 id) external view returns (Attestation[] memory) { return history[id];  }
    function getPosition     (bytes32 id) external view returns (CollateralPosition memory) { return positions[id]; }
    function getFXRate       (bytes32 id) external view returns (LockedFXRate   memory) { return fxRates[id];  }
    function getRFQCount     ()           external view returns (uint256) { return rfqList.length;  }
    function getDealCount    ()           external view returns (uint256) { return dealList.length; }
    function getHistoryCount (bytes32 id) external view returns (uint256) { return history[id].length; }

    function getActiveDealIds() external view returns (bytes32[] memory ids) {
        uint256 n;
        for (uint i; i < dealList.length; i++)
            if (deals[dealList[i]].status == DealStatus.ACTIVE) n++;
        ids = new bytes32[](n);
        uint256 j;
        for (uint i; i < dealList.length; i++)
            if (deals[dealList[i]].status == DealStatus.ACTIVE) ids[j++] = dealList[i];
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /**
     * @dev Execute USYC redemption via Teller.
     *      teller.redeem(shares, receiver, account)
     *        receiver = who gets USDC
     *        account  = address(this) — BFPay holds the shares
     *
     *      REPAID    → borrower gets original USDC + yield
     *      LIQUIDATED → lender gets USDC as collateral compensation
     */
    function _executeRedeem(bytes32 _dealId) internal {
        Deal storage d   = deals[_dealId];
        CollateralPosition storage pos = positions[_dealId];

        uint256 shares = pos.usycShares;
        pos.usycShares = 0; // clear before external call (re-entrancy guard)

        // Approve Teller to pull USYC shares from this contract
        IERC20(usyc).approve(teller, shares);

        // Determine recipient: borrower if repaid, lender if liquidated
        address recipient = d.status == DealStatus.REPAID ? d.borrower : d.lender;

        // teller.redeem(shares, receiver, account)
        uint256 usdcOut = ITeller(teller).redeem(shares, recipient, address(this));

        emit USYCRedeemed(_dealId, recipient, shares, usdcOut);
    }

    function _releaseUSDC(bytes32 _dealId, address _to) internal {
        CollateralPosition storage pos = positions[_dealId];
        uint256 amt   = pos.usdcLocked;
        pos.usdcLocked = 0;
        require(IERC20(usdc).transfer(_to, amt), "BFP: USDC transfer failed");
        emit USDCReleased(_dealId, _to, amt);
    }

    function _computeHealthState(bytes32 _dealId, uint256 hf) internal returns (uint8) {
        if (hf >= 11e17) {                          // ≥ 1.1 → HEALTHY
            marginCallAt[_dealId] = 0;
            return uint8(HealthState.HEALTHY);
        }
        if (hf >= PRECISION)                        // 1.0 – 1.1 → WARNING
            return uint8(HealthState.WARNING);

        // < 1.0 → MARGIN CALL or LIQUIDATING
        if (marginCallAt[_dealId] == 0) {
            marginCallAt[_dealId] = block.timestamp;
            emit MarginCall(_dealId, block.timestamp + gracePeriod);
            return uint8(HealthState.MARGIN_CALL);
        }
        if (block.timestamp >= marginCallAt[_dealId] + gracePeriod)
            return uint8(HealthState.LIQUIDATING);

        return uint8(HealthState.MARGIN_CALL);
    }

    function _prefixed(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function _recover(bytes32 hash, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "BFP: bad sig length");
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        return ecrecover(hash, v, r, s);
    }

    function getAllRfqs() external view returns (bytes32[] memory, RFQ[] memory) {
        uint256 count = rfqList.length;
        RFQ[] memory data = new RFQ[](count);
        for (uint256 i = 0; i < count; i++) {
            data[i] = rfqs[rfqList[i]];
        }
        return (rfqList, data);
    }

    function getQuote(bytes32 _rfqId) external view returns (Quote[] memory) {
        return quotes[_rfqId];
    }

    function getAllDeals() external view returns (bytes32[] memory ids, Deal[] memory allDeals) {
        uint256 count = dealList.length;
        allDeals = new Deal[](count);
        for (uint256 i = 0; i < count; i++) {
            allDeals[i] = deals[dealList[i]];
        }
        return (dealList, allDeals);
    }

    function getDealById(bytes32 _dealId) external view returns (Deal memory) {
        return deals[_dealId];
    }

    function getAllQuotes() external view returns (bytes32[] memory, RFQ[] memory) {
        uint256 count = rfqList.length;
        RFQ[] memory data = new RFQ[](count);
        for (uint256 i = 0; i < count; i++) {
            data[i] = rfqs[rfqList[i]];
        }
        return (rfqList, data);
    }

    function getAllCollateralPositions() external view returns (bytes32[] memory ids, CollateralPosition[] memory allPositions) {
        uint256 count = dealList.length;
        allPositions = new CollateralPosition[](count);
        
        for (uint256 i = 0; i < count; i++) {
            bytes32 dealId = dealList[i];
            allPositions[i] = positions[dealId];
        }
        
        return (dealList, allPositions);
    }

    function getAttestationHistory(bytes32 _dealId) external view returns (Attestation[] memory) {
        return history[_dealId];
    }
}
