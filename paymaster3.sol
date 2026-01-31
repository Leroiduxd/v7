// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* ────────────────────────── Interface vers BrokexCore ────────────────────────── */

interface IBrokexCore {
    // Note: Les suffixes "For" ont été retirés car ces fonctions sont maintenant "external onlyPaymaster"
    // et prennent toutes "address trader" en premier argument.
    
    function openMarketPosition(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external;
    
    function placeOrder(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external;
    
    function closePositionMarket(address trader, uint256 tradeId, bytes calldata oracleProof) external;
    
    function updateSLTP(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external;
    
    function cancelOrder(address trader, uint256 tradeId) external;
    
    function addMargin(address trader, uint256 tradeId, uint64 amount6) external;
}

/* ────────────────────────── Brokex Paymaster V4.0 (Router) ────────────────────────── */

contract BrokexPaymaster is Pausable, Ownable {
    using ECDSA for bytes32;

    IBrokexCore public immutable core;
    uint256 public immutable CHAIN_ID; 
    bytes32 public immutable DOMAIN_SEPARATOR; 
    
    mapping(address => uint256) public nonces;

    // ───────────── TypeHashes (Pour EIP-712 Gasless) ─────────────

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

    // ───────────── Admin ─────────────

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ───────────── Internes EIP-712 ─────────────

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

    function _verify(address trader, bytes32 structHash, bytes calldata signature) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == trader, "INVALID_SIGNATURE");
    }

    // =========================================================================
    //                            1. OPEN MARKET
    // =========================================================================

    // A. GASLESS (Relayed via Signature)
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
            OPEN_MARKET_TYPEHASH, trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, nonce, deadline
        ));
        _verify(trader, structHash, signature);

        // Appel au Core avec l'adresse récupérée
        core.openMarketPosition(trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof);
    }

    // B. STANDARD (User pays gas directly)
    function openMarketPosition(
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        int32 lotSize,
        uint48 stopLoss,
        uint48 takeProfit,
        bytes calldata oracleProof
    ) external whenNotPaused {
        // Pas de signature, l'identité EST l'expéditeur (msg.sender)
        core.openMarketPosition(msg.sender, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof);
    }

    // =========================================================================
    //                            2. PLACE ORDER
    // =========================================================================

    // A. GASLESS
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

        bytes32 structHash = keccak256(abi.encode(
            PLACE_ORDER_TYPEHASH, trader, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit, nonce, deadline
        ));
        _verify(trader, structHash, signature);

        core.placeOrder(trader, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit);
    }

    // B. STANDARD
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
    //                            3. CLOSE MARKET
    // =========================================================================

    // A. GASLESS
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

        core.closePositionMarket(trader, tradeId, oracleProof);
    }

    // B. STANDARD
    function closePositionMarket(
        uint256 tradeId, 
        bytes calldata oracleProof
    ) external whenNotPaused {
        core.closePositionMarket(msg.sender, tradeId, oracleProof);
    }

    // =========================================================================
    //                            4. UPDATE SL/TP
    // =========================================================================

    // A. GASLESS
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

        core.updateSLTP(trader, tradeId, newSL, newTP);
    }

    // B. STANDARD
    function updateSLTP(
        uint256 tradeId, 
        uint48 newSL, 
        uint48 newTP
    ) external whenNotPaused {
        core.updateSLTP(msg.sender, tradeId, newSL, newTP);
    }

    // =========================================================================
    //                            5. CANCEL ORDER
    // =========================================================================

    // A. GASLESS
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

        core.cancelOrder(trader, tradeId);
    }

    // B. STANDARD
    function cancelOrder(uint256 tradeId) external whenNotPaused {
        core.cancelOrder(msg.sender, tradeId);
    }

    // =========================================================================
    //                            6. ADD MARGIN
    // =========================================================================

    // A. GASLESS
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

    // B. STANDARD
    function addMargin(uint256 tradeId, uint64 amount6) external whenNotPaused {
        core.addMargin(msg.sender, tradeId, amount6);
    }
}
