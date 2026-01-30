// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* ────────────────────────── Interface vers BrokexCore ────────────────────────── */

interface IBrokexCore {
    function openMarketPositionFor(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external;
    function placeOrderFor(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external;
    function closePositionMarketFor(address trader, uint256 tradeId, bytes calldata oracleProof) external;
    function updateSLTPFor(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external;
    function cancelOrderFor(address trader, uint256 tradeId) external;
    function addMarginFor(address trader, uint256 tradeId, uint64 amount6) external;
}

/* ────────────────────────── Brokex Paymaster V3.2 ────────────────────────── */

contract BrokexPaymaster is Pausable, Ownable {
    using ECDSA for bytes32;

    IBrokexCore public immutable core;
    uint256 public immutable CHAIN_ID; 
    bytes32 public immutable DOMAIN_SEPARATOR; 
    
    mapping(address => uint256) public nonces;

    // ───────────── TypeHashes EIP-712 ─────────────

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

    // ───────────── Helpers Internes ─────────────
    function _useNonce(address trader) internal returns (uint256 current) {
        current = nonces[trader];
        nonces[trader] = current + 1;
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _verify(address trader, bytes32 structHash, bytes calldata signature) internal view {
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == trader, "INVALID_SIGNATURE");
    }

    /* ──────────────────────────────────────────────────────────────────────────
       SECTION 1 : ACCÈS DIRECT (Le trader appelle et paie son gaz)
       ────────────────────────────────────────────────────────────────────────── */

    function openMarketPosition(uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external whenNotPaused {
        core.openMarketPositionFor(msg.sender, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof);
    }

    function placeOrder(uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external whenNotPaused {
        core.placeOrderFor(msg.sender, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit);
    }

    function closePositionMarket(uint256 tradeId, bytes calldata oracleProof) external whenNotPaused {
        core.closePositionMarketFor(msg.sender, tradeId, oracleProof);
    }

    function updateSLTP(uint256 tradeId, uint48 newSL, uint48 newTP) external whenNotPaused {
        core.updateSLTPFor(msg.sender, tradeId, newSL, newTP);
    }

    function cancelOrder(uint256 tradeId) external whenNotPaused {
        core.cancelOrderFor(msg.sender, tradeId);
    }

    function addMargin(uint256 tradeId, uint64 amount6) external whenNotPaused {
        core.addMarginFor(msg.sender, tradeId, amount6);
    }

    /* ──────────────────────────────────────────────────────────────────────────
       SECTION 2 : ACCÈS RELAYÉ (Relayer paie le gaz, Trader signe via EIP-712)
       ────────────────────────────────────────────────────────────────────────── */

    function executeOpenMarket(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, uint256 deadline, bytes calldata oracleProof, bytes calldata signature) external whenNotPaused {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(OPEN_MARKET_TYPEHASH, trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, nonce, deadline));
        _verify(trader, structHash, signature);
        core.openMarketPositionFor(trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof);
    }

    function executePlaceOrder(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit, uint256 deadline, bytes calldata signature) external whenNotPaused {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(PLACE_ORDER_TYPEHASH, trader, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit, nonce, deadline));
        _verify(trader, structHash, signature);
        core.placeOrderFor(trader, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit);
    }

    function executeCloseMarket(address trader, uint256 tradeId, uint256 deadline, bytes calldata oracleProof, bytes calldata signature) external whenNotPaused {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(CLOSE_MARKET_TYPEHASH, trader, tradeId, nonce, deadline));
        _verify(trader, structHash, signature);
        core.closePositionMarketFor(trader, tradeId, oracleProof);
    }

    function executeUpdateSLTP(address trader, uint256 tradeId, uint48 newSL, uint48 newTP, uint256 deadline, bytes calldata signature) external whenNotPaused {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(UPDATE_SLTP_TYPEHASH, trader, tradeId, newSL, newTP, nonce, deadline));
        _verify(trader, structHash, signature);
        core.updateSLTPFor(trader, tradeId, newSL, newTP);
    }

    function executeCancelOrder(address trader, uint256 tradeId, uint256 deadline, bytes calldata signature) external whenNotPaused {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(CANCEL_ORDER_TYPEHASH, trader, tradeId, nonce, deadline));
        _verify(trader, structHash, signature);
        core.cancelOrderFor(trader, tradeId);
    }

    function executeAddMargin(address trader, uint256 tradeId, uint64 amount6, uint256 deadline, bytes calldata signature) external whenNotPaused {
        require(block.timestamp <= deadline, "DEADLINE_EXPIRED");
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(ADD_MARGIN_TYPEHASH, trader, tradeId, amount6, nonce, deadline));
        _verify(trader, structHash, signature);
        core.addMarginFor(trader, tradeId, amount6);
    }
}
