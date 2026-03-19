// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// ==========================================
// LIBRARY
// ==========================================

library BrokexLibrary {
    // ==========================================
    // 1. DATA STRUCTURES (Moved from Core)
    // ==========================================

    struct Trade {
        address trader;
        uint32 assetId;
        bool isLong;
        bool isLimit;
        uint8 leverage;
        uint48 openPrice;
        uint8 state;
        uint32 openTimestamp;
        uint32 closeTimestamp;
        uint128 fundingIndex;
        uint48 closePrice;
        int32 lotSize;
        int32 closedLotSize;
        uint48 stopLoss;
        uint48 takeProfit;
        uint64 lpLockedCapital;
        uint64 marginUsdc;
        uint64 totalFeesPaidUsdc;
    }

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
    }

    struct Exposure {
        int32 longLots;
        int32 shortLots;
        uint128 longValueSum;
        uint128 shortValueSum;
        uint128 longMaxProfit;
        uint128 shortMaxProfit;
        uint128 longMaxLoss;
        uint128 shortMaxLoss;
        uint128 overlapRisk;
        uint128 currentLpLock;
        uint128 needLock;
    }

    struct FundingState {
        uint64 lastUpdate;
        uint128 longFundingIndex;
        uint128 shortFundingIndex;
    }

    struct PnlRun {
        uint64 runId;
        uint64 startTimestamp;
        uint64 endTimestamp;
        uint32 assetsProcessed;
        uint32 totalAssetsAtStart;
        int256 cumulativePnlX6;
        bool completed;
    }

    // ==========================================
    // 2. MATH & LOGIC FUNCTIONS
    // ==========================================

    function safeSub(uint128 a, uint128 b) internal pure returns (uint128) {
        return (b > a) ? 0 : a - b;
    }

    function getNotionalValue(
        Asset memory a,
        uint256 price,
        uint32 lotSize
    ) internal pure returns (uint256) {
        return
            (price * uint256(lotSize) * uint256(a.numerator)) /
            uint256(a.denominator);
    }

    function validateStops(
        uint256 entryPrice,
        bool isLong,
        uint256 stopLoss,
        uint256 takeProfit
    ) external pure returns (bool, string memory) {
        if (stopLoss == 0 && takeProfit == 0) return (true, "");
        if (stopLoss != 0 && takeProfit != 0 && stopLoss == takeProfit)
            return (false, "SlEqualsTp");

        if (isLong) {
            if (takeProfit > 0 && takeProfit <= entryPrice)
                return (false, "LongTpTooLow");
            if (stopLoss > 0 && stopLoss >= entryPrice)
                return (false, "LongSlTooHigh");
        } else {
            if (takeProfit > 0 && takeProfit >= entryPrice)
                return (false, "ShortTpTooHigh");
            if (stopLoss > 0 && stopLoss <= entryPrice)
                return (false, "ShortSlTooLow");
        }
        return (true, "");
    }

    // ✅ NOUVELLE LOGIQUE V22.2: Renvoie le multiplicateur WAD du spread
    function calculateSpread(
        Asset memory a,
        Exposure memory e,
        bool isLong,
        bool isOpening,
        uint32 lotSize
    ) public pure returns (uint256) {
        uint256 base = uint256(a.spread);

        int256 L = int256(e.longLots);
        int256 S = int256(e.shortLots);
        int256 size = int256(uint256(lotSize));

        if (isLong) {
            if (isOpening) L += size;
            else L -= size;
        } else {
            if (isOpening) S += size;
            else S -= size;
        }

        if (L < 0) L = 0;
        if (S < 0) S = 0;

        uint256 numerator = (L > S) ? uint256(L - S) : uint256(S - L);
        uint256 denominator = uint256(L + S + 2);

        if (denominator == 0) return base;

        uint256 p = ((numerator * 1e18) / denominator) ** 2 / 1e18;
        bool dominant = (L > S && isLong) || (S > L && !isLong);
        return dominant ? (base * (1e18 + 3 * p)) / 1e18 : base;
    }

    // ✅ NOUVELLE LOGIQUE V22.2: Renvoie le Pourcentage WAD cumulé
    function calculateWeekendFunding(
        Trade memory t,
        Asset memory a,
        uint256 currentTimestamp
    ) public pure returns (uint256) {
        if (a.weekendFunding == 0) return 0;

        uint256 closeTs = currentTimestamp;
        if (closeTs <= t.openTimestamp) return 0;

        uint256 offset = 259200;
        uint256 secondsPerWeek = 604800;
        uint256 openWeek = (uint256(t.openTimestamp) + offset) / secondsPerWeek;
        uint256 currentWeek = (closeTs + offset) / secondsPerWeek;

        if (currentWeek <= openWeek) return 0;
        uint256 weekendsCrossed = currentWeek - openWeek;

        return weekendsCrossed * uint256(a.weekendFunding);
    }

    uint256 internal constant BPS = 10000;

    function computeAlpha(
        Asset memory a,
        Exposure memory e
    ) internal pure returns (uint256 alpha) {
        uint256 longSide = uint256(e.longMaxProfit);
        uint256 shortSide = uint256(e.shortMaxProfit);

        uint256 matched = longSide < shortSide ? longSide : shortSide;
        uint256 dominant = longSide > shortSide ? longSide : shortSide;

        if (dominant == 0) return BPS;

        uint256 balance = (matched * BPS) / dominant;

        uint256 depth;
        if (a.alphaScale == 0) {
            depth = BPS;
        } else {
            depth = (matched * BPS) / (matched + uint256(a.alphaScale));
        }

        uint256 cut = (uint256(a.alphaCutBps) * balance * depth) /
            (BPS * BPS);

        if (cut > uint256(a.alphaCutBps)) {
            cut = uint256(a.alphaCutBps);
        }

        alpha = BPS - cut;
    }

    function computeNeedLock(
        Asset memory a,
        Exposure memory e
    ) internal pure returns (uint256 needLock, uint256 alpha) {
        uint256 longSide = uint256(e.longMaxProfit);
        uint256 shortSide = uint256(e.shortMaxProfit);

        uint256 worst = longSide > shortSide ? longSide : shortSide;
        alpha = computeAlpha(a, e);

        needLock = (worst * alpha) / BPS;
    }

    function calculateMargin6(
        Asset memory a,
        uint256 entryPrice,
        uint32 lotSize,
        uint8 leverage
    ) external pure returns (uint256) {
        uint256 notional = getNotionalValue(a, entryPrice, lotSize);
        return notional / uint256(leverage);
    }

    function calculateLockedCapital(
        Asset memory a,
        uint256 entryPrice,
        uint32 lotSize,
        uint8 leverage
    ) external pure returns (uint256) {
        uint256 notional = getNotionalValue(a, entryPrice, lotSize);
        uint256 margin = notional / uint256(leverage);

        uint256 maxProfitLev = (margin * uint256(a.securityMultiplier)) / 100;
        uint256 physMoveVal = (entryPrice * uint256(a.maxPhysicalMove)) / 100;
        uint256 physProfit = getNotionalValue(a, physMoveVal, lotSize);
        return (maxProfitLev < physProfit) ? maxProfitLev : physProfit;
    }

    function calculateCommission6(
        Asset memory a,
        uint256 entryPrice,
        uint32 lotSize
    ) external pure returns (uint256) {
        uint256 notional6 = getNotionalValue(a, entryPrice, lotSize);
        return (notional6 * uint256(a.commission)) / 10000;
    }

    function computeFundingRateQuadratic(
        uint256 L,
        uint256 S,
        uint256 baseFunding
    ) external pure returns (uint256 longRate, uint256 shortRate) {
        if (L == S) return (baseFunding, baseFunding);
        uint256 numerator = (L > S) ? (L - S) : (S - L);
        uint256 denominator = L + S + 2;
        uint256 r = (numerator * 1e18) / denominator;
        uint256 p = (r * r) / 1e18;
        uint256 dominantRate = (baseFunding * (1e18 + 3 * p)) / 1e18;
        if (L > S) return (dominantRate, baseFunding);
        else return (baseFunding, dominantRate);
    }

    // ✅ NOUVELLE LOGIQUE V22.2: PnL avec Spread WAD
    function calculateNetPnl(
        Trade memory t,
        Asset memory a,
        FundingState memory f,
        Exposure memory e,
        uint256 price1e6,
        int32 sizeToCalc,
        uint256 currentTimestamp
    ) external pure returns (int256, uint256, uint256) {
        // ✅ correction : t.isLong et pas !t.isLong
        uint256 spreadWad = calculateSpread(
            a,
            e,
            t.isLong,
            false,
            uint32(sizeToCalc)
        );
        uint256 spreadAmount = (price1e6 * spreadWad) / 1e18;

        uint256 exitPrice;
        if (t.isLong) {
            if (spreadAmount > price1e6) exitPrice = 0;
            else exitPrice = price1e6 - spreadAmount;
        } else {
            exitPrice = price1e6 + spreadAmount;
        }

        int256 delta = t.isLong
            ? int256(exitPrice) - int256(uint256(t.openPrice))
            : int256(uint256(t.openPrice)) - int256(exitPrice);

        int256 lotSize256 = int256(uint256(uint32(sizeToCalc)));
        int256 rawPnl18 = (delta *
            lotSize256 *
            int256(uint256(a.numerator)) *
            1e12) / int256(uint256(a.denominator));

        uint256 currentIdx = t.isLong
            ? f.longFundingIndex
            : f.shortFundingIndex;
        uint256 deltaIndex = currentIdx - t.fundingIndex;

        uint256 exitNotional6 = (exitPrice *
            uint256(uint32(sizeToCalc)) *
            uint256(a.numerator)) / uint256(a.denominator);

        uint256 fundingPaidUsdc = (exitNotional6 * deltaIndex) / 1e18;

        uint256 weekendPercentTotal = calculateWeekendFunding(
            t,
            a,
            currentTimestamp
        );
        uint256 weekendFeesFinal = (exitNotional6 * weekendPercentTotal) / 1e18;

        uint256 extraFeesUsdc = fundingPaidUsdc + weekendFeesFinal;

        int256 finalPnl = rawPnl18 - int256(extraFeesUsdc * 1e12);

        return (finalPnl, exitPrice, extraFeesUsdc);
    }

    function computeLockComponents(
        Exposure storage e
    ) internal view returns (uint256 grossLock, uint256 overlap) {
        uint256 avgLong = 0;
        if (e.longLots > 0) {
            avgLong = uint256(e.longValueSum) / uint256(uint32(e.longLots));
        }

        uint256 avgShort = 0;
        if (e.shortLots > 0) {
            avgShort = uint256(e.shortValueSum) / uint256(uint32(e.shortLots));
        }

        uint256 directional = uint256(e.longMaxProfit) >
            uint256(e.shortMaxProfit)
            ? uint256(e.longMaxProfit)
            : uint256(e.shortMaxProfit);

        overlap = 0;

        if (avgShort > avgLong && e.longLots > 0 && e.shortLots > 0) {
            uint256 matchedLots = uint256(
                uint32(e.longLots < e.shortLots ? e.longLots : e.shortLots)
            );
            overlap = (avgShort - avgLong) * matchedLots;
        }

        grossLock = directional + overlap;
    }

    function calculateAssetPnlCapped(
        Exposure memory e,
        Asset memory a,
        uint256 currentPrice1e6
    ) external pure returns (int256 pnlX6) {
        if (e.longLots == 0 && e.shortLots == 0) return 0;

        int256 longPnl = 0;
        if (e.longLots > 0) {
            uint256 currentVal = (currentPrice1e6 *
                uint256(uint256(int256(e.longLots))) *
                uint256(a.numerator)) / uint256(a.denominator);
            uint256 entryVal = uint256(e.longValueSum);
            longPnl = int256(currentVal) - int256(entryVal);
            if (longPnl > 0) {
                if (uint256(longPnl) > uint256(e.longMaxProfit))
                    longPnl = int256(uint256(e.longMaxProfit));
            } else {
                if (uint256(-longPnl) > uint256(e.longMaxLoss))
                    longPnl = -int256(uint256(e.longMaxLoss));
            }
        }

        int256 shortPnl = 0;
        if (e.shortLots > 0) {
            uint256 currentVal = (currentPrice1e6 *
                uint256(uint256(int256(e.shortLots))) *
                uint256(a.numerator)) / uint256(a.denominator);
            uint256 entryVal = uint256(e.shortValueSum);
            shortPnl = int256(entryVal) - int256(currentVal);
            if (shortPnl > 0) {
                if (uint256(shortPnl) > uint256(e.shortMaxProfit))
                    shortPnl = int256(uint256(e.shortMaxProfit));
            } else {
                if (uint256(-shortPnl) > uint256(e.shortMaxLoss))
                    shortPnl = -int256(uint256(e.shortMaxLoss));
            }
        }
        return -(longPnl + shortPnl);
    }
}

