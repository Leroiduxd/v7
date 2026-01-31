// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* ────────────────────────── Interface Synchronisée (Sécurité Trader) ────────────────────────── */

interface IBrokexCore {
    // 1. Open Market (Déjà OK)
    function openMarketPosition(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external;
    
    // 2. Place Order (Déjà OK)
    function placeOrder(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external;
    
    // 3. Close Market (✅ MODIFIÉ: prend trader)
    function closePositionMarket(address trader, uint256 tradeId, bytes calldata oracleProof) external;
    
    // 4. Update SL/TP (✅ MODIFIÉ: prend trader)
    function updateSLTP(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external;
    
    // 5. Cancel Order (✅ MODIFIÉ: prend trader)
    function cancelOrder(address trader, uint256 tradeId) external;
    
    // 6. Add Margin (Déjà OK)
    function addMargin(address trader, uint256 tradeId, uint64 amount6) external;
}

/* ────────────────────────── Brokex Paymaster V4.2 (Secure Relay) ────────────────────────── */

contract BrokexPaymaster is Pausable, Ownable {
    using ECDSA for bytes32;

    IBrokexCore public immutable core;
    uint256 public immutable CHAIN_ID; 
    bytes32 public immutable DOMAIN_SEPARATOR; 
    
    mapping(address => uint256) public nonces;

    // ───────────── TypeHashes ─────────────

    bytes32 private constant OPEN_MARKET_TYPEHASH = keccak256(
        "OpenMarket(address trader,uint32 assetId,bool isLong,uint8 leverage,int32 lotSize,uint48 stopLoss,uint48 takeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant PLACE_ORDER_TYPEHASH = keccak256(
        "PlaceOrder(address trader,uint32 assetId,bool isLong,bool isLimit,uint8 leverage,int32 lotSize,uint48 targetPrice,uint48 stopLoss,uint48 takeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant CLOSE_MARKET_TYPEHASH = keccak256(
        "CloseMarket(address trader,uint256 tradeId,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant UPDATE_SLTP_TYPEHASH = keccak256(
        "UpdateSLTP(address trader,uint256 tradeId,uint48 newSL,uint48 newTP,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant CANCEL_ORDER_TYPEHASH = keccak256(
        "CancelOrder(address trader,uint256 tradeId,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant ADD_MARGIN_TYPEHASH = keccak256(
        "AddMargin(address trader,uint256 tradeId,uint64 amount6,uint256 nonce,uint256 deadline)"
    );

    // ───────────── Constructor ─────────────

    constructor(address _core, uint256 _chainId) Ownable(msg.sender) {
        require(_core != address(0), "CORE_ZERO_ADDR");
        core = IBrokexCore(_core);
        CHAIN_ID = _chainId;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BrokexPaymaster")),
                keccak256(bytes("1")),
                _chainId,
                address(this)
            )
        );
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function _useNonce(address trader) internal returns (uint256 current) {
        current = nonces[trader];
        nonces[trader] = current + 1;
    }

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
    }

    function _verify(address trader, bytes32 structHash, bytes calldata signature) internal view {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, signature);
        require(signer == trader, "INVALID_SIGNATURE");
    }

    // =========================================================================
    //                                1. OPEN MARKET
    // =========================================================================

    function executeOpenMarket(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        int32 lotSize,
        uint48 stopLoss,
        uint48 takeProfit,
        uint256 deadline,
        bytes calldata oracleProof, 
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(OPEN_MARKET_TYPEHASH, trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, nonce, deadline));
        _verify(trader, structHash, signature);
        core.openMarketPosition(trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof);
    }

    function openMarketPosition(
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        int32 lotSize,
        uint48 stopLoss,
        uint48 takeProfit,
        bytes calldata oracleProof
    ) external whenNotPaused {
        core.openMarketPosition(msg.sender, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof);
    }

    // =========================================================================
    //                                2. PLACE ORDER
    // =========================================================================

    function executePlaceOrder(
        address trader,
        uint32 assetId,
        bool isLong,
        bool isLimit,
        uint8 leverage,
        int32 lotSize,
        uint48 targetPrice,
        uint48 stopLoss,
        uint48 takeProfit,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(PLACE_ORDER_TYPEHASH, trader, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit, nonce, deadline));
        _verify(trader, structHash, signature);
        core.placeOrder(trader, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit);
    }

    function placeOrder(
        uint32 assetId,
        bool isLong,
        bool isLimit,
        uint8 leverage,
        int32 lotSize,
        uint48 targetPrice,
        uint48 stopLoss,
        uint48 takeProfit
    ) external whenNotPaused {
        core.placeOrder(msg.sender, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit);
    }

    // =========================================================================
    //                                3. CLOSE MARKET
    // =========================================================================

    function executeCloseMarket(
        address trader,
        uint256 tradeId,
        uint256 deadline,
        bytes calldata oracleProof, 
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(CLOSE_MARKET_TYPEHASH, trader, tradeId, nonce, deadline));
        _verify(trader, structHash, signature);
        
        // ✅ On envoie le 'trader' récupéré de la signature
        core.closePositionMarket(trader, tradeId, oracleProof);
    }

    function closePositionMarket(uint256 tradeId, bytes calldata oracleProof) external whenNotPaused {
        // ✅ On envoie msg.sender
        core.closePositionMarket(msg.sender, tradeId, oracleProof);
    }

    // =========================================================================
    //                                4. UPDATE SL/TP
    // =========================================================================

    function executeUpdateSLTP(
        address trader,
        uint256 tradeId,
        uint48 newSL,
        uint48 newTP,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(UPDATE_SLTP_TYPEHASH, trader, tradeId, newSL, newTP, nonce, deadline));
        _verify(trader, structHash, signature);
        
        // ✅ On envoie le 'trader' récupéré
        core.updateSLTP(trader, tradeId, newSL, newTP);
    }

    function updateSLTP(uint256 tradeId, uint48 newSL, uint48 newTP) external whenNotPaused {
        // ✅ On envoie msg.sender
        core.updateSLTP(msg.sender, tradeId, newSL, newTP);
    }

    // =========================================================================
    //                                5. CANCEL ORDER
    // =========================================================================

    function executeCancelOrder(
        address trader,
        uint256 tradeId,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, trader, tradeId, nonce, deadline));
        _verify(trader, structHash, signature);
        
        // ✅ On envoie le 'trader' récupéré
        core.cancelOrder(trader, tradeId);
    }

    function cancelOrder(uint256 tradeId) external whenNotPaused {
        // ✅ On envoie msg.sender
        core.cancelOrder(msg.sender, tradeId);
    }

    // =========================================================================
    //                                6. ADD MARGIN
    // =========================================================================

    function executeAddMargin(
        address trader,
        uint256 tradeId,
        uint64 amount6,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(ADD_MARGIN_TYPEHASH, trader, tradeId, amount6, nonce, deadline));
        _verify(trader, structHash, signature);
        
        core.addMargin(trader, tradeId, amount6);
    }

    function addMargin(uint256 tradeId, uint64 amount6) external whenNotPaused {
        core.addMargin(msg.sender, tradeId, amount6);
    }
}
