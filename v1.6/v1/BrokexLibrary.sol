// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library BrokexLibrary {
    // ==========================================
    // 1. DATA STRUCTURES
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

        // --- NEW: ouverture / équilibre / concentration ---
        uint128 imbalanceBufferUsd6;     // buffer en 1e6, ex: 5_000e6
        uint128 imbalanceKUsd6;          // agressivité en 1e6
        uint16 imbalanceMaxRatioBps;     // ex: 40000 = 4.00x
        uint16 imbalanceMinRatioBps;     // ex: 10500 = 1.05x
        uint16 maxAssetLockBps;          // ex: 1000 = 10% du capital LP total
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

    function computeAllowedDominanceBps(
        Asset memory a,
        uint256 totalRisk
    ) internal pure returns (uint256 allowedRatioBps) {
        if (totalRisk <= uint256(a.imbalanceBufferUsd6)) {
            return type(uint256).max;
        }

        uint256 x = totalRisk - uint256(a.imbalanceBufferUsd6);
        uint256 K = uint256(a.imbalanceKUsd6);

        if (K == 0) {
            return uint256(a.imbalanceMinRatioBps);
        }

        uint256 maxBps = uint256(a.imbalanceMaxRatioBps);
        uint256 minBps = uint256(a.imbalanceMinRatioBps);

        if (maxBps <= minBps) {
            return minBps;
        }

        uint256 k2 = K * K;
        uint256 x2 = x * x;

        uint256 extra = ((maxBps - minBps) * k2) / (x2 + k2);

        return minBps + extra;
    }

    function checkOpenImbalanceAfterAdd(
        Asset memory a,
        Exposure memory e,
        bool isLong,
        uint256 addedMaxProfit
    )
        internal
        pure
        returns (
            bool allowed,
            uint256 longRisk,
            uint256 shortRisk,
            uint256 dominant,
            uint256 minority,
            uint256 allowedRatioBps
        )
    {
        longRisk = uint256(e.longMaxProfit);
        shortRisk = uint256(e.shortMaxProfit);

        if (isLong) {
            longRisk += addedMaxProfit;
        } else {
            shortRisk += addedMaxProfit;
        }

        uint256 totalRisk = longRisk + shortRisk;
        allowedRatioBps = computeAllowedDominanceBps(a, totalRisk);

        if (allowedRatioBps == type(uint256).max) {
            return (true, longRisk, shortRisk, 0, 0, allowedRatioBps);
        }

        dominant = longRisk > shortRisk ? longRisk : shortRisk;
        minority = longRisk > shortRisk ? shortRisk : longRisk;

        if (minority == 0) {
            return (false, longRisk, shortRisk, dominant, minority, allowedRatioBps);
        }

        allowed = (dominant * BPS) <= (minority * allowedRatioBps);
    }

    function computeNeedLockAfterOpen(
        Asset memory a,
        Exposure memory e,
        bool isLong,
        uint256 addedMaxProfit,
        uint256 addedMargin
    ) internal pure returns (uint256 needLockAfter, uint256 alpha) {
        if (isLong) {
            e.longMaxProfit += uint128(addedMaxProfit);
            e.longMaxLoss += uint128(addedMargin);
        } else {
            e.shortMaxProfit += uint128(addedMaxProfit);
            e.shortMaxLoss += uint128(addedMargin);
        }

        return computeNeedLock(a, e);
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

    function calculateNetPnl(
        Trade memory t,
        Asset memory a,
        FundingState memory f,
        Exposure memory e,
        uint256 price1e6,
        int32 sizeToCalc,
        uint256 currentTimestamp
    ) external pure returns (int256, uint256, uint256) {
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
