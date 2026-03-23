// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./BrokexLibrary.sol";
// Importer le fichier où se trouve l'interface du manager, ou la redéclarer ici :
import "./BrokexAssetManager.sol";

// ==========================================
// INTERFACES (Vault & Oracle)
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
    error MinGlobalCoverTooLow();
    error OpenImbalanceTooHigh();
    error AssetConcentrationTooHigh();
    error PaymasterAlreadySet();
    error ZeroLibraryAddress();
    error ClosingMoreThanRemaining();
    error ExtraTooHigh();
    error CoverTooLow();
    error LockTooLow();
    error GlobalCoverTooLow();

    // ----------------------------------------------------------------
    // CONSTANTES & STATE
    // ----------------------------------------------------------------
    uint256 constant SECONDS_PER_WEEK = 604800;
    uint256 constant OFFSET_TO_MONDAY = 259200;

    ISupraOraclePull public immutable oracle;
    IBrokexVault public brokexVault;
    IBrokexAssetManager public assetManager;
    address public immutable owner;

    address public paymaster;
    address public libraryAddress; // Référence informationnelle si besoin

    uint256 public nextTradeID;

    uint256 public totalNeedLock;
    uint16 public minGlobalCoverBps = 9000;

    // Mappings using Structs from Library
    mapping(uint256 => BrokexLibrary.Trade) public trades;
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

    constructor(address _oracle, address _libraryAddress, address _assetManager) {
        if (_libraryAddress == address(0) || _assetManager == address(0)) revert ZeroLibraryAddress();
        
        owner = msg.sender;
        oracle = ISupraOraclePull(_oracle);
        libraryAddress = _libraryAddress;
        assetManager = IBrokexAssetManager(_assetManager);
    }

    // ----------------------------------------------------------------
    // ADMIN
    // ----------------------------------------------------------------
    function setBrokexVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddr();
        brokexVault = IBrokexVault(vault);
    }

    function setAssetManager(address _assetManager) external onlyOwner {
        if (_assetManager == address(0)) revert ZeroAddr();
        assetManager = IBrokexAssetManager(_assetManager);
    }

    function setPaymaster(address _paymaster) external onlyOwner {
        if (paymaster != address(0)) revert PaymasterAlreadySet();
        if (_paymaster == address(0)) revert ZeroAddr();
        paymaster = _paymaster;
    }

    // ----------------------------------------------------------------
    // ORACLE HELPER
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

        BrokexLibrary.Asset memory a = assetManager.getAsset(_assetId);
        uint256 allowedDelay = uint256(a.maxOracleDelay);
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
    // EXPOSURE LOGIC
    // ----------------------------------------------------------------
    function _updateExposure(
        uint32 assetId,
        int32 lotSize,
        uint48 price,
        bool isLong,
        bool increase
    ) internal {
        BrokexLibrary.Exposure storage e = exposures[assetId];
        BrokexLibrary.Asset memory a = assetManager.getAsset(assetId);

        uint256 rawVal = BrokexLibrary.getNotionalValue(
            a,
            uint256(price),
            uint32(lotSize)
        );
        uint128 value = uint128(rawVal);

        if (isLong) {
            if (increase) {
                if (
                    uint256(uint256(int256(e.longLots))) +
                        uint256(uint32(lotSize)) >
                    uint256(a.maxLongLots)
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
                    uint256(a.maxShortLots)
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
    }

    function _needLock(
        uint32 assetId
    ) internal view returns (uint256 needLock, uint256 alpha) {
        return BrokexLibrary.computeNeedLock(
            assetManager.getAsset(assetId),
            exposures[assetId]
        );
    }

    // ----------------------------------------------------------------
    // FUNDING RATE
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
        BrokexLibrary.Asset memory a = assetManager.getAsset(assetId);

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

    function _checkAssetConcentration(
        uint32 assetId,
        bool isLong,
        uint256 addedMaxProfit,
        uint256 addedMargin
    ) internal view {
        BrokexLibrary.Asset memory a = assetManager.getAsset(assetId);
        BrokexLibrary.Exposure memory e = exposures[assetId];
    
        uint256 oldNeedLock = uint256(e.needLock);
    
        (uint256 newNeedLock, ) = BrokexLibrary.computeNeedLockAfterOpen(
            a,
            e,
            isLong,
            addedMaxProfit,
            addedMargin
        );
    
        // Si l'ordre réduit ou n'augmente pas le besoin de lock,
        // on l'accepte même si l'asset est déjà concentré.
        if (newNeedLock <= oldNeedLock) {
            return;
        }
    
        uint256 totalLpCapital = brokexVault.lpFreeCapital() +
            brokexVault.lpLockedCapital();
    
        if (totalLpCapital == 0) revert AssetConcentrationTooHigh();
    
        uint256 maxAllowedForAsset =
            (totalLpCapital * uint256(a.maxAssetLockBps)) / 10000;
    
        if (newNeedLock > maxAllowedForAsset) revert AssetConcentrationTooHigh();
    }

    // ----------------------------------------------------------------
    // INTERNAL LOGIC (SHARED)
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
        BrokexLibrary.Asset memory a = assetManager.getAsset(assetId);

        if (!a.listed) revert AssetDeleted();
        if (!a.allowOpen) revert CloseOnlyMode();
        if (lotSize <= 0) revert BadSize();
        if (leverage < 1 || leverage > a.maxLeverage) revert BadLev();

        _updateFundingRate(assetId);

        uint256 price1e6 = _getVerifiedPrice(oracleProof, assetId);

        uint256 spreadWad = BrokexLibrary.calculateSpread(
            a,
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
            a,
            entryPrice,
            uint32(lotSize),
            leverage
        );

        uint256 lpLocked6 = BrokexLibrary.calculateLockedCapital(
            a,
            entryPrice,
            uint32(lotSize),
            leverage
        );

        uint256 commission6 = BrokexLibrary.calculateCommission6(
            a,
            entryPrice,
            uint32(lotSize)
        );

        _checkOpenImbalance(assetId, isLong, lpLocked6);
        _checkAssetConcentration(assetId, isLong, lpLocked6, margin6);

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
        BrokexLibrary.Asset memory a = assetManager.getAsset(assetId);

        if (!a.listed) revert AssetDeleted();
        if (!a.allowOpen) revert CloseOnlyMode();
        if (lotSize <= 0) revert BadSize();
        if (leverage < 1 || leverage > a.maxLeverage) revert BadLev();

        (bool stopsOk, string memory reason) = BrokexLibrary.validateStops(
            uint256(targetPrice),
            isLong,
            stopLoss,
            takeProfit
        );
        if (!stopsOk) revert(reason);

        uint256 margin6 = BrokexLibrary.calculateMargin6(
            a,
            uint256(targetPrice),
            uint32(lotSize),
            leverage
        );

        uint256 lpLocked6 = BrokexLibrary.calculateLockedCapital(
            a,
            uint256(targetPrice),
            uint32(lotSize),
            leverage
        );

        uint256 commission6 = BrokexLibrary.calculateCommission6(
            a,
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
        BrokexLibrary.Asset memory a = assetManager.getAsset(t.assetId);

        if (t.state != 0) revert NotPending();
        if (!a.allowOpen) revert CloseOnlyMode();

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
            a,
            exposures[t.assetId],
            t.isLong,
            true,
            uint32(t.lotSize)
        );
        uint256 spreadAmount = (price1e6 * spreadWad) / 1e18;
        uint256 execPrice = t.isLong
            ? price1e6 + spreadAmount
            : price1e6 - spreadAmount;

        _checkOpenImbalance(t.assetId, t.isLong, uint256(t.lpLockedCapital));
        _checkAssetConcentration(
            t.assetId,
            t.isLong,
            uint256(t.lpLockedCapital),
            uint256(t.marginUsdc)
        );

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
        if (lotLeft < lotClose) revert ClosingMoreThanRemaining();

        BrokexLibrary.Asset memory a = assetManager.getAsset(t.assetId);

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
                a,
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

        if (pnlUsd > 0) {
            uint256 gain = uint256(pnlUsd);
            uint256 freeLp = brokexVault.lpFreeCapital();

            if (freeLp < gain) {
                uint256 extra = gain - freeLp;

                if (extra > uint256(e.currentLpLock)) revert ExtraTooHigh();

                uint256 lockAfter = uint256(e.currentLpLock) - extra;

                if (
                    newNeed > 0 &&
                    lockAfter * 10000 <
                    newNeed * uint256(a.minCoverBps)
                ) revert CoverTooLow();

                uint256 lockedNow = brokexVault.lpLockedCapital();
                if (lockedNow < extra) revert LockTooLow();

                uint256 lockedAfter = lockedNow - extra;

                if (
                    totalNeedLock > 0 &&
                    lockedAfter * 10000 <
                    totalNeedLock * uint256(minGlobalCoverBps)
                ) revert GlobalCoverTooLow();

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

        BrokexLibrary.Asset memory a = assetManager.getAsset(t.assetId);

        (int256 netPnl18, , ) = BrokexLibrary.calculateNetPnl(
            t,
            a,
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
    // UNREALIZED PNL (BATCH)
    // ----------------------------------------------------------------
    function updateUnrealizedPnl(
        bytes calldata singleProof,
        uint32[] calldata assetIds
    ) external returns (uint64 runId, bool runCompleted, int256 currentPnl) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(
            singleProof
        );
        BrokexLibrary.PnlRun storage run;
        
        uint256 listedCount = assetManager.listedAssetsCount();

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
            run.totalAssetsAtStart = uint32(listedCount);
            pnlCalculationActive = true;
            emit PnlRunStarted(currentPnlRunId, uint32(listedCount));
        } else {
            run = pnlRuns[currentPnlRunId];
        }

        if (block.timestamp > run.startTimestamp + 2 minutes) {
            emit PnlRunExpired(currentPnlRunId);
            return (currentPnlRunId, false, run.cumulativePnlX6);
        }

        for (uint256 i = 0; i < assetIds.length; i++) {
            uint32 assetId = assetIds[i];
            BrokexLibrary.Asset memory a = assetManager.getAsset(assetId);
            
            if (!a.listed) continue;
            if (assetProcessedInRun[currentPnlRunId][assetId]) continue;
            
            uint256 price1e6 = _extractPriceFromInfo(info, assetId);
            int256 assetPnl = BrokexLibrary.calculateAssetPnlCapped(
                exposures[assetId],
                a,
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
    // VIEWS UTILS
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
    // ADD MARGIN FUNCTIONS
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

        brokexVault.lockTraderFunds(trader, uint256(amount6));
        t.marginUsdc += amount6;

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
