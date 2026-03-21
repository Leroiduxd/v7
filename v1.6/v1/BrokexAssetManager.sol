// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./BrokexLibrary.sol";

// ==========================================
// INTERFACES
// ==========================================
interface IBrokexAssetManager {
    function getAsset(uint32 assetId) external view returns (BrokexLibrary.Asset memory);
    function listedAssetsCount() external view returns (uint256);
}

// Interface pour lire l'exposition depuis le Core
interface IBrokexCoreState {
    // Getter automatique généré par Solidity pour un public mapping de la struct Exposure
    function exposures(uint32 assetId) external view returns (
        int32 longLots,
        int32 shortLots,
        uint128 longValueSum,
        uint128 shortValueSum,
        uint128 longMaxProfit,
        uint128 shortMaxProfit,
        uint128 longMaxLoss,
        uint128 shortMaxLoss,
        uint128 currentLpLock,
        uint128 needLock
    );
}

// ==========================================
// CONTRACT
// ==========================================
contract BrokexAssetManager is IBrokexAssetManager {
    // ----------------------------------------------------------------
    // ERRORS
    // ----------------------------------------------------------------
    error NotOwner();
    error NotAuthorized();
    error ZeroAddr();
    error AlreadyListed();
    error BadRatio();
    error UnknownAsset();
    error DelayTooShort();
    error DelayTooLong();
    error AlphaCutTooHigh();
    error AlphaScaleTooLow();
    error MinCoverTooLow();
    error BadImbalanceParams();
    error ImbalanceBufferTooLow();
    error ExposureNotZero(); // Revert si exposition ouverte
    error CoreAlreadySet();

    // ----------------------------------------------------------------
    // STATE & CONSTANTS
    // ----------------------------------------------------------------
    address public immutable owner;
    address public riskManager;
    
    // Ajout de la référence vers le Core
    IBrokexCoreState public brokexCore;

    mapping(uint32 => BrokexLibrary.Asset) public assets;
    uint256 public override listedAssetsCount;

    uint128 public constant MIN_IMBALANCE_BUFFER_USD6 = 1_000 * 1e6;
    uint128 public constant DEFAULT_IMBALANCE_BUFFER_USD6 = 5_000 * 1e6;
    uint128 public constant DEFAULT_IMBALANCE_K_USD6 = 10_000 * 1e6;

    uint16 public constant DEFAULT_IMBALANCE_MAX_RATIO_BPS = 40000;
    uint16 public constant DEFAULT_IMBALANCE_MIN_RATIO_BPS = 10500;
    uint16 public constant MAX_IMBALANCE_MAX_RATIO_BPS = 40000;
    uint16 public constant MIN_IMBALANCE_MIN_RATIO_BPS = 10500;
    uint16 public constant DEFAULT_MAX_ASSET_LOCK_BPS = 1000;
    uint16 public constant MAX_ALPHA_CUT_BPS = 2000;
    uint32 public constant MIN_ALPHA_SCALE = 100;
    uint16 public constant MIN_LOCAL_COVER_BPS = 8500;

    // ----------------------------------------------------------------
    // MODIFIERS
    // ----------------------------------------------------------------
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRiskManagerOrOwner() {
        if (msg.sender != owner) {
            if (riskManager == address(0) || msg.sender != riskManager) {
                revert NotAuthorized();
            }
        }
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ----------------------------------------------------------------
    // ADMIN
    // ----------------------------------------------------------------
    function setRiskManager(address _riskManager) external onlyOwner {
        riskManager = _riskManager;
    }

    // Lie ce contrat au Core pour pouvoir lire les expositions
    function setBrokexCore(address _core) external onlyOwner {
        // On bloque si l'adresse a déjà été configurée
        if (address(brokexCore) != address(0)) revert CoreAlreadySet();
        if (_core == address(0)) revert ZeroAddr();
        
        brokexCore = IBrokexCoreState(_core);
    }

    // ----------------------------------------------------------------
    // VIEWS
    // ----------------------------------------------------------------
    function getAsset(uint32 assetId) external view override returns (BrokexLibrary.Asset memory) {
        return assets[assetId];
    }

    // Vérifie qu'aucune position n'est ouverte sur l'actif
    function _checkZeroExposure(uint32 assetId) internal view {
        // On s'assure que le core est bien configuré avant de faire l'appel
        if (address(brokexCore) != address(0)) {
            (int32 longLots, int32 shortLots, , , , , , , , ) = brokexCore.exposures(assetId);
            if (longLots != 0 || shortLots != 0) revert ExposureNotZero();
        }
    }

    // ----------------------------------------------------------------
    // ASSET MANAGEMENT
    // ----------------------------------------------------------------
    function listAsset(
        uint32 assetId,
        uint32 numerator,
        uint32 denominator,
        uint64 baseFundingRate,
        uint64 spread,
        uint32 commission,
        uint64 weekendFunding,
        uint16 securityMultiplier,
        uint16 maxPhysicalMove,
        uint8 maxLeverage
    ) external onlyOwner {
        if (assets[assetId].listed) revert AlreadyListed();
        if (numerator == 0 || denominator == 0) revert BadRatio();

        assets[assetId] = BrokexLibrary.Asset({
            assetId: assetId,
            numerator: numerator,
            denominator: denominator,
            baseFundingRate: baseFundingRate,
            spread: spread,
            commission: commission,
            weekendFunding: weekendFunding,
            securityMultiplier: securityMultiplier,
            maxPhysicalMove: maxPhysicalMove,
            maxLeverage: maxLeverage,
            maxLongLots: 1000000,
            maxShortLots: 1000000,
            maxOracleDelay: 60,
            alphaCutBps: 0,
            alphaScale: 1000000,
            minCoverBps: 10000,
            allowOpen: true,
            listed: true,
            imbalanceBufferUsd6: DEFAULT_IMBALANCE_BUFFER_USD6,
            imbalanceKUsd6: DEFAULT_IMBALANCE_K_USD6,
            imbalanceMaxRatioBps: DEFAULT_IMBALANCE_MAX_RATIO_BPS,
            imbalanceMinRatioBps: DEFAULT_IMBALANCE_MIN_RATIO_BPS,
            maxAssetLockBps: DEFAULT_MAX_ASSET_LOCK_BPS
        });

        listedAssetsCount++;
    }

    function removeAsset(uint32 assetId) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        
        // Bloque la suppression si des lots sont ouverts
        _checkZeroExposure(assetId);
        
        delete assets[assetId];
        listedAssetsCount--; // Ne pas oublier de décrémenter le compteur de listing
    }

    function updateLotSize(
        uint32 assetId,
        uint32 newNum,
        uint32 newDen
    ) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        if (newNum == 0 || newDen == 0) revert BadRatio();
        
        // Bloque le changement de num/den si des lots sont ouverts (empêche les bugs de PnL)
        _checkZeroExposure(assetId);
        
        assets[assetId].numerator = newNum;
        assets[assetId].denominator = newDen;
    }

    function setAssetFees(
        uint32 assetId,
        uint64 newSpreadWad,
        uint32 newCommission
    ) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].spread = newSpreadWad;
        assets[assetId].commission = newCommission;
    }

    function setAssetImbalanceParams(
        uint32 assetId,
        uint128 newBufferUsd6,
        uint128 newKUsd6,
        uint16 newMaxRatioBps,
        uint16 newMinRatioBps,
        uint16 newMaxAssetLockBps
    ) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();

        if (newBufferUsd6 < MIN_IMBALANCE_BUFFER_USD6) revert ImbalanceBufferTooLow();
        if (newKUsd6 == 0) revert BadImbalanceParams();
        if (newMaxRatioBps < 10000 || newMaxRatioBps > MAX_IMBALANCE_MAX_RATIO_BPS) revert BadImbalanceParams();
        if (newMinRatioBps < MIN_IMBALANCE_MIN_RATIO_BPS || newMinRatioBps > newMaxRatioBps) revert BadImbalanceParams();
        if (newMaxAssetLockBps == 0 || newMaxAssetLockBps > 10000) revert BadImbalanceParams();

        assets[assetId].imbalanceBufferUsd6 = newBufferUsd6;
        assets[assetId].imbalanceKUsd6 = newKUsd6;
        assets[assetId].imbalanceMaxRatioBps = newMaxRatioBps;
        assets[assetId].imbalanceMinRatioBps = newMinRatioBps;
        assets[assetId].maxAssetLockBps = newMaxAssetLockBps;
    }

    function setAssetFundingRates(
        uint32 assetId,
        uint64 newBaseFundingWad,
        uint64 newWeekendFundingWad
    ) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].baseFundingRate = newBaseFundingWad;
        assets[assetId].weekendFunding = newWeekendFundingWad;
    }

    function setAssetRiskParams(
        uint32 assetId,
        uint16 newSecMult,
        uint16 newMaxPhys,
        uint8 newMaxLev
    ) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].securityMultiplier = newSecMult;
        assets[assetId].maxPhysicalMove = newMaxPhys;
        assets[assetId].maxLeverage = newMaxLev;
    }

    function setAssetOracleDelay(
        uint32 assetId,
        uint32 newDelay
    ) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        if (newDelay < 15) revert DelayTooShort();
        if (newDelay > 90) revert DelayTooLong();
        assets[assetId].maxOracleDelay = newDelay;
    }

    function setAssetRiskLimits(
        uint32 assetId,
        uint32 _maxLongLots,
        uint32 _maxShortLots
    ) external onlyRiskManagerOrOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].maxLongLots = _maxLongLots;
        assets[assetId].maxShortLots = _maxShortLots;
    }

    function setAssetTradable(
        uint32 assetId,
        bool _allowOpen
    ) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].allowOpen = _allowOpen;
    }

    function setAssetAlphaParams(
        uint32 assetId,
        uint16 newAlphaCutBps,
        uint32 newAlphaScale,
        uint16 newMinCoverBps
    ) external onlyRiskManagerOrOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        if (newAlphaCutBps > MAX_ALPHA_CUT_BPS) revert AlphaCutTooHigh();
        if (newAlphaScale < MIN_ALPHA_SCALE) revert AlphaScaleTooLow();
        if (newMinCoverBps < MIN_LOCAL_COVER_BPS) revert MinCoverTooLow();

        assets[assetId].alphaCutBps = newAlphaCutBps;
        assets[assetId].alphaScale = newAlphaScale;
        assets[assetId].minCoverBps = newMinCoverBps;
    }
}
