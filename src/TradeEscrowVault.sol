// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IAccessControlModule {
    function isAdmin(address account) external view returns (bool);
}

contract TradeEscrowVault {
   
    
    event OfferCancelled(bytes32 indexed ref);
    event OfferMarkedPaid(bytes32 indexed ref);
    event OfferPicked(bytes32 indexed ref, uint256 tokenAmount);
    event OfferReleased(bytes32 indexed ref);
    event AppealCreated(bytes32 indexed ref, address indexed caller);
    event AppealResolved(bytes32 indexed ref, bool released);
    event Paused();
    event Unpaused();
    event Whitelisted(address indexed user, bool status);
    event Blacklisted(address indexed user, bool status);
    event OfferCreated(
        bytes32 indexed ref,
        address indexed creator,
        address indexed counterparty,
        uint256 tokenAmount,
        address token,
        bool isBuy,
        uint32 expiry,
        bytes3 fiatSymbol,
        uint256 fiatAmount,
        uint256 fiatToTokenRate
    );
    
    event TimelockCreated(bytes32 indexed id, address token, address to, uint256 amount, uint256 unlockTime);
    event TimelockExecuted(bytes32 indexed id);

    event Debug(
    string stage,
    bytes32 ref,
    address creator,
    address counterparty,
    address token,
    bool isBuy,
    uint256 tokenAmount,
    uint256 fiatAmount,
    uint256 fiatToTokenRate
);

event DebugBalance(string info, address token, uint256 balance);
event DebugTransfer(string info, address token, address to, uint256 amount);
event DebugTransferFail(string info, string reason);
event DebugTransferFailBytes(string info, bytes data);
event DebugMessage(string info);


    // ====== Config ======
    IAccessControlModule public immutable accessControl;
    bool public paused;
    uint256 private _locked;
    uint256 constant DECIMALS = 1e18;

    mapping(bytes32 => Timelock) public timelocks;
    uint256 public constant TIMELOCK_DELAY = 1 days; // configurable delay

    constructor(address _accessControl) {
        require(_accessControl != address(0), "Invalid access control");
        accessControl = IAccessControlModule(_accessControl);
        _locked = 1;
    }

    // ====== Reentrancy Guard ======
    modifier nonReentrant() {
        require(_locked == 1, "ReentrancyGuard: reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ====== Structs ======
    struct Offer {
        address creator;
        address counterparty;
        address token;
        bool isBuy;
        bool paid;
        bool released;
        bool picked;
        uint32 expiry;       // fits in 4 bytes instead of 32
        uint256 fiatAmount;   // 8 bytes, adjust max as needed
        uint256 fiatToTokenRate; // 8 bytes, scaled by 1e18
        bytes3 fiatSymbol;   // store as 3 bytes like "USD", "NGN"
        bool appealed;
        uint256 tokenAmount;
    }

    // ====== Timelock ======
    struct Timelock {
        uint256 amount;
        address token;      // address(0) for ETH
        address to;
        uint256 unlockTime;
        bool executed;
    }


    mapping(bytes32 => Offer) public offers;
    mapping(address => bool) public whitelist;
    mapping(address => bool) public blacklist;

    // ====== Modifiers ======
    modifier onlyAdmin() {
        require(accessControl.isAdmin(msg.sender), "Only admin");
        _;
    }

    modifier onlyWhitelisted(address user) {
        require(whitelist[user], "User not whitelisted");
        _;
    }

    modifier notBlacklisted(address user) {
        require(!blacklist[user], "User is blacklisted");
        _;
    }

    modifier offerExists(bytes32 ref) {
        require(offers[ref].creator != address(0), "Offer does not exist");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    // ====== Admin: Whitelist / Blacklist ======
    function setWhitelist(address user, bool status) external onlyAdmin {
        whitelist[user] = status;
        emit Whitelisted(user, status);
    }

    function setBlacklist(address user, bool status) external onlyAdmin {
        blacklist[user] = status;
        emit Blacklisted(user, status);
    }

    // ====== Admin: Pause / Unpause ======
    function pause() external onlyAdmin {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused();
    }

    // ====== Internal: Safe ERC20 transfer ======
    /*function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "ERC20 transfer failed");
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        require(token.transferFrom(from, to, amount), "ERC20 transferFrom failed");
    }*/

    function _safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransfer: failed");
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransferFrom: failed");
    }

     // --- HELPER CHECKS ---

    function _checkAllowanceAndBalance(IERC20 token, address user, uint256 requiredAmount) internal view {
        uint256 balance = token.balanceOf(user);
        require(balance >= requiredAmount, "Insufficient balance");

        uint256 allowance = token.allowance(user, address(this));
        require(allowance >= requiredAmount, "Insufficient allowance");
    }

    // ====== Offer Management ======
    function createOffer(
        bytes32 ref,
        address counterparty,
        address token,
        bool isBuy,
        uint32 expiry,
        string calldata fiatSymbol,
        uint256 fiatAmount,
        uint256 fiatToTokenRate,
        uint256 tokenAmount
    ) external whenNotPaused notBlacklisted(msg.sender) notBlacklisted(counterparty) onlyWhitelisted(msg.sender) {
        require(ref != bytes32(0), "Invalid ref");
        require(offers[ref].creator == address(0), "Offer exists");
        //require(counterparty != address(0), "Invalid counterparty");
        require(expiry > block.timestamp, "Expiry must be future");
        require(fiatToTokenRate > 0, "Invalid rate");
        require(bytes(fiatSymbol).length == 3, "Fiat symbol must be 3 chars");
        require(fiatAmount > 0, "Invalid fiat amount");
        require(fiatToTokenRate > 0, "Invalid token rate");
        require(tokenAmount > 0, "Invalid token amount");

        // Compute tokenAmount using fixed-point arithmetic (DECIMALS = 1e18)
      

        // Convert fiatSymbol string (3 chars) to bytes3
        bytes3 symbol;
        assembly {
            // calldata layout: fiatSymbol is a dynamic calldata item; fiatSymbol.offset points to its location
            // load 32 bytes from the string location then truncate to bytes3
            symbol := calldataload(fiatSymbol.offset)
        }

        IERC20 erc20 = IERC20(token);

        // ✅ Check allowance and balance before transfer
        _checkAllowanceAndBalance(erc20, msg.sender, tokenAmount);

        // Delegate storage writes, transfer and event emission to an internal function
        _saveOfferAndTransfer(
            ref,
            msg.sender,
            counterparty,
            token,
            isBuy,
            expiry,
            symbol,
            fiatAmount,
            fiatToTokenRate,
            tokenAmount
        );
    }

    function _saveOfferAndTransfer(
        bytes32 ref,
        address creator,
        address counterparty,
        address token,
        bool isBuy,
        uint32 expiry,
        bytes3 fiatSymbol,
        uint256 fiatAmount,
        uint256 fiatToTokenRate,
        uint256 tokenAmount
    ) internal {
        // Write into storage (single storage pointer usage)
        /*
           if isBuy, creator must be seller, counterparty will be buyer
           if isSell creator must be seller, counterparty will be null

        */

         // Transfer tokens to escrow for seller offers (do this after storage write)
        //if (tokenAmount > 0) {
        _safeTransferFrom(IERC20(token), msg.sender, address(this), tokenAmount);
        
        Offer storage o = offers[ref];
        o.creator = creator;
        o.counterparty = counterparty;
        o.token = token;
        o.isBuy = isBuy;
        o.expiry = expiry;
        o.fiatSymbol = fiatSymbol;
        o.fiatAmount = fiatAmount;
        o.fiatToTokenRate = fiatToTokenRate;
        o.appealed = false;
        o.paid = false;
        o.released = false;
        o.tokenAmount = tokenAmount;

        if(o.counterparty != address(0))
            o.picked = true;
        else
           o.picked = false;

        // Emit event
        emit OfferCreated(
            ref,
            creator,
            counterparty,
            tokenAmount,
            token,
            isBuy,
            expiry,
            fiatSymbol,
            fiatAmount,
            fiatToTokenRate
        );
    }

    function cancelOffer(bytes32 ref) external offerExists(ref) whenNotPaused nonReentrant notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) {
        Offer storage o = offers[ref];
        //require(msg.sender == o.counterparty, "Only counterparty");
        require(!o.released && !o.paid, "Cannot cancel");
        require( (o.picked && msg.sender == o.counterparty) || (!o.picked)  , "Already picked");

        if (o.tokenAmount > 0) {
            _safeTransfer(IERC20(o.token), o.creator, o.tokenAmount);
        }

        delete offers[ref];
        emit OfferCancelled(ref);
    }

    
    function pickOffer(bytes32 ref) external offerExists(ref) whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) {
        Offer storage o = offers[ref];
        require(msg.sender == o.counterparty || o.counterparty == address(0), "only chosen counterparty");
        require(!o.paid, "Already marked paid");
        require(!o.picked, "Already picked");
        require(!o.released, "Already released");
         
        o.counterparty =  msg.sender;
        /*if (o.isBuy && o.tokenAmount > 0) {
            _safeTransferFrom(IERC20(o.token), msg.sender, address(this), o.tokenAmount);
        }*/
        o.picked = true;
        
        //if pick for buy USDT, the picker USDT must be transferred to vault

        emit OfferPicked(ref,o.tokenAmount);
    }

    function markPaid(bytes32 ref) external offerExists(ref) whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) {
        Offer storage o = offers[ref];
        /*
           if isBuy, creator must be seller, counterparty will be buyer
           if isSell creator must be seller, counterparty will be null

           if isBuy counterparty must mark paid
           if isSell , counterparty must mark paid

        */
        require(msg.sender == o.counterparty, "Only counterparty");
        //require(o.picked, "Not picked");
        require(!o.paid, "Already marked paid");
        o.paid = true;
        emit OfferMarkedPaid(ref);
    }


    function releaseOffer(bytes32 ref) external offerExists(ref)  whenNotPaused nonReentrant {
        Offer storage o = offers[ref];
        require(o.paid, "Not marked paid");
        require(!o.released, "Already released");
        require(o.picked, "Not picked");
        require(whitelist[o.creator] && whitelist[o.counterparty], "Both must be whitelisted");
        require(!blacklist[o.creator] && !blacklist[o.counterparty], "Cannot release to blacklisted user");


        /*
           if isBuy, creator must be seller, counterparty will be buyer
           if isSell creator must be seller, counterparty will be null
        */

        require(msg.sender == o.creator, "Only creator can release");
                  
       //if is buy USDT true, pick offer, and mark paid, release it
       //if sell usdt, lock into vault, confirm receipt and release
       emit Debug("releaseOffer: pre-transfer", ref, o.creator, o.counterparty, o.token, o.isBuy, o.tokenAmount, o.fiatAmount, o.fiatToTokenRate);
      
        require(o.tokenAmount > 0, "tokenAmount=0");
        IERC20 token = IERC20(o.token);
        uint256 bal = token.balanceOf(address(this));
        emit DebugBalance("Vault balance before transfer", o.token, bal);

        //_safeTransfer(IERC20(o.token), o.counterparty, o.tokenAmount);
        require(bal >= o.tokenAmount, "insufficient vault balance");

        // Safe transfer with inline revert check
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, o.counterparty, o.tokenAmount)
        );

        if (!success) {
            string memory reason = _getRevertMsg(data);
            emit DebugTransferFail("Token transfer failed", reason);
            revert(string(abi.encodePacked("transfer failed: ", reason)));
        }

        emit DebugTransfer("Token transfer success", o.token, o.counterparty, o.tokenAmount);
    

        o.released = true;
        emit OfferReleased(ref);
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If no revert message, return default
        if (_returnData.length < 68) return "Transaction reverted silently";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }

    // ====== Appeals ======
    function createAppeal(bytes32 ref) external offerExists(ref) whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) {
        Offer storage o = offers[ref];
        require(msg.sender == o.creator || msg.sender == o.counterparty, "Only parties");
        require(!o.appealed, "Already appealed");
        o.appealed = true;
        emit AppealCreated(ref, msg.sender);
    }

    function resolveAppeal(bytes32 ref, bool release) external onlyAdmin offerExists(ref) whenNotPaused nonReentrant {
        Offer storage o = offers[ref];
        require(o.appealed, "No appeal");
        o.appealed = false;

        if (release && !o.released) {
            require(whitelist[o.creator] && whitelist[o.counterparty], "Both must be whitelisted");
            require(!blacklist[o.creator] && !blacklist[o.counterparty], "Cannot release to blacklisted user");
            
            if (o.tokenAmount > 0) {
                _safeTransfer(IERC20(o.token), o.creator, o.tokenAmount);
            }
            o.released = true;
        }

        emit AppealResolved(ref, release);
    }

    // Dedicated getter for offers
        function getOffer(bytes32 ref) external view returns (
            address creator,
            address counterparty,
            address token,
            bool isBuy,
            uint32 expiry,
            bytes3 fiatSymbol,
            uint256 fiatAmount,
            uint256 fiatToTokenRate,
            bool appealed,
            bool paid,
            bool released,
            uint256 tokenAmount,
            bool picked
        ) {
            Offer storage o = offers[ref];
             return (
                o.creator,
                o.counterparty,
                o.token,
                o.isBuy,
                o.expiry,
                o.fiatSymbol,
                o.fiatAmount,
                o.fiatToTokenRate,
                o.appealed,
                o.paid,
                o.released,
                o.tokenAmount,
                o.picked );
        }


        // ====== Admin: schedule rescue ======
        function scheduleRescueERC20(address token, address to, uint256 amount) external onlyAdmin returns (bytes32) {
            require(to != address(0), "invalid address");
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 send = amount == 0 ? bal : amount;
            require(send <= bal, "no balance");

            bytes32 id = keccak256(abi.encodePacked(token, to, send, block.timestamp));
            timelocks[id] = Timelock(send, token, to, block.timestamp + TIMELOCK_DELAY, false);
            emit TimelockCreated(id, token, to, send, block.timestamp + TIMELOCK_DELAY);
            return id;
        }

        function executeRescueERC20(bytes32 id) external onlyAdmin {
            Timelock storage t = timelocks[id];
            require(!t.executed, "already executed");
            require(block.timestamp >= t.unlockTime, "timelock not expired");

            _safeTransfer(IERC20(t.token), t.to, t.amount);
            t.executed = true;
            emit TimelockExecuted(id);
        }

        // ====== Admin: schedule rescue ETH ======
        function scheduleRescueETH(address payable to, uint256 amount) external onlyAdmin returns (bytes32) {
            require(to != address(0), "invalid address");
            uint256 bal = address(this).balance;
            uint256 send = amount == 0 ? bal : amount;
            require(send <= bal, "no balance");

            bytes32 id = keccak256(abi.encodePacked(address(0), to, send, block.timestamp));
            timelocks[id] = Timelock(send, address(0), to, block.timestamp + TIMELOCK_DELAY, false);
            emit TimelockCreated(id, address(0), to, send, block.timestamp + TIMELOCK_DELAY);
            return id;
        }

        function executeRescueETH(bytes32 id) external onlyAdmin {
            Timelock storage t = timelocks[id];
            require(!t.executed, "already executed");
            require(block.timestamp >= t.unlockTime, "timelock not expired");

            (bool s,) = payable(t.to).call{value: t.amount}("");
            require(s, "eth transfer failed");
            t.executed = true;
            emit TimelockExecuted(id);
        }
}