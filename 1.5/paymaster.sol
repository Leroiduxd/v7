// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* ────────────────────────── Interface Synchronisée + Lecture Data ────────────────────────── */

interface IBrokexCore {
    // Structure Trade (identique au Core)
    struct Trade {
        address trader;
        uint32 assetId;
        bool isLong;
        bool isLimit;
        uint8 leverage;
        uint48 openPrice;        
        uint8 state; 
        uint32 openTimestamp;
        uint128 fundingIndex;
        uint48 closePrice;       
        int32 lotSize;
        int32 closedLotSize; 
        uint48 stopLoss;
        uint48 takeProfit;
        uint64 lpLockedCapital;
        uint64 marginUsdc;
    }

    // ✅ CRUCIAL : Permet au Paymaster de savoir quel sera le prochain ID
    function nextTradeID() external view returns (uint256);

    // Getter automatique du mapping trades
    function trades(uint256 tradeId) external view returns (Trade memory);

    // --- Fonctions d'écriture ---
    function openMarketPosition(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external;
    function placeOrder(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external;
    function closePositionMarket(address trader, uint256 tradeId, int32 lotsToClose, bytes calldata oracleProof) external;
    function updateSLTP(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external;
    function cancelOrder(address trader, uint256 tradeId) external;
    function addMargin(address trader, uint256 tradeId, uint64 amount6) external;

    // --- Getters Automatiques des Mappings Publics du Core ---
    
    function exposures(uint32 assetId) external view returns (
        int32 longLots, int32 shortLots, uint128 longValueSum, uint128 shortValueSum,
        uint128 longMaxProfit, uint128 shortMaxProfit, uint128 longMaxLoss, uint128 shortMaxLoss
    );

    function assets(uint32 assetId) external view returns (
        uint32 assetId_, uint32 numerator, uint32 denominator, uint32 baseFundingRate,
        uint32 spread, uint32 commission, uint32 weekendFunding, uint16 securityMultiplier,
        uint16 maxPhysicalMove, uint8 maxLeverage, uint32 maxLongLots, uint32 maxShortLots,
        uint32 maxOracleDelay, bool allowOpen, bool listed
    );
    
    // Pour lire l'état du funding
    function fundingStates(uint32 assetId) external view returns (uint64 lastUpdate, uint128 longFundingIndex, uint128 shortFundingIndex);
}

/* ────────────────────────── Brokex Paymaster V4.7 (Relay + Lens - Off-Chain DB Ready) ────────────────────────── */

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
        "CloseMarket(address trader,uint256 tradeId,int32 lotsToClose,uint256 nonce,uint256 deadline)"
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
        int32 lotsToClose,
        uint256 deadline,
        bytes calldata oracleProof, 
        bytes calldata signature
    ) external whenNotPaused {
        _checkDeadline(deadline);
        uint256 nonce = _useNonce(trader);
        bytes32 structHash = keccak256(abi.encode(CLOSE_MARKET_TYPEHASH, trader, tradeId, lotsToClose, nonce, deadline));
        _verify(trader, structHash, signature);
        
        core.closePositionMarket(trader, tradeId, lotsToClose, oracleProof);
    }

    function closePositionMarket(uint256 tradeId, int32 lotsToClose, bytes calldata oracleProof) external whenNotPaused {
        core.closePositionMarket(msg.sender, tradeId, lotsToClose, oracleProof);
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
        
        core.updateSLTP(trader, tradeId, newSL, newTP);
    }

    function updateSLTP(uint256 tradeId, uint48 newSL, uint48 newTP) external whenNotPaused {
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
        
        core.cancelOrder(trader, tradeId);
    }

    function cancelOrder(uint256 tradeId) external whenNotPaused {
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

    // =========================================================================
    //              7. VIEWS UTILITAIRES (Pour le Fetching de masse)
    // =========================================================================

    /**
     * @notice Récupère uniquement les états (state) d'une liste de trades.
     */
    function getTradeStatesFromList(uint256[] calldata tradeIds) external view returns (uint8[] memory states) {
        uint256 len = tradeIds.length;
        if (len > 1000) revert("List too long");

        states = new uint8[](len);
        for (uint256 i = 0; i < len; i++) {
            IBrokexCore.Trade memory t = core.trades(tradeIds[i]);
            states[i] = t.state;
        }
    }

    /**
     * @notice ✅ NOUVEAU : Récupère les structures complètes (Trade) pour une liste d'IDs.
     * Idéal pour initialiser un dashboard avec les trades d'un utilisateur récupérés en DB.
     */
    function getTradesFromList(uint256[] calldata tradeIds) external view returns (IBrokexCore.Trade[] memory fetchedTrades) {
        uint256 len = tradeIds.length;
        if (len > 1000) revert("List too long");

        fetchedTrades = new IBrokexCore.Trade[](len);
        for (uint256 i = 0; i < len; i++) {
            fetchedTrades[i] = core.trades(tradeIds[i]);
        }
    }

    /**
     * @notice ✅ NOUVEAU : Récupère les Stop Loss et Take Profit d'une liste précise de trades.
     */
    function getSLTPFromList(uint256[] calldata tradeIds) external view returns (uint48[] memory stopLosses, uint48[] memory takeProfits) {
        uint256 len = tradeIds.length;
        if (len > 1000) revert("List too long");

        stopLosses = new uint48[](len);
        takeProfits = new uint48[](len);

        for (uint256 i = 0; i < len; i++) {
            IBrokexCore.Trade memory t = core.trades(tradeIds[i]);
            stopLosses[i] = t.stopLoss;
            takeProfits[i] = t.takeProfit;
        }
    }

    /**
     * @notice ✅ NOUVEAU : Récupère les Stop Loss et Take Profit d'une plage (range) continue de trades.
     */
    function getSLTPFromRange(uint256 startTradeId, uint256 count) external view returns (uint48[] memory stopLosses, uint48[] memory takeProfits) {
        if (count > 1000) revert("Range too large");

        stopLosses = new uint48[](count);
        takeProfits = new uint48[](count);

        for (uint256 i = 0; i < count; i++) {
            IBrokexCore.Trade memory t = core.trades(startTradeId + i);
            stopLosses[i] = t.stopLoss;
            takeProfits[i] = t.takeProfit;
        }
    }

    // =========================================================================
    //              8. EX-CORE VIEWS (LENS PATTERN)
    // =========================================================================

    // Cette fonction lit les mappings bruts du Core pour calculer les stats
    function getExposureAndAveragePrices(uint32 assetId) external view returns (uint32 longLots, uint32 shortLots, uint256 avgLongPrice, uint256 avgShortPrice) {
        (
            int32 _longLots, int32 _shortLots, 
            uint128 _longValueSum, uint128 _shortValueSum,
            , , , 
        ) = core.exposures(assetId);

        longLots = uint32(_longLots);
        shortLots = uint32(_shortLots);
        
        if (_longLots > 0) avgLongPrice = uint256(_longValueSum) / uint256(uint32(_longLots));
        if (_shortLots > 0) avgShortPrice = uint256(_shortValueSum) / uint256(uint32(_shortLots));
    }

    function getAssetRiskLimits(uint32 assetId) external view returns (uint32 maxLong, uint32 maxShort, uint32 oracleDelay, bool isOpenAllowed) {
        (
            , , , , , , , , , , 
            uint32 _maxLongLots, uint32 _maxShortLots, uint32 _maxOracleDelay, 
            bool _allowOpen, 
        ) = core.assets(assetId);

        return (_maxLongLots, _maxShortLots, _maxOracleDelay, _allowOpen);
    }

    // =========================================================================
    //              9. FUNDING RATE LENS
    // =========================================================================

    /**
     * @notice Calcule l'index de funding théorique en temps réel (Lens via Paymaster).
     */
    function getLiveFundingIndices(uint32 assetId) external view returns (uint128 longIdx, uint128 shortIdx) {
        (uint64 lastUpdate, uint128 longFundingIndex, uint128 shortFundingIndex) = core.fundingStates(assetId);
        
        (int32 longLots, int32 shortLots, , , , , , ) = core.exposures(assetId);
        ( , , , uint32 baseFundingRate, , , , , , , , , , , ) = core.assets(assetId);

        longIdx = longFundingIndex;
        shortIdx = shortFundingIndex;

        if (block.timestamp > lastUpdate && lastUpdate != 0) {
            uint256 timePassed = block.timestamp - lastUpdate;

            uint256 L = uint256(longLots > 0 ? uint256(int256(longLots)) : 0);
            uint256 S = uint256(shortLots > 0 ? uint256(int256(shortLots)) : 0);
            
            (uint256 longRateHourly, uint256 shortRateHourly) = _computeFundingRateQuadratic(L, S, uint256(baseFundingRate));

            longIdx += uint128((longRateHourly * timePassed) / 3600);
            shortIdx += uint128((shortRateHourly * timePassed) / 3600);
        }
    }

    /**
     * @notice Copie pure de la formule du Core pour simuler le taux (Zéro Gas).
     */
    function _computeFundingRateQuadratic(uint256 L, uint256 S, uint256 baseFunding) internal pure returns (uint256 longRate, uint256 shortRate) {
        if (L == S) return (baseFunding, baseFunding);
        uint256 numerator = (L > S) ? (L - S) : (S - L);
        uint256 denominator = L + S + 2;
        uint256 r = (numerator * 1e18) / denominator;
        uint256 p = (r * r) / 1e18;
        uint256 dominantRate = (baseFunding * (1e18 + 3 * p)) / 1e18;
        if (L > S) return (dominantRate, baseFunding);
        else return (baseFunding, dominantRate);
    }
}
