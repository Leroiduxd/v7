// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IBrokexAssetManager {
    struct Asset {
        uint32 assetId;
        uint32 numerator;
        uint32 denominator;
        uint64 baseFundingRate;
        uint64 spread;
        uint32 commission;
        uint64 weekendFunding;
        uint16 securityMultiplier;
        uint16 maxPhysicalMove;
        uint8 maxLeverage;
        uint32 maxLongLots;
        uint32 maxShortLots;
        uint32 maxOracleDelay;
        uint16 alphaCutBps;
        uint32 alphaScale;
        uint16 minCoverBps;
        bool allowOpen;
        bool listed;

        // --- anti-imbalance / concentration ---
        uint128 imbalanceBufferUsd6;   // ex: 5_000e6
        uint128 imbalanceKUsd6;        // ex: 10_000e6
        uint16 imbalanceMaxRatioBps;   // ex: 40000 = 4.00x
        uint16 imbalanceMinRatioBps;   // ex: 10500 = 1.05x
        uint16 maxAssetLockBps;        // ex: 1000 = 10%
    }

    function getAsset(uint32 assetId) external view returns (Asset memory);
    function listedAssetsCount() external view returns (uint256);
}

contract BrokexAssetManager is IBrokexAssetManager {
    // =========================================================
    // ERRORS
    // =========================================================
    error NotOwner();
    error NotAuthorized();
    error ZeroAddr();
    error AlreadyListed();
    error UnknownAsset();
    error BadRatio();
    error DelayTooShort();
    error DelayTooLong();
    error AlphaCutTooHigh();
    error AlphaScaleTooLow();
    error MinCoverTooLow();
    error BadImbalanceParams();
    error ImbalanceBufferTooLow();
    error ExposureNotZero(); // gardé si tu veux empêcher remove sur actif "utilisé" via flag externe
    error AssetNotListed();

    // =========================================================
    // EVENTS
    // =========================================================
    event RiskManagerUpdated(address indexed newRiskManager);
    event AssetListed(uint32 indexed assetId);
    event AssetRemoved(uint32 indexed assetId);
    event AssetFeesUpdated(uint32 indexed assetId, uint64 spread, uint32 commission);
    event AssetFundingUpdated(uint32 indexed assetId, uint64 baseFundingRate, uint64 weekendFunding);
    event AssetRiskParamsUpdated(uint32 indexed assetId, uint16 securityMultiplier, uint16 maxPhysicalMove, uint8 maxLeverage);
    event AssetOracleDelayUpdated(uint32 indexed assetId, uint32 maxOracleDelay);
    event AssetRiskLimitsUpdated(uint32 indexed assetId, uint32 maxLongLots, uint32 maxShortLots);
    event AssetTradableUpdated(uint32 indexed assetId, bool allowOpen);
    event AssetAlphaParamsUpdated(uint32 indexed assetId, uint16 alphaCutBps, uint32 alphaScale, uint16 minCoverBps);
    event AssetImbalanceParamsUpdated(
        uint32 indexed assetId,
        uint128 imbalanceBufferUsd6,
        uint128 imbalanceKUsd6,
        uint16 imbalanceMaxRatioBps,
        uint16 imbalanceMinRatioBps,
        uint16 maxAssetLockBps
    );
    event AssetLotSizeUpdated(uint32 indexed assetId, uint32 numerator, uint32 denominator);

    // =========================================================
    // STATE
    // =========================================================
    address public immutable owner;
    address public riskManager;

    mapping(uint32 => Asset) internal _assets;
    uint256 public override listedAssetsCount;

    // =========================================================
    // CONSTANTS
    // =========================================================
    uint16 public constant MAX_ALPHA_CUT_BPS = 2000;        // alpha min = 80%
    uint32 public constant MIN_ALPHA_SCALE = 100;
    uint16 public constant MIN_LOCAL_COVER_BPS = 8500;      // 85%

    uint128 public constant MIN_IMBALANCE_BUFFER_USD6 = 1_000 * 1e6;      // 1 000$
    uint128 public constant DEFAULT_IMBALANCE_BUFFER_USD6 = 5_000 * 1e6;  // 5 000$
    uint128 public constant DEFAULT_IMBALANCE_K_USD6 = 10_000 * 1e6;      // 10 000$

    uint16 public constant DEFAULT_IMBALANCE_MAX_RATIO_BPS = 40000;       // 4.00x
    uint16 public constant DEFAULT_IMBALANCE_MIN_RATIO_BPS = 10500;       // 1.05x
    uint16 public constant MAX_IMBALANCE_MAX_RATIO_BPS = 40000;           // max autorisé
    uint16 public constant MIN_IMBALANCE_MIN_RATIO_BPS = 10500;           // min autorisé
    uint16 public constant DEFAULT_MAX_ASSET_LOCK_BPS = 1000;             // 10%

    uint32 public constant DEFAULT_MAX_LONG_LOTS = 1_000_000;
    uint32 public constant DEFAULT_MAX_SHORT_LOTS = 1_000_000;
    uint32 public constant DEFAULT_MAX_ORACLE_DELAY = 60;
    uint32 public constant MIN_ORACLE_DELAY = 15;
    uint32 public constant MAX_ORACLE_DELAY = 90;

    // =========================================================
    // MODIFIERS
    // =========================================================
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

    // =========================================================
    // CONSTRUCTOR
    // =========================================================
    constructor() {
        owner = msg.sender;
    }

    // =========================================================
    // ADMIN
    // =========================================================
    function setRiskManager(address _riskManager) external onlyOwner {
        riskManager = _riskManager;
        emit RiskManagerUpdated(_riskManager);
    }

    // =========================================================
    // VIEWS
    // =========================================================
    function getAsset(uint32 assetId) external view override returns (Asset memory) {
        return _assets[assetId];
    }

    function isListed(uint32 assetId) external view returns (bool) {
        return _assets[assetId].listed;
    }

    // =========================================================
    // ASSET MANAGEMENT
    // =========================================================
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
        if (_assets[assetId].listed) revert AlreadyListed();
        if (numerator == 0 || denominator == 0) revert BadRatio();

        _assets[assetId] = Asset({
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
            maxLongLots: DEFAULT_MAX_LONG_LOTS,
            maxShortLots: DEFAULT_MAX_SHORT_LOTS,
            maxOracleDelay: DEFAULT_MAX_ORACLE_DELAY,
            alphaCutBps: 0,
            alphaScale: 1_000_000,
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
        emit AssetListed(assetId);
    }

    function removeAsset(uint32 assetId) external onlyOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();

        delete _assets[assetId];
        listedAssetsCount--;

        emit AssetRemoved(assetId);
    }

    function updateLotSize(
        uint32 assetId,
        uint32 newNum,
        uint32 newDen
    ) external onlyOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();
        if (newNum == 0 || newDen == 0) revert BadRatio();

        _assets[assetId].numerator = newNum;
        _assets[assetId].denominator = newDen;

        emit AssetLotSizeUpdated(assetId, newNum, newDen);
    }

    function setAssetFees(
        uint32 assetId,
        uint64 newSpreadWad,
        uint32 newCommission
    ) external onlyOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();

        _assets[assetId].spread = newSpreadWad;
        _assets[assetId].commission = newCommission;

        emit AssetFeesUpdated(assetId, newSpreadWad, newCommission);
    }

    function setAssetFundingRates(
        uint32 assetId,
        uint64 newBaseFundingWad,
        uint64 newWeekendFundingWad
    ) external onlyOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();

        _assets[assetId].baseFundingRate = newBaseFundingWad;
        _assets[assetId].weekendFunding = newWeekendFundingWad;

        emit AssetFundingUpdated(assetId, newBaseFundingWad, newWeekendFundingWad);
    }

    function setAssetRiskParams(
        uint32 assetId,
        uint16 newSecMult,
        uint16 newMaxPhys,
        uint8 newMaxLev
    ) external onlyOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();

        _assets[assetId].securityMultiplier = newSecMult;
        _assets[assetId].maxPhysicalMove = newMaxPhys;
        _assets[assetId].maxLeverage = newMaxLev;

        emit AssetRiskParamsUpdated(assetId, newSecMult, newMaxPhys, newMaxLev);
    }

    function setAssetOracleDelay(
        uint32 assetId,
        uint32 newDelay
    ) external onlyOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();
        if (newDelay < MIN_ORACLE_DELAY) revert DelayTooShort();
        if (newDelay > MAX_ORACLE_DELAY) revert DelayTooLong();

        _assets[assetId].maxOracleDelay = newDelay;

        emit AssetOracleDelayUpdated(assetId, newDelay);
    }

    function setAssetRiskLimits(
        uint32 assetId,
        uint32 newMaxLongLots,
        uint32 newMaxShortLots
    ) external onlyRiskManagerOrOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();

        _assets[assetId].maxLongLots = newMaxLongLots;
        _assets[assetId].maxShortLots = newMaxShortLots;

        emit AssetRiskLimitsUpdated(assetId, newMaxLongLots, newMaxShortLots);
    }

    function setAssetTradable(
        uint32 assetId,
        bool allowOpen
    ) external onlyOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();

        _assets[assetId].allowOpen = allowOpen;

        emit AssetTradableUpdated(assetId, allowOpen);
    }

    function setAssetAlphaParams(
        uint32 assetId,
        uint16 newAlphaCutBps,
        uint32 newAlphaScale,
        uint16 newMinCoverBps
    ) external onlyRiskManagerOrOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();

        if (newAlphaCutBps > MAX_ALPHA_CUT_BPS) revert AlphaCutTooHigh();
        if (newAlphaScale < MIN_ALPHA_SCALE) revert AlphaScaleTooLow();
        if (newMinCoverBps < MIN_LOCAL_COVER_BPS) revert MinCoverTooLow();

        _assets[assetId].alphaCutBps = newAlphaCutBps;
        _assets[assetId].alphaScale = newAlphaScale;
        _assets[assetId].minCoverBps = newMinCoverBps;

        emit AssetAlphaParamsUpdated(assetId, newAlphaCutBps, newAlphaScale, newMinCoverBps);
    }

    function setAssetImbalanceParams(
        uint32 assetId,
        uint128 newBufferUsd6,
        uint128 newKUsd6,
        uint16 newMaxRatioBps,
        uint16 newMinRatioBps,
        uint16 newMaxAssetLockBps
    ) external onlyOwner {
        if (!_assets[assetId].listed) revert UnknownAsset();

        if (newBufferUsd6 < MIN_IMBALANCE_BUFFER_USD6) {
            revert ImbalanceBufferTooLow();
        }

        if (newKUsd6 == 0) revert BadImbalanceParams();

        if (
            newMaxRatioBps < 10000 ||
            newMaxRatioBps > MAX_IMBALANCE_MAX_RATIO_BPS
        ) {
            revert BadImbalanceParams();
        }

        if (
            newMinRatioBps < MIN_IMBALANCE_MIN_RATIO_BPS ||
            newMinRatioBps > newMaxRatioBps
        ) {
            revert BadImbalanceParams();
        }

        if (newMaxAssetLockBps == 0 || newMaxAssetLockBps > 10000) {
            revert BadImbalanceParams();
        }

        _assets[assetId].imbalanceBufferUsd6 = newBufferUsd6;
        _assets[assetId].imbalanceKUsd6 = newKUsd6;
        _assets[assetId].imbalanceMaxRatioBps = newMaxRatioBps;
        _assets[assetId].imbalanceMinRatioBps = newMinRatioBps;
        _assets[assetId].maxAssetLockBps = newMaxAssetLockBps;

        emit AssetImbalanceParamsUpdated(
            assetId,
            newBufferUsd6,
            newKUsd6,
            newMaxRatioBps,
            newMinRatioBps,
            newMaxAssetLockBps
        );
    }
}
