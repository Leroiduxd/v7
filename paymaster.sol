// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* ────────────────────────── Interface vers BrokexCore ────────────────────────── */

interface IBrokexCore {
    function openMarketPositionFor(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external;
    function placeOrderFor(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external;
    function executeOrderFor(uint256 tradeId, bytes calldata oracleProof) external;
    function closePositionMarketFor(address trader, uint256 tradeId, bytes calldata oracleProof) external;
    function updateSLTPFor(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external;
    function cancelOrderFor(address trader, uint256 tradeId) external;
}

/* ────────────────────────── Brokex Paymaster EIP-712 ────────────────────────── */

contract BrokexPaymaster is EIP712, Pausable, Ownable {
    using ECDSA for bytes32;

    IBrokexCore public immutable core;
    
    // Mapping pour éviter les attaques par rejeu (Replay Attack)
    mapping(address => uint256) public nonces;

    // ───────────── Structs (Ce que l'utilisateur signe) ─────────────

    struct OpenMarketCall {
        address trader;
        uint32 assetId;
        bool isLong;
        uint8 leverage;
        int32 lotSize;
        uint48 stopLoss;
        uint48 takeProfit;
        uint256 nonce;
        uint256 deadline;
    }

    struct PlaceOrderCall {
        address trader;
        uint32 assetId;
        bool isLong;
        uint8 leverage;
        int32 lotSize;
        uint48 targetPrice;
        uint48 stopLoss;
        uint48 takeProfit;
        uint256 nonce;
        uint256 deadline;
    }

    struct CloseMarketCall {
        address trader;
        uint256 tradeId;
        uint256 nonce;
        uint256 deadline;
    }

    struct UpdateSLTPCall {
        address trader;
        uint256 tradeId;
        uint48 newSL;
        uint48 newTP;
        uint256 nonce;
        uint256 deadline;
    }

    struct CancelOrderCall {
        address trader;
        uint256 tradeId;
        uint256 nonce;
        uint256 deadline;
    }

    // ───────────── TypeHashes (EIP-712 Schemas) ─────────────

    bytes32 private constant OPEN_MARKET_TYPEHASH = keccak256(
        "OpenMarket(address trader,uint32 assetId,bool isLong,uint8 leverage,int32 lotSize,uint48 stopLoss,uint48 takeProfit,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant PLACE_ORDER_TYPEHASH = keccak256(
        "PlaceOrder(address trader,uint32 assetId,bool isLong,uint8 leverage,int32 lotSize,uint48 targetPrice,uint48 stopLoss,uint48 takeProfit,uint256 nonce,uint256 deadline)"
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

    // ───────────── Constructor ─────────────

    constructor(address _core) 
        EIP712("BrokexPaymaster", "1") 
        Ownable(msg.sender) 
    {
        require(_core != address(0), "CORE_ZERO_ADDR");
        core = IBrokexCore(_core);
    }

    // ───────────── Admin Functions ─────────────

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ───────────── Internes : Nonce & Deadline ─────────────

    function _useNonce(address trader) internal returns (uint256 current) {
        current = nonces[trader];
        nonces[trader] = current + 1;
    }

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
    }

    function _verify(address trader, bytes32 structHash, bytes calldata signature) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == trader, "INVALID_SIGNATURE");
    }

    // ───────────── EXÉCUTION (Relayed Functions) ─────────────

    // 1. OPEN MARKET
    function executeOpenMarket(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        int32 lotSize,
        uint48 stopLoss,
        uint48 takeProfit,
        uint256 deadline,
        bytes calldata oracleProof, // La preuve n'est pas signée (pour être fraîche)
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(abi.encode(
            OPEN_MARKET_TYPEHASH,
            trader,
            assetId,
            isLong,
            leverage,
            lotSize,
            stopLoss,
            takeProfit,
            nonce,
            deadline
        ));

        _verify(trader, structHash, signature);

        // Appel au Core (OnlyPaymaster)
        core.openMarketPositionFor(trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof);
    }

    // 2. PLACE ORDER (LIMIT)
    function executePlaceOrder(
        address trader,
        uint32 assetId,
        bool isLong,
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

        bytes32 structHash = keccak256(abi.encode(
            PLACE_ORDER_TYPEHASH,
            trader,
            assetId,
            isLong,
            leverage,
            lotSize,
            targetPrice,
            stopLoss,
            takeProfit,
            nonce,
            deadline
        ));

        _verify(trader, structHash, signature);

        core.placeOrderFor(trader, assetId, isLong, leverage, lotSize, targetPrice, stopLoss, takeProfit);
    }

    // 3. CLOSE MARKET
    function executeCloseMarket(
        address trader,
        uint256 tradeId,
        uint256 deadline,
        bytes calldata oracleProof,
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(abi.encode(
            CLOSE_MARKET_TYPEHASH,
            trader,
            tradeId,
            nonce,
            deadline
        ));

        _verify(trader, structHash, signature);

        core.closePositionMarketFor(trader, tradeId, oracleProof);
    }

    // 4. UPDATE SL/TP
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

        bytes32 structHash = keccak256(abi.encode(
            UPDATE_SLTP_TYPEHASH,
            trader,
            tradeId,
            newSL,
            newTP,
            nonce,
            deadline
        ));

        _verify(trader, structHash, signature);

        core.updateSLTPFor(trader, tradeId, newSL, newTP);
    }

    // 5. CANCEL ORDER
    function executeCancelOrder(
        address trader,
        uint256 tradeId,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);

        bytes32 structHash = keccak256(abi.encode(
            CANCEL_ORDER_TYPEHASH,
            trader,
            tradeId,
            nonce,
            deadline
        ));

        _verify(trader, structHash, signature);

        core.cancelOrderFor(trader, tradeId);
    }

    // Note: executeOrderFor n'a pas besoin de signature utilisateur car c'est une exécution publique
    // Si tu veux quand même l'exposer via le Paymaster pour des bots :
    function executeOrderBot(uint256 tradeId, bytes calldata oracleProof) external whenNotPaused {
        // Pas de vérification de signature utilisateur ici, car l'ordre est déjà placé.
        // N'importe qui peut trigger l'exécution si le prix est bon.
        core.executeOrderFor(tradeId, oracleProof);
    }
}