// ==========================================
// INTERFACES
// ==========================================

interface ISupraOraclePull {
    struct PriceInfo {
        uint256[] pairs;
        uint256[] prices;
        uint256[] timestamp;
        uint256[] decimal;
        uint256[] round;
    }
    function verifyOracleProofV2(
        bytes calldata _bytesProof
    ) external returns (PriceInfo memory);
}

interface IBrokexVault {
    function lockTraderFunds(address trader, uint256 amount6) external;
    function unlockTraderFunds(address trader, uint256 amount6) external;
    function lockLpCapital(uint256 amount6) external;
    function unlockLpCapital(uint256 amount6) external;
    function collectCommissionFromLocked(
        address trader,
        uint256 commission6
    ) external;
    function settlePnl(address trader, int256 pnl6) external;
    function lpFreeCapital() external view returns (uint256);
    function lpLockedCapital() external view returns (uint256);
}

// ==========================================
// CONTRACT CORE
// ==========================================

contract BrokexCore {
    // ----------------------------------------------------------------
    // ERRORS
    // ----------------------------------------------------------------
    error NotOwner();
    error NotPaymaster();
    error ZeroAddr();
    error AlreadyListed();
    error BadRatio();
    error UnknownAsset();
    error DelayTooShort();
    error DelayTooLong();
    error ExposureNotZero();
    error AssetDeleted();
    error CloseOnlyMode();
    error BadSize();
    error BadLev();
    error MaxLongLimit();
    error MaxShortLimit();
    error NotPending();
    error PriceBad();
    error NotOpen();
    error NotYourTrade();
    error NotLiq();
    error NotTriggered();
    error Closed();
    error TraderMismatch();
    error PairNotInProof();
    error FutureProof();
    error StalePrice();
    error Mismatch();
    error SlEqualsTp();
    error LongTpTooLow();
    error LongSlTooHigh();
    error ShortTpTooHigh();
    error ShortSlTooLow();
    error PnlUnderCap();
    error NotAuthorized();

    // ----------------------------------------------------------------
    // CONSTANTES & STATE
    // ----------------------------------------------------------------

    uint256 constant SECONDS_PER_WEEK = 604800;
    uint256 constant OFFSET_TO_MONDAY = 259200;

    ISupraOraclePull public immutable oracle;
    IBrokexVault public brokexVault;
    address public immutable owner;

    address public paymaster;
    address public riskManager;
    address public libraryAddress;

    uint256 public nextTradeID;
    uint256 public listedAssetsCount;

    uint256 public totalNeedLock;
    uint16 public minGlobalCoverBps = 9000;

    // Mappings using Structs from Library
    mapping(uint256 => BrokexLibrary.Trade) public trades;
    mapping(uint32 => BrokexLibrary.Asset) public assets;
    mapping(uint32 => BrokexLibrary.Exposure) public exposures;
    mapping(uint32 => BrokexLibrary.FundingState) public fundingStates;

    uint64 public currentPnlRunId;
    mapping(uint64 => BrokexLibrary.PnlRun) public pnlRuns;
    mapping(uint64 => mapping(uint32 => bool)) public assetProcessedInRun;
    bool public pnlCalculationActive;

    event TradeEvent(uint256 tradeId, uint8 code);
    event PnlRunStarted(uint64 runId, uint32 totalAssets);
    event PnlRunCompleted(uint64 runId, int256 finalPnl);
    event PnlRunExpired(uint64 runId);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyPaymaster() {
        if (msg.sender != paymaster) revert NotPaymaster();
        _;
    }
    modifier onlyRiskManagerOrOwner() {
        if (msg.sender != owner) {
            if (riskManager == address(0) || msg.sender != riskManager)
                revert NotAuthorized();
        }
        _;
    }

    constructor(address _oracle, address _libraryAddress) {
        owner = msg.sender;
        oracle = ISupraOraclePull(_oracle);

        require(_libraryAddress != address(0), "Zero Address for Lib");
        libraryAddress = _libraryAddress;
        riskManager = address(0);
    }

    function setBrokexVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddr();
        brokexVault = IBrokexVault(vault);
    }

    function setPaymaster(address _paymaster) external onlyOwner {
        require(paymaster == address(0), "PAYMASTER_ALREADY_SET");
        if (_paymaster == address(0)) revert ZeroAddr();
        paymaster = _paymaster;
    }

    function setRiskManager(address _riskManager) external onlyOwner {
        riskManager = _riskManager;
    }

    // ----------------------------------------------------------------
    // 3. ORACLE HELPER
    // ----------------------------------------------------------------

    function _extractPriceFromInfo(
        ISupraOraclePull.PriceInfo memory info,
        uint32 _assetId
    ) internal view returns (uint256 price1e6) {
        uint256 len = info.pairs.length;
        bool found = false;
        uint256 index;

        for (uint256 i = 0; i < len; i++) {
            if (info.pairs[i] == uint256(_assetId)) {
                index = i;
                found = true;
                break;
            }
        }

        if (!found) revert PairNotInProof();

        uint256 oracleTime = info.timestamp[index];
        if (oracleTime > 1000000000000) {
            oracleTime = oracleTime / 1000;
        }

        if (block.timestamp < oracleTime) revert FutureProof();

        uint256 allowedDelay = uint256(assets[_assetId].maxOracleDelay);
        if (allowedDelay == 0) allowedDelay = 60;

        if (block.timestamp - oracleTime > allowedDelay) revert StalePrice();

        uint256 rawPrice = info.prices[index];
        uint256 decimals = info.decimal[index];

        if (decimals > 6) {
            price1e6 = rawPrice / (10 ** (decimals - 6));
        } else if (decimals < 6) {
            price1e6 = rawPrice * (10 ** (6 - decimals));
        } else {
            price1e6 = rawPrice;
        }
    }

    function _getVerifiedPrice(
        bytes calldata _bytesProof,
        uint32 _assetId
    ) internal returns (uint256) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(
            _bytesProof
        );
        return _extractPriceFromInfo(info, _assetId);
    }

    // ----------------------------------------------------------------
    // 4. ADMIN & ASSET
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
        listed: true
    });
        listedAssetsCount++;
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

    function setAssetFundingRates(
        uint32 assetId,
        uint64 newBaseFundingWad,
        uint64 newWeekendFundingWad
    ) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        _updateFundingRate(assetId);
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

    function removeAsset(uint32 assetId) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        BrokexLibrary.Exposure storage e = exposures[assetId];
        if (e.longLots != 0 || e.shortLots != 0) revert ExposureNotZero();
        delete assets[assetId];
    }

    function updateLotSize(
        uint32 assetId,
        uint32 newNum,
        uint32 newDen
    ) external onlyOwner {
        BrokexLibrary.Exposure storage e = exposures[assetId];
        if (e.longLots != 0 || e.shortLots != 0) revert ExposureNotZero();
        assets[assetId].numerator = newNum;
        assets[assetId].denominator = newDen;
    }

    // ----------------------------------------------------------------
    // 5. EXPOSURE LOGIC
    // ----------------------------------------------------------------

    function _updateExposure(
        uint32 assetId,
        int32 lotSize,
        uint48 price,
        bool isLong,
        bool increase
    ) internal {
        BrokexLibrary.Exposure storage e = exposures[assetId];
        uint256 rawVal = BrokexLibrary.getNotionalValue(
            assets[assetId],
            uint256(price),
            uint32(lotSize)
        );
        uint128 value = uint128(rawVal);

        if (isLong) {
            if (increase) {
                if (
                    uint256(uint256(int256(e.longLots))) +
                        uint256(uint32(lotSize)) >
                    uint256(assets[assetId].maxLongLots)
                ) revert MaxLongLimit();
                e.longLots += lotSize;
                e.longValueSum += value;
            } else {
                e.longLots -= lotSize;
                e.longValueSum = BrokexLibrary.safeSub(e.longValueSum, value);
            }
        } else {
            if (increase) {
                if (
                    uint256(uint256(int256(e.shortLots))) +
                        uint256(uint32(lotSize)) >
                    uint256(assets[assetId].maxShortLots)
                ) revert MaxShortLimit();
                e.shortLots += lotSize;
                e.shortValueSum += value;
            } else {
                e.shortLots -= lotSize;
                e.shortValueSum = BrokexLibrary.safeSub(e.shortValueSum, value);
            }
        }
    }

    function _updateExposureLimits(
        uint32 assetId,
        uint64 lpLocked,
        uint64 margin,
        bool isLong,
        bool increase
    ) internal {
        BrokexLibrary.Exposure storage e = exposures[assetId];
        uint128 locked = uint128(lpLocked);
        uint128 marg = uint128(margin);

        if (isLong) {
            if (increase) {
                e.longMaxProfit += locked;
                e.longMaxLoss += marg;
            } else {
                e.longMaxProfit = BrokexLibrary.safeSub(
                    e.longMaxProfit,
                    locked
                );
                e.longMaxLoss = BrokexLibrary.safeSub(e.longMaxLoss, marg);
            }
        } else {
            if (increase) {
                e.shortMaxProfit += locked;
                e.shortMaxLoss += marg;
            } else {
                e.shortMaxProfit = BrokexLibrary.safeSub(
                    e.shortMaxProfit,
                    locked
                );
                e.shortMaxLoss = BrokexLibrary.safeSub(e.shortMaxLoss, marg);
            }
        }
    }

    function _syncLock(uint32 assetId, bool isClose) internal {
        BrokexLibrary.Exposure storage e = exposures[assetId];

        uint256 oldLock = uint256(e.currentLpLock);
        uint256 oldNeed = uint256(e.needLock);

        (uint256 newNeed, ) = _needLock(assetId);

        if (e.longLots == 0 && e.shortLots == 0) {
            newNeed = 0;
        }

        if (newNeed >= oldNeed) {
            totalNeedLock += (newNeed - oldNeed);
        } else {
            totalNeedLock -= (oldNeed - newNeed);
        }

        uint256 newLock = newNeed;

        if (isClose && newLock > oldLock) {
            newLock = oldLock;
        }

        if (newLock > oldLock) {
            brokexVault.lockLpCapital(newLock - oldLock);
        } else if (oldLock > newLock) {
            brokexVault.unlockLpCapital(oldLock - newLock);
        }

        e.currentLpLock = uint128(newLock);
        e.needLock = uint128(newNeed);
        e.overlapRisk = 0;
    }

    function _needLock(
        uint32 assetId
    ) internal view returns (uint256 needLock, uint256 alpha) {
        return BrokexLibrary.computeNeedLock(
            assets[assetId],
            exposures[assetId]
        );
    }
    // ----------------------------------------------------------------
    // 7. FUNDING RATE
    // ----------------------------------------------------------------

    function updateFundingRates(uint32[] calldata assetIds) external {
        for (uint256 i = 0; i < assetIds.length; i++) {
            _updateFundingRate(assetIds[i]);
        }
    }

    function _updateFundingRate(uint32 assetId) internal {
        BrokexLibrary.FundingState storage f = fundingStates[assetId];
        if (block.timestamp <= f.lastUpdate) return;

        if (f.lastUpdate == 0) {
            f.lastUpdate = uint64(block.timestamp);
            return;
        }

        BrokexLibrary.Exposure memory e = exposures[assetId];
        BrokexLibrary.Asset memory a = assets[assetId];

        uint256 L = uint256(
            int256(e.longLots) > 0 ? uint256(int256(e.longLots)) : 0
        );
        uint256 S = uint256(
            int256(e.shortLots) > 0 ? uint256(int256(e.shortLots)) : 0
        );
        uint256 baseFunding = uint256(a.baseFundingRate);

        (uint256 longRateHourly, uint256 shortRateHourly) = BrokexLibrary
            .computeFundingRateQuadratic(L, S, baseFunding);

        uint256 timePassed = block.timestamp - f.lastUpdate;
        f.longFundingIndex += uint128((longRateHourly * timePassed) / 3600);
        f.shortFundingIndex += uint128((shortRateHourly * timePassed) / 3600);

        f.lastUpdate = uint64(block.timestamp);
    }

    // ----------------------------------------------------------------
    // 10. INTERNAL LOGIC (SHARED)
    // ----------------------------------------------------------------
    function openMarketPosition(
        address trader,
        uint32 assetId,
        bool isLong,
        uint8 leverage,
        int32 lotSize,
        uint48 stopLoss,
        uint48 takeProfit,
        bytes calldata oracleProof
    ) external onlyPaymaster {
        if (!assets[assetId].listed) revert AssetDeleted();
        if (!assets[assetId].allowOpen) revert CloseOnlyMode();
        if (lotSize <= 0) revert BadSize();
        if (leverage < 1 || leverage > assets[assetId].maxLeverage)
            revert BadLev();

        _updateFundingRate(assetId);

        uint256 price1e6 = _getVerifiedPrice(oracleProof, assetId);

        uint256 spreadWad = BrokexLibrary.calculateSpread(
            assets[assetId],
            exposures[assetId],
            isLong,
            true,
            uint32(lotSize)
        );
        uint256 spreadAmount = (price1e6 * spreadWad) / 1e18;
        uint256 entryPrice = isLong
            ? price1e6 + spreadAmount
            : price1e6 - spreadAmount;

        (bool stopsOk, string memory reason) = BrokexLibrary.validateStops(
            entryPrice,
            isLong,
            stopLoss,
            takeProfit
        );
        if (!stopsOk) revert(reason);

        uint256 margin6 = BrokexLibrary.calculateMargin6(
            assets[assetId],
            entryPrice,
            uint32(lotSize),
            leverage
        );

        uint256 lpLocked6 = BrokexLibrary.calculateLockedCapital(
            assets[assetId],
            entryPrice,
            uint32(lotSize),
            leverage
        );

        // ✅ Commission sur le notionnel
        uint256 commission6 = BrokexLibrary.calculateCommission6(
            assets[assetId],
            entryPrice,
            uint32(lotSize)
        );

        uint256 tradeId = ++nextTradeID;
        BrokexLibrary.Trade storage t = trades[tradeId];

        t.trader = trader;
        t.assetId = assetId;
        t.isLong = isLong;
        t.isLimit = false;
        t.leverage = leverage;
        t.openPrice = uint48(entryPrice);
        t.state = 1;
        t.openTimestamp = uint32(block.timestamp);
        t.closeTimestamp = 0;

        BrokexLibrary.FundingState memory fs = fundingStates[assetId];
        t.fundingIndex = isLong ? fs.longFundingIndex : fs.shortFundingIndex;

        t.closePrice = 0;
        t.lotSize = lotSize;
        t.closedLotSize = 0;
        t.stopLoss = stopLoss;
        t.takeProfit = takeProfit;
        t.lpLockedCapital = uint64(lpLocked6);
        t.marginUsdc = uint64(margin6);
        t.totalFeesPaidUsdc = uint64(commission6);

        _updateExposure(assetId, lotSize, uint48(entryPrice), isLong, true);
        _updateExposureLimits(
            assetId,
            uint64(lpLocked6),
            uint64(margin6),
            isLong,
            true
        );

        brokexVault.lockTraderFunds(trader, margin6 + commission6);
        _syncLock(assetId, false);
        brokexVault.collectCommissionFromLocked(trader, commission6);

        emit TradeEvent(tradeId, 1);
    }

    function placeOrder(
        address trader,
        uint32 assetId,
        bool isLong,
        bool isLimit,
        uint8 leverage,
        int32 lotSize,
        uint48 targetPrice,
        uint48 stopLoss,
        uint48 takeProfit
    ) external onlyPaymaster {
        if (!assets[assetId].listed) revert AssetDeleted();
        if (!assets[assetId].allowOpen) revert CloseOnlyMode();
        if (lotSize <= 0) revert BadSize();
        if (leverage < 1 || leverage > assets[assetId].maxLeverage)
            revert BadLev();

        (bool stopsOk, string memory reason) = BrokexLibrary.validateStops(
            uint256(targetPrice),
            isLong,
            stopLoss,
            takeProfit
        );
        if (!stopsOk) revert(reason);

        uint256 margin6 = BrokexLibrary.calculateMargin6(
            assets[assetId],
            uint256(targetPrice),
            uint32(lotSize),
            leverage
        );

        uint256 lpLocked6 = BrokexLibrary.calculateLockedCapital(
            assets[assetId],
            uint256(targetPrice),
            uint32(lotSize),
            leverage
        );

        // ✅ Commission réservée sur le notionnel du targetPrice
        uint256 commission6 = BrokexLibrary.calculateCommission6(
            assets[assetId],
            uint256(targetPrice),
            uint32(lotSize)
        );

        uint256 tradeId = ++nextTradeID;

        trades[tradeId] = BrokexLibrary.Trade({
            trader: trader,
            assetId: assetId,
            isLong: isLong,
            isLimit: isLimit,
            leverage: leverage,
            openPrice: targetPrice,
            state: 0,
            openTimestamp: uint32(block.timestamp),
            closeTimestamp: 0,
            fundingIndex: 0,
            closePrice: 0,
            lotSize: lotSize,
            closedLotSize: 0,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            lpLockedCapital: uint64(lpLocked6),
            marginUsdc: uint64(margin6),
            totalFeesPaidUsdc: uint64(commission6)
        });

        brokexVault.lockTraderFunds(trader, margin6 + commission6);

        emit TradeEvent(tradeId, 0);
    }

    function executeOrder(
        uint256 tradeId,
        bytes calldata oracleProof
    ) external {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.state != 0) revert NotPending();
        if (!assets[t.assetId].allowOpen) revert CloseOnlyMode();

        _updateFundingRate(t.assetId);

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);

        bool executable;
        if (t.isLimit) {
            executable = t.isLong
                ? price1e6 <= uint256(t.openPrice)
                : price1e6 >= uint256(t.openPrice);
        } else {
            executable = t.isLong
                ? price1e6 >= uint256(t.openPrice)
                : price1e6 <= uint256(t.openPrice);
        }

        if (!executable) revert PriceBad();

        uint256 spreadWad = BrokexLibrary.calculateSpread(
            assets[t.assetId],
            exposures[t.assetId],
            t.isLong,
            true,
            uint32(t.lotSize)
        );
        uint256 spreadAmount = (price1e6 * spreadWad) / 1e18;
        uint256 execPrice = t.isLong
            ? price1e6 + spreadAmount
            : price1e6 - spreadAmount;

        t.openPrice = uint48(execPrice);
        t.state = 1;
        t.openTimestamp = uint32(block.timestamp);

        BrokexLibrary.FundingState memory fs = fundingStates[t.assetId];
        t.fundingIndex = t.isLong ? fs.longFundingIndex : fs.shortFundingIndex;

        _updateExposure(
            t.assetId,
            t.lotSize,
            uint48(execPrice),
            t.isLong,
            true
        );
        _updateExposureLimits(
            t.assetId,
            t.lpLockedCapital,
            t.marginUsdc,
            t.isLong,
            true
        );

        _syncLock(t.assetId, false);

        uint256 commission6 = uint256(t.totalFeesPaidUsdc);
        if (commission6 > 0) {
            brokexVault.collectCommissionFromLocked(t.trader, commission6);
        }

        emit TradeEvent(tradeId, 1);
    }

    function closePositionMarket(
        address trader,
        uint256 tradeId,
        int32 lotsToClose,
        bytes calldata oracleProof
    ) external onlyPaymaster {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.trader != trader) revert NotYourTrade();
        if (t.state != 1) revert NotOpen();

        _updateFundingRate(t.assetId);

        int32 remaining = t.lotSize - t.closedLotSize;
        if (lotsToClose == 0 || lotsToClose > remaining) {
            lotsToClose = remaining;
        }

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);

        _finalizeClose(t, price1e6, tradeId, lotsToClose);
    }

    function executeStopOrTakeProfit(
        uint256 tradeId,
        bytes calldata oracleProof
    ) external {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.state != 1) revert NotOpen();

        _updateFundingRate(t.assetId);

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        bool triggered = false;

        if (t.stopLoss > 0) {
            if (t.isLong && price1e6 <= t.stopLoss) triggered = true;
            if (!t.isLong && price1e6 >= t.stopLoss) triggered = true;
        }

        if (!triggered && t.takeProfit > 0) {
            if (t.isLong && price1e6 >= t.takeProfit) triggered = true;
            if (!t.isLong && price1e6 <= t.takeProfit) triggered = true;
        }

        if (!triggered) revert NotTriggered();

        int32 remaining = t.lotSize - t.closedLotSize;
        _finalizeClose(t, price1e6, tradeId, remaining);
    }

    function updateSLTP(
        address trader,
        uint256 tradeId,
        uint48 newSL,
        uint48 newTP
    ) external onlyPaymaster {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.trader != trader) revert NotYourTrade();

        if (t.state > 1) revert Closed();
        (bool ok, string memory reason) = BrokexLibrary.validateStops(
            uint256(t.openPrice),
            t.isLong,
            newSL,
            newTP
        );
        if (!ok) revert(reason);
        t.stopLoss = newSL;
        t.takeProfit = newTP;
        emit TradeEvent(tradeId, 5);
    }

    function cancelOrder(
        address trader,
        uint256 tradeId
    ) external onlyPaymaster {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.trader != trader) revert NotYourTrade();
        if (t.state != 0) revert NotPending();

        t.state = 3;

        brokexVault.unlockTraderFunds(
            trader,
            uint256(t.marginUsdc) + uint256(t.totalFeesPaidUsdc)
        );

        emit TradeEvent(tradeId, 3);
    }

    function _finalizeClose(
        BrokexLibrary.Trade storage t,
        uint256 price,
        uint256 tradeId,
        int32 lotClose
    ) internal {
        int32 lotLeft = t.lotSize - t.closedLotSize;
        require(lotLeft >= lotClose, "Closing more than remaining");

        uint256 marginOut;
        uint256 lpOut;

        if (lotClose == lotLeft) {
            marginOut = t.marginUsdc;
            lpOut = t.lpLockedCapital;
        } else {
            uint256 ratio = (uint256(uint32(lotClose)) * 1e18) /
                uint256(uint32(lotLeft));
            marginOut = (uint256(t.marginUsdc) * ratio) / 1e18;
            lpOut = (uint256(t.lpLockedCapital) * ratio) / 1e18;
        }

        (
            int256 netPnl,
            uint256 exitPrice,
            uint256 feeExtra
        ) = BrokexLibrary.calculateNetPnl(
                t,
                assets[t.assetId],
                fundingStates[t.assetId],
                exposures[t.assetId],
                price,
                lotClose,
                block.timestamp
            );

        int256 pnl = netPnl;

        if (netPnl > 0) {
            uint256 pnlCap = lpOut * 1e12;
            if (uint256(netPnl) > pnlCap) {
                pnl = int256(pnlCap);
            }
        } else if (netPnl < 0) {
            uint256 liqCut = (marginOut * 90 / 100) * 1e12;
            uint256 marginCap = marginOut * 1e12;

            if (uint256(-netPnl) >= liqCut) {
                pnl = -int256(marginCap);
            } else if (uint256(-netPnl) > marginCap) {
                pnl = -int256(marginCap);
            }
        }

        int256 pnlUsd = pnl / int256(1e12);

        BrokexLibrary.Exposure storage e = exposures[t.assetId];

        uint256 oldLock = uint256(e.currentLpLock);
        uint256 oldNeed = uint256(e.needLock);

        _updateExposure(t.assetId, lotClose, t.openPrice, t.isLong, false);
        _updateExposureLimits(
            t.assetId,
            uint64(lpOut),
            uint64(marginOut),
            t.isLong,
            false
        );

        (uint256 newNeed, ) = _needLock(t.assetId);

        if (e.longLots == 0 && e.shortLots == 0) {
            newNeed = 0;
        }

        if (newNeed >= oldNeed) {
            totalNeedLock += (newNeed - oldNeed);
        } else {
            totalNeedLock -= (oldNeed - newNeed);
        }

        uint256 baseLock = newNeed;
        if (baseLock > oldLock) {
            baseLock = oldLock;
        }

        uint256 freeLock = oldLock - baseLock;

        if (freeLock > 0) {
            brokexVault.unlockLpCapital(freeLock);
        }

        e.currentLpLock = uint128(baseLock);
        e.needLock = uint128(newNeed);
        e.overlapRisk = 0;

        if (pnlUsd > 0) {
            uint256 gain = uint256(pnlUsd);
            uint256 freeLp = brokexVault.lpFreeCapital();

            if (freeLp < gain) {
                uint256 extra = gain - freeLp;

                require(
                    extra <= uint256(e.currentLpLock),
                    "EXTRA_TOO_HIGH"
                );

                uint256 lockAfter = uint256(e.currentLpLock) - extra;

                if (newNeed > 0) {
                    require(
                        lockAfter * 10000 >=
                            newNeed * uint256(assets[t.assetId].minCoverBps),
                        "COVER_TOO_LOW"
                    );
                }

                uint256 lockedNow = brokexVault.lpLockedCapital();
                require(lockedNow >= extra, "LOCK_TOO_LOW");

                uint256 lockedAfter = lockedNow - extra;

                if (totalNeedLock > 0) {
                    require(
                        lockedAfter * 10000 >=
                            totalNeedLock * uint256(minGlobalCoverBps),
                        "GLOBAL_COVER_TOO_LOW"
                    );
                }

                brokexVault.unlockLpCapital(extra);
                e.currentLpLock = uint128(lockAfter);
            }
        }

        uint256 closedOld = uint256(uint32(t.closedLotSize));
        uint256 closedNow = uint256(uint32(lotClose));
        if (closedOld + closedNow > 0) {
            uint256 avg = (uint256(t.closePrice) * closedOld) +
                (exitPrice * closedNow);
            t.closePrice = uint48(avg / (closedOld + closedNow));
        }

        if (feeExtra > 0) {
            t.totalFeesPaidUsdc += uint64(feeExtra);
        }

        t.closedLotSize += lotClose;
        t.marginUsdc -= uint64(marginOut);
        t.lpLockedCapital -= uint64(lpOut);

        bool isFull = (t.closedLotSize >= t.lotSize);
        if (isFull) {
            t.state = 2;
            t.closeTimestamp = uint32(block.timestamp);
        }

        brokexVault.unlockTraderFunds(t.trader, marginOut);

        if (pnlUsd != 0) {
            brokexVault.settlePnl(t.trader, pnlUsd);
        }

        emit TradeEvent(tradeId, 2);
    }

    function liquidatePosition(
        uint256 tradeId,
        bytes calldata oracleProof
    ) external {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.state != 1) revert NotOpen();

        _updateFundingRate(t.assetId);

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        int32 remainingLots = t.lotSize - t.closedLotSize;
        if (remainingLots <= 0) revert Closed();

        (int256 netPnl18, , ) = BrokexLibrary.calculateNetPnl(
            t,
            assets[t.assetId],
            fundingStates[t.assetId],
            exposures[t.assetId],
            price1e6,
            remainingLots,
            block.timestamp
        );

        uint256 maxProfit18 = uint256(t.lpLockedCapital) * 1e12;
        uint256 maxLoss18 = ((uint256(t.marginUsdc) * 90) / 100) * 1e12;

        bool isPositiveLiq = netPnl18 >= 0 && uint256(netPnl18) >= maxProfit18;
        bool isNegativeLiq = netPnl18 < 0 && uint256(-netPnl18) >= maxLoss18;

        if (!isPositiveLiq && !isNegativeLiq) revert NotLiq();

        _finalizeClose(t, price1e6, tradeId, remainingLots);
    }

    // ----------------------------------------------------------------
    // 11. UNREALIZED PNL (BATCH)
    // ----------------------------------------------------------------

    function updateUnrealizedPnl(
        bytes calldata singleProof,
        uint32[] calldata assetIds
    ) external returns (uint64 runId, bool runCompleted, int256 currentPnl) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(
            singleProof
        );
        BrokexLibrary.PnlRun storage run;
        if (
            currentPnlRunId == 0 ||
            block.timestamp >
            pnlRuns[currentPnlRunId].startTimestamp + 2 minutes ||
            pnlRuns[currentPnlRunId].completed
        ) {
            currentPnlRunId++;
            run = pnlRuns[currentPnlRunId];
            run.runId = currentPnlRunId;
            run.startTimestamp = uint64(block.timestamp);
            run.totalAssetsAtStart = uint32(listedAssetsCount);
            pnlCalculationActive = true;
            emit PnlRunStarted(currentPnlRunId, uint32(listedAssetsCount));
        } else {
            run = pnlRuns[currentPnlRunId];
        }

        if (block.timestamp > run.startTimestamp + 2 minutes) {
            emit PnlRunExpired(currentPnlRunId);
            return (currentPnlRunId, false, run.cumulativePnlX6);
        }

        for (uint256 i = 0; i < assetIds.length; i++) {
            uint32 assetId = assetIds[i];
            if (!assets[assetId].listed) continue;
            if (assetProcessedInRun[currentPnlRunId][assetId]) continue;
            uint256 price1e6 = _extractPriceFromInfo(info, assetId);
            int256 assetPnl = BrokexLibrary.calculateAssetPnlCapped(
                exposures[assetId],
                assets[assetId],
                price1e6
            );
            run.cumulativePnlX6 += assetPnl;
            assetProcessedInRun[currentPnlRunId][assetId] = true;
            run.assetsProcessed++;
        }

        if (run.assetsProcessed >= run.totalAssetsAtStart) {
            run.completed = true;
            run.endTimestamp = uint64(block.timestamp);
            pnlCalculationActive = false;
            emit PnlRunCompleted(currentPnlRunId, run.cumulativePnlX6);
        }
        return (currentPnlRunId, run.completed, run.cumulativePnlX6);
    }

    // ----------------------------------------------------------------
    // 12. VIEWS UTILS
    // ----------------------------------------------------------------

    function getLastFinishedPnlRun()
        external
        view
        returns (int256 pnl, uint64 timestamp)
    {
        if (currentPnlRunId > 0) {
            BrokexLibrary.PnlRun memory run = pnlRuns[currentPnlRunId];
            if (run.completed) return (run.cumulativePnlX6, run.endTimestamp);
            else if (currentPnlRunId > 1) {
                BrokexLibrary.PnlRun memory prev = pnlRuns[currentPnlRunId - 1];
                if (prev.completed)
                    return (prev.cumulativePnlX6, prev.endTimestamp);
            }
        }
        return (0, 0);
    }

    // ----------------------------------------------------------------
    // 14. ADD MARGIN FUNCTIONS
    // ----------------------------------------------------------------

    function addMargin(
        address trader,
        uint256 tradeId,
        uint64 amount6
    ) external onlyPaymaster {
        BrokexLibrary.Trade storage t = trades[tradeId];

        if (t.trader != trader) revert NotYourTrade();
        if (t.state > 1) revert Closed();
        if (amount6 == 0) revert BadSize();

        // On lock simplement les fonds du trader dans le Vault
        brokexVault.lockTraderFunds(trader, uint256(amount6));

        // On augmente la marge restante réelle du trade
        t.marginUsdc += amount6;

        // Si le trade est déjà ouvert, on augmente aussi la perte max agrégée du côté concerné
        if (t.state == 1) {
            _updateExposureLimits(
                t.assetId,
                0,
                uint64(amount6),
                t.isLong,
                true
            );
        }

        emit TradeEvent(tradeId, 6);
    }
}
