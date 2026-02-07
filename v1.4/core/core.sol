// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./BrokexLibrary.sol";

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
    function verifyOracleProofV2(bytes calldata _bytesProof) external returns (PriceInfo memory);
}

interface IBrokexVault {
    function createOrder(uint256 tradeId, address trader, uint256 margin6, uint256 commission6, uint256 lpLock6) external;
    function executeOrder(uint256 tradeId) external;
    function cancelOrder(uint256 tradeId) external;
    function createPosition(uint256 tradeId, address trader, uint256 margin6, uint256 commission6, uint256 lpLock6) external;
    function closeTrade(uint256 tradeId, int256 pnl18, uint256 marginToRelease6, uint256 lpLockToRelease6, bool isFullClose) external;    
    function liquidate(uint256 tradeId) external;
    function addMarginToTrade(uint256 tradeId, uint256 amount6) external;
}

// ==========================================
// CONTRACT
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

    // ----------------------------------------------------------------
    // CONSTANTES & STATE
    // ----------------------------------------------------------------

    uint256 constant SECONDS_PER_WEEK = 604800;
    uint256 constant OFFSET_TO_MONDAY = 259200; 

    ISupraOraclePull public immutable oracle;
    IBrokexVault public brokexVault;
    address public immutable owner;
    
    address public paymaster;

    uint256 public nextTradeID;
    uint256 public listedAssetsCount;

    // --- AIRDROP STATE ---
    uint32 public currentSeasonId;
    
    mapping(uint32 => mapping(address => uint256)) public seasonTraderVolume;
    mapping(uint32 => uint256) public seasonTotalVolume;
    
    mapping(uint32 => mapping(address => uint256)) public seasonTraderWinPnL;
    mapping(uint32 => uint256) public seasonTotalWinPnL;

    event SeasonRotated(uint32 newSeasonId);
    event AirdropPoints(uint32 indexed seasonId, address indexed trader, uint256 volumePoints, uint256 pnlPoints);

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

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyPaymaster() { if (msg.sender != paymaster) revert NotPaymaster(); _; }

    constructor(address _oracle) {
        owner = msg.sender;
        oracle = ISupraOraclePull(_oracle);
        currentSeasonId = 1; 
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

    // ----------------------------------------------------------------
    // 2. AIRDROP LOGIC & VIEWS
    // ----------------------------------------------------------------

    function startNewSeason() external onlyOwner {
        currentSeasonId++;
        emit SeasonRotated(currentSeasonId);
    }

    function _updateAirdropVolume(address trader, uint256 margin6) internal {
        seasonTraderVolume[currentSeasonId][trader] += margin6;
        seasonTotalVolume[currentSeasonId] += margin6;
        emit AirdropPoints(currentSeasonId, trader, margin6, 0);
    }

    function _updateAirdropPnL(address trader, int256 pnl18) internal {
        if (pnl18 > 0) {
            uint256 profit6 = uint256(pnl18) / 1e12; 
            seasonTraderWinPnL[currentSeasonId][trader] += profit6;
            seasonTotalWinPnL[currentSeasonId] += profit6;
            emit AirdropPoints(currentSeasonId, trader, 0, profit6);
        }
    }

    function isSeasonFinished(uint32 seasonId) external view returns (bool) {
        return seasonId < currentSeasonId;
    }

    // ----------------------------------------------------------------
    // 3. ORACLE HELPER
    // ----------------------------------------------------------------

    function _extractPriceFromInfo(ISupraOraclePull.PriceInfo memory info, uint32 _assetId) internal view returns (uint256 price1e6) {
        uint256 len = info.pairs.length;
        bool found = false;
        uint256 index;

        for(uint256 i = 0; i < len; i++) {
            if(info.pairs[i] == uint256(_assetId)) {
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

    function _getVerifiedPrice(bytes calldata _bytesProof, uint32 _assetId) internal returns (uint256) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(_bytesProof);
        return _extractPriceFromInfo(info, _assetId);
    }

    // ----------------------------------------------------------------
    // 4. ADMIN & ASSET
    // ----------------------------------------------------------------

    function listAsset(uint32 assetId, uint32 numerator, uint32 denominator, uint32 baseFundingRate, uint32 spread, uint32 commission, uint32 weekendFunding, uint16 securityMultiplier, uint16 maxPhysicalMove, uint8 maxLeverage) external onlyOwner {
        if (assets[assetId].listed) revert AlreadyListed();
        if (numerator == 0 || denominator == 0) revert BadRatio();
        assets[assetId] = BrokexLibrary.Asset({assetId: assetId, numerator: numerator, denominator: denominator, baseFundingRate: baseFundingRate, spread: spread, commission: commission, weekendFunding: weekendFunding, securityMultiplier: securityMultiplier, maxPhysicalMove: maxPhysicalMove, maxLeverage: maxLeverage, maxLongLots: 1000000, maxShortLots: 1000000, maxOracleDelay: 60, allowOpen: true, listed: true});
        listedAssetsCount++;
    }

    function setAssetOracleDelay(uint32 assetId, uint32 newDelay) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        if (newDelay < 15) revert DelayTooShort();
        if (newDelay > 90) revert DelayTooLong();
        assets[assetId].maxOracleDelay = newDelay;
    }

    function setAssetRiskLimits(uint32 assetId, uint32 _maxLongLots, uint32 _maxShortLots) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].maxLongLots = _maxLongLots;
        assets[assetId].maxShortLots = _maxShortLots;
    }

    function setAssetTradable(uint32 assetId, bool _allowOpen) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].allowOpen = _allowOpen;
    }

    function removeAsset(uint32 assetId) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        BrokexLibrary.Exposure storage e = exposures[assetId];
        if (e.longLots != 0 || e.shortLots != 0) revert ExposureNotZero();
        delete assets[assetId];
    }

    function updateLotSize(uint32 assetId, uint32 newNum, uint32 newDen) external onlyOwner {
        BrokexLibrary.Exposure storage e = exposures[assetId];
        if (e.longLots != 0 || e.shortLots != 0) revert ExposureNotZero();
        assets[assetId].numerator = newNum;
        assets[assetId].denominator = newDen;
    }

    // ----------------------------------------------------------------
    // 5. EXPOSURE LOGIC
    // ----------------------------------------------------------------

    function _updateExposure(uint32 assetId, int32 lotSize, uint48 price, bool isLong, bool increase) internal {
        BrokexLibrary.Exposure storage e = exposures[assetId];
        uint256 rawVal = BrokexLibrary.getNotionalValue(assets[assetId], uint256(price), uint32(lotSize));
        uint128 value = uint128(rawVal);

        if (isLong) {
            if (increase) {
                if (uint256(uint256(int256(e.longLots))) + uint256(uint32(lotSize)) > uint256(assets[assetId].maxLongLots)) revert MaxLongLimit();
                e.longLots += lotSize;
                e.longValueSum += value;
            } else {
                e.longLots -= lotSize;
                e.longValueSum = BrokexLibrary.safeSub(e.longValueSum, value);
            }
        } else {
            if (increase) {
                if (uint256(uint256(int256(e.shortLots))) + uint256(uint32(lotSize)) > uint256(assets[assetId].maxShortLots)) revert MaxShortLimit();
                e.shortLots += lotSize;
                e.shortValueSum += value;
            } else {
                e.shortLots -= lotSize;
                e.shortValueSum = BrokexLibrary.safeSub(e.shortValueSum, value);
            }
        }
    }

    function _updateExposureLimits(uint32 assetId, uint64 lpLocked, uint64 margin, bool isLong, bool increase) internal {
        BrokexLibrary.Exposure storage e = exposures[assetId];
        uint128 locked = uint128(lpLocked);
        uint128 marg = uint128(margin);

        if (isLong) {
            if (increase) {
                e.longMaxProfit += locked;
                e.longMaxLoss += marg;
            } else {
                e.longMaxProfit = BrokexLibrary.safeSub(e.longMaxProfit, locked);
                e.longMaxLoss = BrokexLibrary.safeSub(e.longMaxLoss, marg);
            }
        } else {
            if (increase) {
                e.shortMaxProfit += locked;
                e.shortMaxLoss += marg;
            } else {
                e.shortMaxProfit = BrokexLibrary.safeSub(e.shortMaxProfit, locked);
                e.shortMaxLoss = BrokexLibrary.safeSub(e.shortMaxLoss, marg);
            }
        }
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
        if (block.timestamp < f.lastUpdate + 1 hours) return;

        BrokexLibrary.Exposure memory e = exposures[assetId];
        BrokexLibrary.Asset memory a = assets[assetId];

        uint256 L = uint256(int256(e.longLots) > 0 ? uint256(int256(e.longLots)) : 0);
        uint256 S = uint256(int256(e.shortLots) > 0 ? uint256(int256(e.shortLots)) : 0);
        uint256 baseFunding = uint256(a.baseFundingRate);

        (uint256 longRate, uint256 shortRate) = BrokexLibrary.computeFundingRateQuadratic(L, S, baseFunding);

        f.longFundingIndex += uint128(longRate);
        f.shortFundingIndex += uint128(shortRate);
        f.lastUpdate = uint64(block.timestamp);
    }

    // ----------------------------------------------------------------
    // 10. INTERNAL LOGIC (SHARED)
    // ----------------------------------------------------------------

    function openMarketPosition(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external onlyPaymaster {
        if (!assets[assetId].listed) revert AssetDeleted();
        if (!assets[assetId].allowOpen) revert CloseOnlyMode();
        if (lotSize <= 0) revert BadSize();
        if (!BrokexLibrary.isRoundLeverage(leverage)) revert BadLev();

        uint256 price1e6 = _getVerifiedPrice(oracleProof, assetId);
        uint256 spread = BrokexLibrary.calculateSpread(assets[assetId], exposures[assetId], isLong, true, uint32(lotSize));
        uint256 entryPrice = isLong ? price1e6 + spread : price1e6 - spread;

        (bool stopsOk, string memory reason) = BrokexLibrary.validateStops(entryPrice, isLong, stopLoss, takeProfit);
        if(!stopsOk) revert(reason);

        uint256 margin6 = BrokexLibrary.calculateMargin6(assets[assetId], entryPrice, uint32(lotSize), leverage);
        uint256 lpLocked6 = BrokexLibrary.calculateLockedCapital(assets[assetId], entryPrice, uint32(lotSize), leverage);
        uint256 commission6 = (margin6 * assets[assetId].commission) / 10000;

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
        BrokexLibrary.FundingState memory fs = fundingStates[assetId];
        t.fundingIndex = isLong ? fs.longFundingIndex : fs.shortFundingIndex;
        t.closePrice = 0;          
        t.lotSize = lotSize; 
        t.closedLotSize = 0;       
        t.stopLoss = stopLoss; 
        t.takeProfit = takeProfit;
        t.lpLockedCapital = uint64(lpLocked6); 
        t.marginUsdc = uint64(margin6);

        _updateExposure(assetId, lotSize, uint48(entryPrice), isLong, true);
        _updateExposureLimits(assetId, uint64(lpLocked6), uint64(margin6), isLong, true);
        
        _updateAirdropVolume(trader, uint256(margin6));
        brokexVault.createPosition(tradeId, trader, margin6, commission6, lpLocked6);
        emit TradeEvent(tradeId, 1);
    }

    function placeOrder(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external onlyPaymaster {
        if (!assets[assetId].listed) revert AssetDeleted();
        if (!assets[assetId].allowOpen) revert CloseOnlyMode();
        (bool stopsOk, string memory reason) = BrokexLibrary.validateStops(uint256(targetPrice), isLong, stopLoss, takeProfit);
        if(!stopsOk) revert(reason);

        uint256 margin6 = BrokexLibrary.calculateMargin6(assets[assetId], uint256(targetPrice), uint32(lotSize), leverage);
        uint256 lpLocked6 = BrokexLibrary.calculateLockedCapital(assets[assetId], uint256(targetPrice), uint32(lotSize), leverage);
        uint256 commission6 = (margin6 * assets[assetId].commission) / 10000;

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
            fundingIndex: 0, 
            closePrice: 0, 
            lotSize: lotSize, 
            closedLotSize: 0,
            stopLoss: stopLoss, 
            takeProfit: takeProfit, 
            lpLockedCapital: uint64(lpLocked6), 
            marginUsdc: uint64(margin6)
        });

        brokexVault.createOrder(tradeId, trader, margin6, commission6, lpLocked6);
        emit TradeEvent(tradeId, 0);
    }

    function executeOrder(uint256 tradeId, bytes calldata oracleProof) external {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.state != 0) revert NotPending();
        if (!assets[t.assetId].allowOpen) revert CloseOnlyMode();

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        
        bool executable;
        if (t.isLimit) {
            executable = t.isLong ? price1e6 <= uint256(t.openPrice) : price1e6 >= uint256(t.openPrice);
        } else {
            executable = t.isLong ? price1e6 >= uint256(t.openPrice) : price1e6 <= uint256(t.openPrice);
        }
        
        if (!executable) revert PriceBad();

        uint256 spread = BrokexLibrary.calculateSpread(assets[t.assetId], exposures[t.assetId], t.isLong, true, uint32(t.lotSize));
        uint256 execPrice = t.isLong ? price1e6 + spread : price1e6 - spread;

        t.openPrice = uint48(execPrice); t.state = 1; t.openTimestamp = uint32(block.timestamp);
        BrokexLibrary.FundingState memory fs = fundingStates[t.assetId];
        t.fundingIndex = t.isLong ? fs.longFundingIndex : fs.shortFundingIndex;

        _updateExposure(t.assetId, t.lotSize, uint48(execPrice), t.isLong, true);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, true);
        _updateAirdropVolume(t.trader, uint256(t.marginUsdc));

        brokexVault.executeOrder(tradeId);
        emit TradeEvent(tradeId, 1);
    }

    function closePositionMarket(address trader, uint256 tradeId, int32 lotsToClose, bytes calldata oracleProof) external onlyPaymaster {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.trader != trader) revert NotYourTrade();
        if (t.state != 1) revert NotOpen();

        int32 remaining = t.lotSize - t.closedLotSize;
        if (lotsToClose == 0 || lotsToClose > remaining) {
            lotsToClose = remaining;
        }

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        _finalizeClose(t, price1e6, tradeId, lotsToClose);
    }

    function liquidatePosition(uint256 tradeId, bytes calldata oracleProof) external {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.state != 1) revert NotOpen();
        
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        uint256 liqPrice = BrokexLibrary.calculateLiquidationPrice(t, assets[t.assetId], fundingStates[t.assetId], exposures[t.assetId], block.timestamp);
        
        bool isLiq = t.isLong ? price1e6 <= liqPrice : price1e6 >= liqPrice;
        if (!isLiq) revert NotLiq();

        int32 remainingLots = t.lotSize - t.closedLotSize;

        _updateExposure(t.assetId, remainingLots, t.openPrice, t.isLong, false);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, false);
        
        t.state = 2; 
        t.closePrice = uint48(price1e6);
        t.closedLotSize = t.lotSize;

        brokexVault.liquidate(tradeId);
        emit TradeEvent(tradeId, 4);
    }

    function executeStopOrTakeProfit(uint256 tradeId, bytes calldata oracleProof) external {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.state != 1) revert NotOpen();
        
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

    function updateSLTP(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external onlyPaymaster {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.trader != trader) revert NotYourTrade();
        
        if (t.state > 1) revert Closed();
        (bool ok, string memory reason) = BrokexLibrary.validateStops(uint256(t.openPrice), t.isLong, newSL, newTP);
        if (!ok) revert(reason);
        t.stopLoss = newSL; t.takeProfit = newTP;
        emit TradeEvent(tradeId, 5);
    }

    function cancelOrder(address trader, uint256 tradeId) external onlyPaymaster {
        BrokexLibrary.Trade storage t = trades[tradeId];
        if (t.trader != trader) revert NotYourTrade();

        if (t.state != 0) revert NotPending();
        t.state = 3;
        brokexVault.cancelOrder(tradeId);
        emit TradeEvent(tradeId, 3);
    }

    function _finalizeClose(BrokexLibrary.Trade storage t, uint256 price1e6, uint256 tradeId, int32 lotsToClose) internal {
        int32 remainingLots = t.lotSize - t.closedLotSize;
        require(remainingLots >= lotsToClose, "Closing more than remaining");

        uint256 marginToRelease;
        uint256 lpToRelease;

        if (lotsToClose == remainingLots) {
            marginToRelease = t.marginUsdc;
            lpToRelease = t.lpLockedCapital;
        } else {
            uint256 currentRatioWad = (uint256(uint32(lotsToClose)) * 1e18) / uint256(uint32(remainingLots));
            marginToRelease = (uint256(t.marginUsdc) * currentRatioWad) / 1e18;
            lpToRelease = (uint256(t.lpLockedCapital) * currentRatioWad) / 1e18;
        }

        int256 netPnl = BrokexLibrary.calculateNetPnl(t, assets[t.assetId], fundingStates[t.assetId], exposures[t.assetId], price1e6, lotsToClose, block.timestamp);

        _updateExposure(t.assetId, lotsToClose, t.openPrice, t.isLong, false);
        _updateExposureLimits(t.assetId, uint64(lpToRelease), uint64(marginToRelease), t.isLong, false);

        uint256 prevClosed = uint256(uint32(t.closedLotSize));
        uint256 currentClosed = uint256(uint32(lotsToClose));
        if (prevClosed + currentClosed > 0) {
             uint256 weightedSum = (uint256(t.closePrice) * prevClosed) + (price1e6 * currentClosed);
             t.closePrice = uint48(weightedSum / (prevClosed + currentClosed));
        }

        t.closedLotSize += lotsToClose; 
        t.marginUsdc -= uint64(marginToRelease);       
        t.lpLockedCapital -= uint64(lpToRelease);      

        bool isFullClose = (t.closedLotSize >= t.lotSize);
        if (isFullClose) {
            t.state = 2; 
        }

        _updateAirdropPnL(t.trader, netPnl);
        
        brokexVault.closeTrade(tradeId, netPnl, marginToRelease, lpToRelease, isFullClose);
        
        emit TradeEvent(tradeId, 2);
    }

    // ----------------------------------------------------------------
    // 11. UNREALIZED PNL (BATCH)
    // ----------------------------------------------------------------

    function updateUnrealizedPnl(bytes calldata singleProof, uint32[] calldata assetIds) external returns (uint64 runId, bool runCompleted, int256 currentPnl) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(singleProof);
        BrokexLibrary.PnlRun storage run;
        if (currentPnlRunId == 0 || block.timestamp > pnlRuns[currentPnlRunId].startTimestamp + 2 minutes || pnlRuns[currentPnlRunId].completed) {
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
            if(!assets[assetId].listed) continue; 
            if (assetProcessedInRun[currentPnlRunId][assetId]) continue;
            uint256 price1e6 = _extractPriceFromInfo(info, assetId);
            int256 assetPnl = BrokexLibrary.calculateAssetPnlCapped(exposures[assetId], assets[assetId], price1e6);
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

    function getLastFinishedPnlRun() external view returns (int256 pnl, uint64 timestamp) {
        if (currentPnlRunId > 0) {
            BrokexLibrary.PnlRun memory run = pnlRuns[currentPnlRunId];
            if (run.completed) return (run.cumulativePnlX6, run.endTimestamp);
            else if (currentPnlRunId > 1) {
                BrokexLibrary.PnlRun memory prev = pnlRuns[currentPnlRunId - 1];
                if (prev.completed) return (prev.cumulativePnlX6, prev.endTimestamp);
            }
        }
        return (0, 0);
    }

    // ----------------------------------------------------------------
    // 14. ADD MARGIN FUNCTIONS
    // ----------------------------------------------------------------

    function addMargin(address trader, uint256 tradeId, uint64 amount6) external onlyPaymaster {
        BrokexLibrary.Trade storage t = trades[tradeId];
        
        if (t.trader != trader) revert NotYourTrade();
        if (t.state > 1) revert Closed();
        
        t.marginUsdc += amount6;

        if (t.state == 1) {
            _updateExposureLimits(t.assetId, 0, uint64(amount6), t.isLong, true);
        }

        brokexVault.addMarginToTrade(tradeId, uint256(amount6));
        emit TradeEvent(tradeId, 6);
    }

    function liquidateProfit(uint256 tradeId, bytes calldata oracleProof) external {
        BrokexLibrary.Trade storage t = trades[tradeId];

        if (t.state != 1) revert NotOpen();

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);

        int32 remaining = t.lotSize - t.closedLotSize;

        int256 netPnl = BrokexLibrary.calculateNetPnl(t, assets[t.assetId], fundingStates[t.assetId], exposures[t.assetId], price1e6, remaining, block.timestamp);

        uint256 maxPayout18 = uint256(t.lpLockedCapital) * 1e12;

        if (netPnl <= 0 || uint256(netPnl) <= maxPayout18) {
            revert("PnlUnderCap"); 
        }

        _finalizeClose(t, price1e6, tradeId, remaining);
    }
}
