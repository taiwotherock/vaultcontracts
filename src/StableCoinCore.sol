// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./RolesModule.sol";

contract StableCoinCore is RolesModule {

    struct MintProposal {
        address to;
        uint256 amount;
        address proposer;
        uint256 createdAt;
        bool executed;
    }

    string public name;
    string public symbol;
    uint8 public decimals;
    bool public paused;
    address public tokenOracle;
    uint256 public maxTransferAmount ;//maximum 10 milion naira/GBP
    uint256 public proposalExpiry = 7 days;
    uint256 public MAX_CAP ;

    event Paused(address indexed admin);
    event Unpaused(address indexed admin);

    uint256 public cap; // default: no cap
    uint256 public totalSupply;
    uint256 public reserveBalance;
    mapping(bytes32 => uint256) public timelocks;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public whitelisted;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public mintProposalCount;
    mapping(uint256 => MintProposal) public mintProposals;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event CapUpdated(uint256 newCap);
    event CapChangeQueued(uint256 newCap, uint256 timelock);
    event ReserveBalanceUpdated(uint256 balance);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event BlacklistUpdated(address indexed account, bool blacklisted);
    event WhitelistUpdated(address indexed account, bool whitelisted);

    event MintProposed(uint256 indexed proposalId, address indexed proposer, address indexed to, uint256 amount);
    event MintExecuted(uint256 indexed proposalId, address indexed executor, address indexed to, uint256 amount);
    
    uint256 private _locked = 1;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, 
    address initialAdmin, uint256 initialSupply, uint256 _cap,
       uint256 transferLimit, uint256 maxCap) {
        require(initialAdmin != address(0), "ZERO_ADMIN");
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        cap = _cap;
        maxTransferAmount = transferLimit;
        MAX_CAP = maxCap;


        isAdmin[msg.sender] = true;
        emit AdminAdded(msg.sender);

        isAdmin[initialAdmin] = true;
        emit AdminAdded(initialAdmin);

        if (initialSupply > 0) {
            require(cap == 0 || initialSupply <= cap, "INITIAL_SUPPLY_EXCEEDS_CAP");
            totalSupply = initialSupply;
            balanceOf[initialAdmin] = initialSupply;
            emit Transfer(address(0), initialAdmin, initialSupply);
        }

    }

    modifier onlyAdminHook() {
        require(isAdmin[msg.sender], "NOT_ADMIN");
        _;
    }

    // Set or update max cap
    function setCap(uint256 newCap) external onlyAdminHook {
        bytes32 id = keccak256(abi.encode("setCap", newCap));
        if (timelocks[id] == 0) {
            timelocks[id] = block.timestamp + 1 days;
            emit CapChangeQueued(newCap, timelocks[id]);
        } else {
            require(block.timestamp >= timelocks[id], "TIMELOCK_NOT_EXPIRED");
            require(newCap > 0, "Cap cannot be zero");
            require(newCap >= totalSupply, "NEW_CAP_LESS_THAN_SUPPLY");
            require(newCap <= MAX_CAP, "EXCEEDS_MAX_CAP");
            cap = newCap;
            delete timelocks[id];
            emit CapUpdated(newCap);
        }
    }

    // Update reserve balance
    function updateReserveBalance(uint256 balance) external onlyAdminHook {
        require(balance >= totalSupply, "INSUFFICIENT_RESERVES");
        reserveBalance = balance;
        emit ReserveBalanceUpdated(balance);
    }

    // optional admin-only function
    function reduceReserve(uint256 amount) external onlyAdminHook {
        require(reserveBalance >= amount, "UNDERFLOW");
        reserveBalance -= amount;
    }

    function pause() external onlyAdminHook { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyAdminHook { paused = false; emit Unpaused(msg.sender); }

    function _isPaused() internal view returns (bool) { return paused; }

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    function isBlacklisted(address account) public view returns (bool) {
        return blacklisted[account];
    }

    function setBlacklist(address account, bool status) external onlyAdminHook {
        require(account != address(0), "ZERO_ADDRESS");
        require(!isAdmin[account], "CANNOT_BLACKLIST_ADMIN");
        blacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    function isWhitelisted(address account) public view returns (bool) {
        return whitelisted[account];
    }

    function setWhitelist(address account, bool status) external onlyAdminHook {
        require(account != address(0), "ZERO_ADDRESS");
        whitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function setPriceOracle(address oracle) external onlyAdminHook {
        require(oracle != address(0), "INVALID_ORACLE_ADDRESS");

        address old = tokenOracle;
        tokenOracle = oracle;
        emit PriceOracleUpdated(old, oracle);
    }

    function _beforeTransferChecks(address from, address to) internal view virtual {
        require(to != address(0), "TRC20: transfer to zero");
        require(!isBlacklisted(from) && !isBlacklisted(to), "TRC20: blacklisted");
        if (!isWhitelisted(from) && !isWhitelisted(to)) {
            require(!_isPaused(), "TRC20: paused");
        }
    }


    function _transferInternal(address from, address to, uint256 amount) internal virtual {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "TRC20: insufficient balance");
        if (!isWhitelisted(from)) {
            require(amount <= maxTransferAmount,"Transfer limit exceeded");
        }
       
        unchecked { balanceOf[from] = bal - amount; }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }


    function _approveInternal(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "TRC20: zero address");
        require(!isBlacklisted(spender), "SPENDER_BLACKLISTED");
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }


    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _beforeTransferChecks(msg.sender, to);
        _transferInternal(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external virtual returns (bool) {
        require(!isBlacklisted(msg.sender), "owner blacklisted");
        require(!paused, "paused");
        _approveInternal(msg.sender, spender, amount);
        return true;
    }


    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        _beforeTransferChecks(from, to);
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "TRC20: allowance exceeded");
        unchecked { allowance[from][msg.sender] = allowed - amount; }
        emit Approval(from, msg.sender, allowance[from][msg.sender]);
        _transferInternal(from, to, amount);
        return true;
    }

     function proposeMint(address to, uint256 amount) external onlyAdminHook returns (uint256) {
        require(!paused, "MINT_PAUSED");
        require(to != address(0), "ERC20: mint to zero");
        require(!isBlacklisted(to), "ERC20: mint to blacklisted");
        require(amount > 0, "AMOUNT_ZERO");
        
        // Pre-validate that mint would succeed
        uint256 newSupply = totalSupply + amount;
        if (cap > 0) {
            require(newSupply <= cap, "CAP_EXCEEDED");
        }
        require(reserveBalance >= newSupply, "INSUFFICIENT_RESERVES");
        
        uint256 proposalId = mintProposalCount++;
        MintProposal storage proposal = mintProposals[proposalId];
        proposal.to = to;
        proposal.amount = amount;
        proposal.createdAt = block.timestamp;
        proposal.proposer = msg.sender;
              
        emit MintProposed(proposalId, msg.sender, to, amount);
        return proposalId;
    }

    // ------------------- Public mint/burn -------------------
   
    function burn(uint256 amount) external nonReentrant {
        require(isBurner[msg.sender] || isAdmin[msg.sender], "NOT_AUTH_BURN");
        require(!isBlacklisted(msg.sender), "ERC20: burn from blacklisted");
        require(!paused, "BURN_PAUSED");

        uint256 bal = balanceOf[msg.sender];
        require(bal >= amount, "ERC20: insufficient balance");
        unchecked { balanceOf[msg.sender] = bal - amount; }
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
       
    }
   
    function executeMint(uint256 proposalId) external nonReentrant onlyAdminHook {
        MintProposal storage proposal = mintProposals[proposalId];
        
        require(proposal.createdAt > 0, "PROPOSAL_NOT_FOUND");
        require(!proposal.executed, "ALREADY_EXECUTED");
        require(proposal.proposer != msg.sender, "Executor cannot be same as proposer");
        require(block.timestamp <= proposal.createdAt + proposalExpiry, "PROPOSAL_EXPIRED");
        
        // Re-validate conditions at execution time
        require(!paused, "MINT_PAUSED");
        require(!isBlacklisted(proposal.to), "ERC20: mint to blacklisted");
        
        uint256 newSupply = totalSupply + proposal.amount;
        if (cap > 0) {
            require(newSupply <= cap, "CAP_EXCEEDED");
        }
        require(reserveBalance >= newSupply, "INSUFFICIENT_RESERVES");
        
        // Mark as executed before state changes (reentrancy protection)
        proposal.executed = true;
        
        // Execute the mint
        balanceOf[proposal.to] += proposal.amount;
        totalSupply = newSupply;
        
        emit Transfer(address(0), proposal.to, proposal.amount);
        emit MintExecuted(proposalId, msg.sender, proposal.to, proposal.amount);
    }

    
    /**
     * @notice Get proposal details
     * @param proposalId The ID of the proposal
     */
    function getMintProposal(uint256 proposalId) external view returns (
        address to,
        uint256 amount,
        address proposer,
        uint256 createdAt,
        bool executed,
        bool expired
    ) {
        MintProposal storage proposal = mintProposals[proposalId];
        return (
            proposal.to,
            proposal.amount,
            proposal.proposer,
            proposal.createdAt,
            proposal.executed,
            block.timestamp > proposal.createdAt + proposalExpiry
        );
    }

    function getTokenInfo() external view returns (
        uint256 totalSupply_,
        uint256 vaultBalance,
        uint256 cap_,
        uint256 remainingMintable,
        uint256 maximumSupply
    ) {
        totalSupply_ = totalSupply;
        vaultBalance = reserveBalance;
        cap_ = cap;
        maximumSupply = cap;
        
        if (cap == 0) {
            remainingMintable = type(uint256).max;
        } else if (totalSupply >= cap) {
            remainingMintable = 0;
        } else {
            remainingMintable = cap - totalSupply;
        }
    }
   

}
