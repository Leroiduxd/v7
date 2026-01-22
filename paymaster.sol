// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* ────────────────────────── Interface vers BrokexCore ────────────────────────── */

interface IBrokexCore {
    function openMarketPositionFor(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external;
    function placeOrderFor(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external;
    function closePositionMarketFor(address trader, uint256 tradeId, bytes calldata oracleProof) external;
    function updateSLTPFor(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external;
    function cancelOrderFor(address trader, uint256 tradeId) external;
}

/* ────────────────────────── Brokex Paymaster V2 ────────────────────────── */

contract BrokexPaymaster is Pausable, Ownable {
    using ECDSA for bytes32;

    IBrokexCore public immutable core;
    uint256 public immutable CHAIN_ID; // ✅ Chain ID fixé au déploiement
    bytes32 public immutable DOMAIN_SEPARATOR; // ✅ Calculé une seule fois
    
    mapping(address => uint256) public nonces;

    // ───────────── TypeHashes (SANS Proof) ─────────────

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

    constructor(address _core, uint256 _chainId) Ownable(msg.sender) {
        require(_core != address(0), "CORE_ZERO_ADDR");
        core = IBrokexCore(_core);
        CHAIN_ID = _chainId;

        // Construction manuelle du Domain Separator pour garantir le ChainID
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BrokexPaymaster")),
                keccak256(bytes("1")),
                _chainId, // ✅ Force l'ID (ex: 688689)
                address(this)
            )
        );
    }

    // ───────────── Admin ─────────────

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ───────────── Internes / Helpers ─────────────

    function _useNonce(address trader) internal returns (uint256 current) {
        current = nonces[trader];
        nonces[trader] = current + 1;
    }

    function _checkDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    // ✅ FONCTION VIEW DE DEBUG (Demandée)
    // Permet de voir quelle adresse a signé ce hash
    function recoverSigner(bytes32 structHash, bytes calldata signature) external view returns (address) {
        bytes32 digest = _hashTypedDataV4(structHash);
        return ECDSA.recover(digest, signature);
    }

    // Fonction interne de vérif
    function _verify(address trader, bytes32 structHash, bytes calldata signature) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == trader, "INVALID_SIGNATURE");
    }

    // ───────────── EXÉCUTION (Relayed Functions) ─────────────

    // 1. OPEN MARKET (Proof en argument, pas dans le hash)
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

        core.openMarketPositionFor(trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof);
    }

    // 2. PLACE ORDER
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

    // 3. CLOSE MARKET (Proof en argument, pas dans le hash)
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
}
