// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
    BROKEX CORE V22 (GATEKEEPER MODE)
    - Mode: Toutes les exécutions passent par le Paymaster.
    - Logic: Strictement identique à la V21/V22 originale.
*/

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
    function closeTrade(uint256 tradeId, int256 pnl18) external;
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
    error NotOwner(); error NotPaymaster(); error ZeroAddr(); error AlreadyListed();
    error BadRatio(); error UnknownAsset(); error DelayTooShort(); error DelayTooLong();
    error ExposureNotZero(); error AssetDeleted(); error CloseOnlyMode(); error BadSize();
    error BadLev(); error MaxLongLimit(); error MaxShortLimit(); error NotPending();
    error PriceBad(); error NotOpen(); error NotYourTrade(); error NotLiq();
    error NotTriggered(); error Closed(); error TraderMismatch(); error PairNotInProof();
    error FutureProof(); error StalePrice(); error Mismatch(); error SlEqualsTp();
    error LongTpTooLow(); error LongSlTooHigh(); error ShortTpTooHigh(); error ShortSlTooLow();

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
    uint32 public currentSeasonId;
    
    mapping(uint32 => mapping(address => uint256)) public seasonTraderVolume;
    mapping(uint32 => uint256) public seasonTotalVolume;
    mapping(uint32 => mapping(address => uint256)) public seasonTraderWinPnL;
    mapping(uint32 => uint256) public seasonTotalWinPnL;

    struct Trade {
        address trader; uint32 assetId; bool isLong; bool isLimit;
        uint8 leverage; uint48 openPrice; uint8 state; uint32 openTimestamp;
        uint128 fundingIndex; uint48 closePrice; int32 lotSize;
        uint48 stopLoss; uint48 takeProfit; uint64 lpLockedCapital; uint64 marginUsdc;
    }

    struct Asset {
        uint32 assetId; uint32 numerator; uint32 denominator; uint32 baseFundingRate;
        uint32 spread; uint32 commission; uint32 weekendFunding; uint16 securityMultiplier;
        uint16 maxPhysicalMove; uint8  maxLeverage; uint32 maxLongLots; uint32 maxShortLots;
        uint32 maxOracleDelay; bool allowOpen; bool listed;
    }

    struct Exposure {
        int32 longLots; int32 shortLots; uint128 longValueSum; uint128 shortValueSum;
        uint128 longMaxProfit; uint128 shortMaxProfit; uint128 longMaxLoss; uint128 shortMaxLoss;
    }

    struct FundingState { uint64 lastUpdate; uint128 longFundingIndex; uint128 shortFundingIndex; }

    struct PnlRun {
        uint64 runId; uint64 startTimestamp; uint64 endTimestamp; uint32 assetsProcessed;
        uint32 totalAssetsAtStart; int256 cumulativePnlX6; bool completed;
    }

    mapping(uint256 => Trade) public trades;
    mapping(uint32 => Asset) public assets;
    mapping(uint32 => Exposure) public exposures;
    mapping(uint32 => FundingState) public fundingStates;
    
    uint64 public currentPnlRunId;
    mapping(uint64 => PnlRun) public pnlRuns;
    mapping(uint64 => mapping(uint32 => bool)) public assetProcessedInRun;
    bool public pnlCalculationActive;

    event TradeEvent(uint256 tradeId, uint8 code);
    event SeasonRotated(uint32 newSeasonId);
    event AirdropPoints(uint32 indexed seasonId, address indexed trader, uint256 volumePoints, uint256 pnlPoints);
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
    // AIRDROP LOGIC
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

    // ----------------------------------------------------------------
    // ORACLE HELPERS
    // ----------------------------------------------------------------
    function _extractPriceFromInfo(ISupraOraclePull.PriceInfo memory info, uint32 _assetId) internal view returns (uint256 price1e6) {
        uint256 len = info.pairs.length;
        bool found = false; uint256 index;
        for(uint256 i = 0; i < len; i++) {
            if(info.pairs[i] == uint256(_assetId)) { index = i; found = true; break; }
        }
        if (!found) revert PairNotInProof();
        uint256 oracleTime = info.timestamp[index] > 1000000000000 ? info.timestamp[index] / 1000 : info.timestamp[index];
        if (block.timestamp < oracleTime) revert FutureProof();
        uint256 allowedDelay = assets[_assetId].maxOracleDelay == 0 ? 60 : uint256(assets[_assetId].maxOracleDelay);
        if (block.timestamp - oracleTime > allowedDelay) revert StalePrice();
        uint256 rawPrice = info.prices[index];
        uint256 decimals = info.decimal[index];
        if (decimals > 6) price1e6 = rawPrice / (10 ** (decimals - 6));
        else if (decimals < 6) price1e6 = rawPrice * (10 ** (6 - decimals));
        else price1e6 = rawPrice;
    }

    function _getVerifiedPrice(bytes calldata _bytesProof, uint32 _assetId) internal returns (uint256) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(_bytesProof);
        return _extractPriceFromInfo(info, _assetId);
    }

    // ----------------------------------------------------------------
    // ADMIN FUNCTIONS
    // ----------------------------------------------------------------
    function listAsset(uint32 assetId, uint32 numerator, uint32 denominator, uint32 baseFundingRate, uint32 spread, uint32 commission, uint32 weekendFunding, uint16 securityMultiplier, uint16 maxPhysicalMove, uint8 maxLeverage) external onlyOwner {
        if (assets[assetId].listed) revert AlreadyListed();
        if (numerator == 0 || denominator == 0) revert BadRatio();
        assets[assetId] = Asset({assetId: assetId, numerator: numerator, denominator: denominator, baseFundingRate: baseFundingRate, spread: spread, commission: commission, weekendFunding: weekendFunding, securityMultiplier: securityMultiplier, maxPhysicalMove: maxPhysicalMove, maxLeverage: maxLeverage, maxLongLots: 1000000, maxShortLots: 1000000, maxOracleDelay: 60, allowOpen: true, listed: true});
        listedAssetsCount++;
    }

    function setAssetOracleDelay(uint32 assetId, uint32 newDelay) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].maxOracleDelay = newDelay;
    }

    function setAssetRiskLimits(uint32 assetId, uint32 _maxLongLots, uint32 _maxShortLots) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        assets[assetId].maxLongLots = _maxLongLots;
        assets[assetId].maxShortLots = _maxShortLots;
    }

    function removeAsset(uint32 assetId) external onlyOwner {
        if (!assets[assetId].listed) revert UnknownAsset();
        if (exposures[assetId].longLots != 0 || exposures[assetId].shortLots != 0) revert ExposureNotZero();
        delete assets[assetId];
    }

    // ----------------------------------------------------------------
    // EXPOSURE & MATH
    // ----------------------------------------------------------------
    function _updateExposure(uint32 assetId, int32 lotSize, uint48 price, bool isLong, bool increase) internal {
        Exposure storage e = exposures[assetId];
        uint128 value = uint128(_getNotionalValue(assetId, uint256(price), uint32(lotSize)));
        if (isLong) {
            if (increase) {
                if (uint256(uint256(int256(e.longLots))) + uint256(uint32(lotSize)) > uint256(assets[assetId].maxLongLots)) revert MaxLongLimit();
                e.longLots += lotSize; e.longValueSum += value;
            } else { e.longLots -= lotSize; e.longValueSum = _safeSub(e.longValueSum, value); }
        } else {
            if (increase) {
                if (uint256(uint256(int256(e.shortLots))) + uint256(uint32(lotSize)) > uint256(assets[assetId].maxShortLots)) revert MaxShortLimit();
                e.shortLots += lotSize; e.shortValueSum += value;
            } else { e.shortLots -= lotSize; e.shortValueSum = _safeSub(e.shortValueSum, value); }
        }
    }

    function _updateExposureLimits(uint32 assetId, uint64 lpLocked, uint64 margin, bool isLong, bool increase) internal {
        Exposure storage e = exposures[assetId];
        if (isLong) {
            if (increase) { e.longMaxProfit += uint128(lpLocked); e.longMaxLoss += uint128(margin); }
            else { e.longMaxProfit = _safeSub(e.longMaxProfit, uint128(lpLocked)); e.longMaxLoss = _safeSub(e.longMaxLoss, uint128(margin)); }
        } else {
            if (increase) { e.shortMaxProfit += uint128(lpLocked); e.shortMaxLoss += uint128(margin); }
            else { e.shortMaxProfit = _safeSub(e.shortMaxProfit, uint128(lpLocked)); e.shortMaxLoss = _safeSub(e.shortMaxLoss, uint128(margin)); }
        }
    }

    function _getNotionalValue(uint32 assetId, uint256 price, uint32 lotSize) internal view returns (uint256) {
        Asset memory a = assets[assetId];
        return (price * uint256(lotSize) * uint256(a.numerator)) / uint256(a.denominator);
    }

    function _safeSub(uint128 a, uint128 b) internal pure returns (uint128) { return (b > a) ? 0 : a - b; }

    function validateStops(uint256 entryPrice, bool isLong, uint256 stopLoss, uint256 takeProfit) public pure returns (bool, string memory) {
        if (stopLoss == 0 && takeProfit == 0) return (true, "");
        if (stopLoss != 0 && takeProfit != 0 && stopLoss == takeProfit) return (false, "SlEqualsTp");
        if (isLong) {
            if (takeProfit > 0 && takeProfit <= entryPrice) return (false, "LongTpTooLow");
            if (stopLoss > 0 && stopLoss >= entryPrice) return (false, "LongSlTooHigh");
        } else {
            if (takeProfit > 0 && takeProfit >= entryPrice) return (false, "ShortTpTooHigh");
            if (stopLoss > 0 && stopLoss <= entryPrice) return (false, "ShortSlTooLow");
        }
        return (true, "");
    }

    function calculateSpread(uint32 assetId, bool isLong, bool isOpening, uint32 lotSize) public view returns (uint256) {
        Asset memory a = assets[assetId]; Exposure memory e = exposures[assetId];
        int256 L = int256(e.longLots); int256 S = int256(e.shortLots); int256 size = int256(uint256(lotSize));
        if (isLong) { if (isOpening) L += size; else L -= size; } else { if (isOpening) S += size; else S -= size; }
        if(L < 0) L = 0; if(S < 0) S = 0;
        uint256 numerator = (L > S) ? uint256(L - S) : uint256(S - L);
        uint256 denominator = uint256(L + S + 2);
        uint256 p = ((numerator * 1e18) / denominator) ** 2 / 1e18;
        return ((L > S && isLong) || (S > L && !isLong)) ? (uint256(a.spread) * (1e18 + 3 * p)) / 1e18 : uint256(a.spread);
    }

    function calculateLiquidationPrice(uint256 tradeId) public view returns (uint256) {
        Trade memory t = trades[tradeId]; Asset memory a = assets[t.assetId];
        uint256 margin = _getNotionalValue(t.assetId, uint256(t.openPrice), uint32(t.lotSize)) / uint256(t.leverage);
        uint256 fundingPaid = (uint256(t.isLong ? fundingStates[t.assetId].longFundingIndex : fundingStates[t.assetId].shortFundingIndex) - uint256(t.fundingIndex)) * uint256(uint32(t.lotSize)) * uint256(a.numerator) / uint256(a.denominator);
        uint256 totalLossAllowable = (margin * 90 / 100) + _getNotionalValue(t.assetId, calculateSpread(t.assetId, !t.isLong, false, uint32(t.lotSize)), uint32(t.lotSize)) + fundingPaid;
        uint256 deltaPrice = (totalLossAllowable * uint256(a.denominator)) / (uint256(uint32(t.lotSize)) * uint256(a.numerator));
        return t.isLong ? (deltaPrice >= t.openPrice ? 0 : t.openPrice - deltaPrice) : t.openPrice + deltaPrice;
    }

    // ----------------------------------------------------------------
    // TRADING FUNCTIONS (ONLY PAYMASTER)
    // ----------------------------------------------------------------

    function openMarketPositionFor(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external onlyPaymaster {
        if (!assets[assetId].listed || !assets[assetId].allowOpen) revert CloseOnlyMode();
        uint256 price1e6 = _getVerifiedPrice(oracleProof, assetId);
        uint256 spread = calculateSpread(assetId, isLong, true, uint32(lotSize));
        uint256 entryPrice = isLong ? price1e6 + spread : price1e6 - spread;

        (bool stopsOk, string memory reason) = validateStops(entryPrice, isLong, stopLoss, takeProfit);
        if(!stopsOk) revert(reason);

        uint256 margin6 = (entryPrice * uint256(uint32(lotSize)) * uint256(assets[assetId].numerator)) / (uint256(assets[assetId].denominator) * uint256(leverage));
        uint256 lpLocked6 = (margin6 * uint256(assets[assetId].securityMultiplier)) / 100;
        
        uint256 tradeId = ++nextTradeID;
        trades[tradeId] = Trade({trader: trader, assetId: assetId, isLong: isLong, isLimit: false, leverage: leverage, openPrice: uint48(entryPrice), state: 1, openTimestamp: uint32(block.timestamp), fundingIndex: isLong ? fundingStates[assetId].longFundingIndex : fundingStates[assetId].shortFundingIndex, closePrice: 0, lotSize: lotSize, stopLoss: stopLoss, takeProfit: takeProfit, lpLockedCapital: uint64(lpLocked6), marginUsdc: uint64(margin6)});

        _updateExposure(assetId, lotSize, uint48(entryPrice), isLong, true);
        _updateExposureLimits(assetId, uint64(lpLocked6), uint64(margin6), isLong, true);
        _updateAirdropVolume(trader, margin6);
        brokexVault.createPosition(tradeId, trader, margin6, (margin6 * assets[assetId].commission) / 10000, lpLocked6);
        emit TradeEvent(tradeId, 1);
    }

    function placeOrderFor(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external onlyPaymaster {
        if (!assets[assetId].listed || !assets[assetId].allowOpen) revert CloseOnlyMode();
        uint256 margin6 = (uint256(targetPrice) * uint256(uint32(lotSize)) * uint256(assets[assetId].numerator)) / (uint256(assets[assetId].denominator) * uint256(leverage));
        uint256 lpLocked6 = (margin6 * uint256(assets[assetId].securityMultiplier)) / 100;
        
        uint256 tradeId = ++nextTradeID;
        trades[tradeId] = Trade({trader: trader, assetId: assetId, isLong: isLong, isLimit: isLimit, leverage: leverage, openPrice: targetPrice, state: 0, openTimestamp: uint32(block.timestamp), fundingIndex: 0, closePrice: 0, lotSize: lotSize, stopLoss: stopLoss, takeProfit: takeProfit, lpLockedCapital: uint64(lpLocked6), marginUsdc: uint64(margin6)});
        brokexVault.createOrder(tradeId, trader, margin6, (margin6 * assets[assetId].commission) / 10000, lpLocked6);
        emit TradeEvent(tradeId, 0);
    }

    function executeOrder(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        if (t.state != 0) revert NotPending();
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        bool exec = t.isLimit ? (t.isLong ? price1e6 <= t.openPrice : price1e6 >= t.openPrice) : (t.isLong ? price1e6 >= t.openPrice : price1e6 <= t.openPrice);
        if (!exec) revert PriceBad();

        uint256 spread = calculateSpread(t.assetId, t.isLong, true, uint32(t.lotSize));
        uint256 execPrice = t.isLong ? price1e6 + spread : price1e6 - spread;

        t.openPrice = uint48(execPrice); t.state = 1; t.openTimestamp = uint32(block.timestamp);
        t.fundingIndex = t.isLong ? fundingStates[t.assetId].longFundingIndex : fundingStates[t.assetId].shortFundingIndex;

        _updateExposure(t.assetId, t.lotSize, uint48(execPrice), t.isLong, true);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, true);
        _updateAirdropVolume(t.trader, uint256(t.marginUsdc));
        brokexVault.executeOrder(tradeId);
        emit TradeEvent(tradeId, 1);
    }

    function closePositionMarketFor(address trader, uint256 tradeId, bytes calldata oracleProof) external onlyPaymaster {
        Trade storage t = trades[tradeId];
        if (t.trader != trader) revert TraderMismatch();
        if (t.state != 1) revert NotOpen();
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        _finalizeClose(t, price1e6, tradeId);
    }

    function addMarginFor(address trader, uint256 tradeId, uint64 amount6) external onlyPaymaster {
        Trade storage t = trades[tradeId];
        if (t.trader != trader) revert TraderMismatch();
        if (t.state > 1) revert Closed();
        t.marginUsdc += amount6;
        _updateExposureLimits(t.assetId, 0, amount6, t.isLong, true);
        brokexVault.addMarginToTrade(tradeId, uint256(amount6));
        emit TradeEvent(tradeId, 6);
    }

    function updateSLTPFor(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external onlyPaymaster {
        Trade storage t = trades[tradeId];
        if (t.trader != trader) revert TraderMismatch();
        if (t.state > 1) revert Closed();
        t.stopLoss = newSL; t.takeProfit = newTP;
        emit TradeEvent(tradeId, 5);
    }

    function cancelOrderFor(address trader, uint256 tradeId) external onlyPaymaster {
        Trade storage t = trades[tradeId];
        if (t.trader != trader) revert TraderMismatch();
        if (t.state != 0) revert NotPending();
        t.state = 3;
        brokexVault.cancelOrder(tradeId);
        emit TradeEvent(tradeId, 3);
    }

    function liquidatePosition(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        if (t.state != 1) revert NotOpen();
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        uint256 liqPrice = calculateLiquidationPrice(tradeId);
        if (t.isLong ? price1e6 > liqPrice : price1e6 < liqPrice) revert NotLiq();
        _updateExposure(t.assetId, t.lotSize, t.openPrice, t.isLong, false);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, false);
        t.state = 2; t.closePrice = uint48(price1e6);
        brokexVault.liquidate(tradeId);
        emit TradeEvent(tradeId, 4);
    }

    function executeStopOrTakeProfit(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
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
        _finalizeClose(t, price1e6, tradeId);
    }

    function _finalizeClose(Trade storage t, uint256 price1e6, uint256 tradeId) internal {
        uint256 spread = calculateSpread(t.assetId, !t.isLong, false, uint32(t.lotSize));
        uint256 exitPrice = t.isLong ? (price1e6 > spread ? price1e6 - spread : 0) : price1e6 + spread;
        int256 delta = t.isLong ? int256(exitPrice) - int256(uint256(t.openPrice)) : int256(uint256(t.openPrice)) - int256(exitPrice);
        int256 netPnl = (delta * int256(uint256(uint32(t.lotSize))) * int256(uint256(assets[t.assetId].numerator)) / int256(uint256(assets[t.assetId].denominator))) * 1e12;
        
        _updateExposure(t.assetId, t.lotSize, t.openPrice, t.isLong, false);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, false);
        t.state = 2; t.closePrice = uint48(price1e6);
        _updateAirdropPnL(t.trader, netPnl);
        brokexVault.closeTrade(tradeId, netPnl);
        emit TradeEvent(tradeId, 2);
    }

    // ----------------------------------------------------------------
    // UNREALIZED PNL (BATCH)
    // ----------------------------------------------------------------
    function updateUnrealizedPnl(bytes calldata singleProof, uint32[] calldata assetIds) external returns (uint64 runId, bool runCompleted, int256 currentPnl) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(singleProof);
        if (currentPnlRunId == 0 || block.timestamp > pnlRuns[currentPnlRunId].startTimestamp + 2 minutes || pnlRuns[currentPnlRunId].completed) {
            currentPnlRunId++;
            PnlRun storage newRun = pnlRuns[currentPnlRunId];
            newRun.runId = currentPnlRunId; newRun.startTimestamp = uint64(block.timestamp);
            newRun.totalAssetsAtStart = uint32(listedAssetsCount);
            pnlCalculationActive = true; emit PnlRunStarted(currentPnlRunId, uint32(listedAssetsCount));
        }
        PnlRun storage run = pnlRuns[currentPnlRunId];
        for (uint256 i = 0; i < assetIds.length; i++) {
            uint32 assetId = assetIds[i];
            if(!assets[assetId].listed || assetProcessedInRun[currentPnlRunId][assetId]) continue;
            run.cumulativePnlX6 += _calculateAssetPnlCapped(assetId, _extractPriceFromInfo(info, assetId));
            assetProcessedInRun[currentPnlRunId][assetId] = true; run.assetsProcessed++;
        }
        if (run.assetsProcessed >= run.totalAssetsAtStart) {
            run.completed = true; run.endTimestamp = uint64(block.timestamp);
            pnlCalculationActive = false; emit PnlRunCompleted(currentPnlRunId, run.cumulativePnlX6);
        }
        return (currentPnlRunId, run.completed, run.cumulativePnlX6);
    }

    function _calculateAssetPnlCapped(uint32 assetId, uint256 currentPrice1e6) internal view returns (int256 pnlX6) {
        Exposure memory e = exposures[assetId]; Asset memory a = assets[assetId];
        if (e.longLots == 0 && e.shortLots == 0) return 0;
        int256 longPnl = 0;
        if (e.longLots > 0) {
            longPnl = int256((currentPrice1e6 * uint256(uint32(e.longLots)) * uint256(a.numerator)) / uint256(a.denominator)) - int256(uint256(e.longValueSum));
            if (longPnl > 0) longPnl = longPnl > int256(uint256(e.longMaxProfit)) ? int256(uint256(e.longMaxProfit)) : longPnl;
            else longPnl = (-longPnl) > int256(uint256(e.longMaxLoss)) ? -int256(uint256(e.longMaxLoss)) : longPnl;
        }
        int256 shortPnl = 0;
        if (e.shortLots > 0) {
            shortPnl = int256(uint256(e.shortValueSum)) - int256((currentPrice1e6 * uint256(uint32(e.shortLots)) * uint256(a.numerator)) / uint256(a.denominator));
            if (shortPnl > 0) shortPnl = shortPnl > int256(uint256(e.shortMaxProfit)) ? int256(uint256(e.shortMaxProfit)) : shortPnl;
            else shortPnl = (-shortPnl) > int256(uint256(e.shortMaxLoss)) ? -int256(uint256(e.shortMaxLoss)) : shortPnl;
        }
        return -(longPnl + shortPnl);
    }
    
    function getTradeStatesFromList(uint256[] calldata tradeIds) external view returns (uint8[] memory states) {
        uint256 len = tradeIds.length;
        // Limite de sécurité pour le RPC
        if (len > 1000) revert("List too long");

        states = new uint8[](len);
        
        for (uint256 i = 0; i < len; i++) {
            states[i] = trades[tradeIds[i]].state;
        }
    }

  
    function getTradeSLTPFromList(uint256[] calldata tradeIds) external view returns (uint48[] memory stopLosses, uint48[] memory takeProfits) {
        uint256 len = tradeIds.length;
        if (len > 1000) revert("List too long");

        stopLosses = new uint48[](len);
        takeProfits = new uint48[](len);
        
        for (uint256 i = 0; i < len; i++) {
            Trade storage t = trades[tradeIds[i]];
            stopLosses[i] = t.stopLoss;
            takeProfits[i] = t.takeProfit;
        }
    }
}
