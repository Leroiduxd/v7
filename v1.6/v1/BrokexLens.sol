// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./BrokexLibrary.sol";

interface IBrokexCoreLens {
    function trades(
        uint256 tradeId
    ) external view returns (
        address trader,
        uint32 assetId,
        bool isLong,
        bool isLimit,
        uint8 leverage,
        uint48 openPrice,
        uint8 state,
        uint32 openTimestamp,
        uint32 closeTimestamp,
        uint128 fundingIndex,
        uint48 closePrice,
        int32 lotSize,
        int32 closedLotSize,
        uint48 stopLoss,
        uint48 takeProfit,
        uint64 lpLockedCapital,
        uint64 marginUsdc,
        uint64 totalFeesPaidUsdc
    );

    function exposures(
        uint32 assetId
    ) external view returns (
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

    function fundingStates(
        uint32 assetId
    ) external view returns (
        uint64 lastUpdate,
        uint128 longFundingIndex,
        uint128 shortFundingIndex
    );
}

interface IBrokexAssetManagerLens {
    function getAsset(uint32 assetId) external view returns (BrokexLibrary.Asset memory);
}

contract BrokexLens {
    error ZeroAddr();

    IBrokexCoreLens public immutable core;
    IBrokexAssetManagerLens public immutable assetManager;

    struct FundingPreview {
        uint32 assetId;
        uint64 lastUpdate;
        uint256 timePassed;
        uint256 longRateHourlyWad;
        uint256 shortRateHourlyWad;
        uint256 currentLongIndex;
        uint256 currentShortIndex;
        uint256 projectedLongIndex;
        uint256 projectedShortIndex;
        int32 longLots;
        int32 shortLots;
        uint64 baseFundingRate;
    }

    constructor(address _core, address _assetManager) {
        if (_core == address(0) || _assetManager == address(0)) revert ZeroAddr();
        core = IBrokexCoreLens(_core);
        assetManager = IBrokexAssetManagerLens(_assetManager);
    }

    // =========================================================
    // 1. READ ONLY: STATES OF A LIST OF TRADES
    // =========================================================

    function getTradeStates(
        uint256[] calldata tradeIds
    ) external view returns (uint8[] memory states) {
        uint256 len = tradeIds.length;
        states = new uint8[](len);

        for (uint256 i = 0; i < len; i++) {
            (, , , , , , uint8 state, , , , , , , , , , , ) = core.trades(tradeIds[i]);
            states[i] = state;
        }
    }

    // =========================================================
    // 2. READ ONLY: FULL TRADE STRUCTS FOR A LIST OF TRADES
    // =========================================================

    function getTrades(
        uint256[] calldata tradeIds
    ) external view returns (BrokexLibrary.Trade[] memory out) {
        uint256 len = tradeIds.length;
        out = new BrokexLibrary.Trade[](len);

        for (uint256 i = 0; i < len; i++) {
            (
                address trader,
                uint32 assetId,
                bool isLong,
                bool isLimit,
                uint8 leverage,
                uint48 openPrice,
                uint8 state,
                uint32 openTimestamp,
                uint32 closeTimestamp,
                uint128 fundingIndex,
                uint48 closePrice,
                int32 lotSize,
                int32 closedLotSize,
                uint48 stopLoss,
                uint48 takeProfit,
                uint64 lpLockedCapital,
                uint64 marginUsdc,
                uint64 totalFeesPaidUsdc
            ) = core.trades(tradeIds[i]);

            out[i] = BrokexLibrary.Trade({
                trader: trader,
                assetId: assetId,
                isLong: isLong,
                isLimit: isLimit,
                leverage: leverage,
                openPrice: openPrice,
                state: state,
                openTimestamp: openTimestamp,
                closeTimestamp: closeTimestamp,
                fundingIndex: fundingIndex,
                closePrice: closePrice,
                lotSize: lotSize,
                closedLotSize: closedLotSize,
                stopLoss: stopLoss,
                takeProfit: takeProfit,
                lpLockedCapital: lpLockedCapital,
                marginUsdc: marginUsdc,
                totalFeesPaidUsdc: totalFeesPaidUsdc
            });
        }
    }

    // =========================================================
    // 3. READ ONLY: CURRENT HOURLY FUNDING RATE
    // =========================================================

    function getCurrentFundingRates(
        uint32 assetId
    ) public view returns (uint256 longRateHourlyWad, uint256 shortRateHourlyWad) {
        BrokexLibrary.Asset memory a = assetManager.getAsset(assetId);

        (
            int32 longLotsSigned,
            int32 shortLotsSigned,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = core.exposures(assetId);

        uint256 L = longLotsSigned > 0 ? uint256(uint32(longLotsSigned)) : 0;
        uint256 S = shortLotsSigned > 0 ? uint256(uint32(shortLotsSigned)) : 0;

        return BrokexLibrary.computeFundingRateQuadratic(
            L,
            S,
            uint256(a.baseFundingRate)
        );
    }

    // =========================================================
    // 4. READ ONLY: PROJECTED FUNDING INDEX "AS IF UPDATED NOW"
    // =========================================================

    function previewFundingUpdate(
        uint32 assetId
    ) public view returns (FundingPreview memory p) {
        BrokexLibrary.Asset memory a = assetManager.getAsset(assetId);

        (
            int32 longLotsSigned,
            int32 shortLotsSigned,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = core.exposures(assetId);

        (
            uint64 lastUpdate,
            uint128 longFundingIndex,
            uint128 shortFundingIndex
        ) = core.fundingStates(assetId);

        uint256 currentLongIndex = uint256(longFundingIndex);
        uint256 currentShortIndex = uint256(shortFundingIndex);

        uint256 projectedLongIndex = currentLongIndex;
        uint256 projectedShortIndex = currentShortIndex;

        uint256 longRateHourlyWad;
        uint256 shortRateHourlyWad;
        uint256 timePassed = 0;

        if (lastUpdate == 0 || block.timestamp <= uint256(lastUpdate)) {
            (longRateHourlyWad, shortRateHourlyWad) = getCurrentFundingRates(assetId);

            return FundingPreview({
                assetId: assetId,
                lastUpdate: lastUpdate,
                timePassed: 0,
                longRateHourlyWad: longRateHourlyWad,
                shortRateHourlyWad: shortRateHourlyWad,
                currentLongIndex: currentLongIndex,
                currentShortIndex: currentShortIndex,
                projectedLongIndex: projectedLongIndex,
                projectedShortIndex: projectedShortIndex,
                longLots: longLotsSigned,
                shortLots: shortLotsSigned,
                baseFundingRate: a.baseFundingRate
            });
        }

        (longRateHourlyWad, shortRateHourlyWad) = getCurrentFundingRates(assetId);
        timePassed = block.timestamp - uint256(lastUpdate);

        projectedLongIndex =
            currentLongIndex +
            ((longRateHourlyWad * timePassed) / 3600);

        projectedShortIndex =
            currentShortIndex +
            ((shortRateHourlyWad * timePassed) / 3600);

        return FundingPreview({
            assetId: assetId,
            lastUpdate: lastUpdate,
            timePassed: timePassed,
            longRateHourlyWad: longRateHourlyWad,
            shortRateHourlyWad: shortRateHourlyWad,
            currentLongIndex: currentLongIndex,
            currentShortIndex: currentShortIndex,
            projectedLongIndex: projectedLongIndex,
            projectedShortIndex: projectedShortIndex,
            longLots: longLotsSigned,
            shortLots: shortLotsSigned,
            baseFundingRate: a.baseFundingRate
        });
    }

    // =========================================================
    // 5. BATCH PREVIEW FOR MULTIPLE ASSETS
    // =========================================================

    function previewFundingUpdates(
        uint32[] calldata assetIds
    ) external view returns (FundingPreview[] memory out) {
        uint256 len = assetIds.length;
        out = new FundingPreview[](len);

        for (uint256 i = 0; i < len; i++) {
            out[i] = previewFundingUpdate(assetIds[i]);
        }
    }
}
