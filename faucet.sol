
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

abstract contract ReentrancyGuard {
    uint256 private _status;
    constructor() { _status = 1; }
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

contract Ownable {
    address public owner;
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDR");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

contract StableClaimFaucet is Ownable, ReentrancyGuard {
    IERC20 public immutable stable;

    // 1000 USDC en 10^6 (USDC a 6 decimales)
    uint256 public constant CLAIM_AMOUNT = 1000 * 1e6;

    // 24h
    uint256 public constant COOLDOWN = 24 hours;

    // Dernier claim par utilisateur (timestamp)
    mapping(address => uint256) public lastClaimAt;

    // ABI demandé
    // - claim() nonpayable
    // - hasClaimed(address) view returns (bool)
    mapping(address => bool) private _everClaimed; // optionnel, juste pour info "a deja claim au moins une fois"

    event Deposited(address indexed from, uint256 amount);
    event Claimed(address indexed user, uint256 amount, uint256 nextEligibleAt);
    event OwnerWithdraw(address indexed to, uint256 amount);

    constructor(address stableToken) {
        require(stableToken != address(0), "ZERO_TOKEN");
        stable = IERC20(stableToken);
    }

    /**
     * @notice N'importe qui peut déposer des USDC dans le contrat.
     * @dev Il faut faire approve() sur le token avant.
     */
    function deposit(uint256 amount) external {
        require(amount > 0, "AMOUNT_0");
        bool ok = stable.transferFrom(msg.sender, address(this), amount);
        require(ok, "TRANSFER_FROM_FAIL");
        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Réclame 1000 USDC (1000*10^6) une fois toutes les 24h.
     * Signature exactement comme tu veux : claim()
     */
    function claim() external nonReentrant {
        address user = msg.sender;

        uint256 last = lastClaimAt[user];
        if (last != 0) {
            require(block.timestamp >= last + COOLDOWN, "COOLDOWN_NOT_PASSED");
        }

        require(stable.balanceOf(address(this)) >= CLAIM_AMOUNT, "INSUFFICIENT_FUNDS");

        // Effets avant interaction
        lastClaimAt[user] = block.timestamp;
        _everClaimed[user] = true;

        bool ok = stable.transfer(user, CLAIM_AMOUNT);
        require(ok, "TRANSFER_FAIL");

        emit Claimed(user, CLAIM_AMOUNT, block.timestamp + COOLDOWN);
    }

    /**
     * @notice View demandée : permet de voir si l'utilisateur a "claim" ou pas.
     * Ici: true = il a claim dans les dernières 24h (donc pas éligible encore).
     * Signature exactement comme tu veux : hasClaimed(address) -> bool
     */
    function hasClaimed(address user) external view returns (bool) {
        uint256 last = lastClaimAt[user];
        if (last == 0) return false;
        return block.timestamp < last + COOLDOWN;
    }

    // Bonus pratiques (facultatif) :

    /// @notice Retourne si l'utilisateur a déjà claim au moins une fois dans sa vie.
    function everClaimed(address user) external view returns (bool) {
        return _everClaimed[user];
    }

    /// @notice Si tu veux pouvoir récupérer des fonds (ex: fin de campagne).
    function ownerWithdraw(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "ZERO_TO");
        require(amount > 0, "AMOUNT_0");
        bool ok = stable.transfer(to, amount);
        require(ok, "TRANSFER_FAIL");
        emit OwnerWithdraw(to, amount);
    }

    /// @notice Aide front: timestamp quand l'utilisateur redevient éligible.
    function nextEligibleAt(address user) external view returns (uint256) {
        uint256 last = lastClaimAt[user];
        if (last == 0) return 0;
        return last + COOLDOWN;
    }
}
