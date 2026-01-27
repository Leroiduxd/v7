// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
    BROKEX CORE V24.2 (FINAL FIX - MISSING AIRDROP FUNCTIONS)
    
    FIX LOG:
    - Re-added internal functions '_updateAirdropVolume' and '_updateAirdropPnL' 
      which were accidentally removed during optimization.
*/

// ==========================================
// 1. GLOBAL STRUCTS (Shared)
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
    uint128 fundingIndex;
    int32 lotSize;          
    uint32 closedLots;      
    uint48 avgClosePrice;   
    uint48 stopLoss;        
    uint48 takeProfit;      
    uint48 closePrice;      
    uint64 lpLockedCapital; 
    uint64 marginUsdc;      
}

struct OrderRequest {
    uint256 id;
    uint256 tradeId;
    bool isStop; 
    uint48 triggerPrice;
    uint32 lots; 
    uint8 status; 
}

struct Asset {
    uint32 assetId;
    uint32 numerator;        
    uint32 denominator;      
    uint32 baseFundingRate;
    uint32 spread;
    uint32 commission;
    uint32 weekendFunding;
    uint16 securityMultiplier;
    uint16 maxPhysicalMove;
    uint8  maxLeverage;
    uint32 maxLongLots;      
    uint32 maxShortLots;     
    uint32 maxOracleDelay;   
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
// 2. INTERFACES
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
    function addMarginToTrade(address trader, uint256 amount6) external;
}

// ==========================================
// 3. MATH LIBRARY (Size Reduction)
// ==========================================

library BrokexMath {
    error BadLev();
    error SlEqualsTp();
    error LongTpTooLow();
    error LongSlTooHigh();
    error ShortTpTooHigh();
    error ShortSlTooLow();

    function safeSub(uint128 a, uint128 b) internal pure returns (uint128) {
        return (b > a) ? 0 : a - b;
    }

    function isRoundLeverage(uint8 lev) internal pure returns (bool) {
        return (lev == 1 || lev == 2 || lev == 3 || lev == 5 || lev == 10 || lev == 20 || lev == 25 || lev == 50 || lev == 100);
    }

    function getNotionalValue(Asset memory a, uint256 price, uint32 lotSize) internal pure returns (uint256) {
        return (price * uint256(lotSize) * uint256(a.numerator)) / uint256(a.denominator);
    }

    function calculateMargin6(Asset memory a, uint256 entryPrice, uint32 lotSize, uint8 leverage) internal pure returns (uint256) {
        uint256 notional = getNotionalValue(a, entryPrice, lotSize);
        return notional / uint256(leverage);
    }

    function calculateLockedCapital(Asset memory a, uint256 entryPrice, uint32 lotSize, uint8 leverage) internal pure returns (uint256) {
        uint256 notional = getNotionalValue(a, entryPrice, lotSize);
        uint256 margin = notional / uint256(leverage);
        uint256 maxProfitLev = (margin * uint256(a.securityMultiplier)) / 100;
        uint256 physMoveVal = (entryPrice * uint256(a.maxPhysicalMove)) / 100;
        uint256 physProfit = getNotionalValue(a, physMoveVal, lotSize);
        return (maxProfitLev < physProfit) ? maxProfitLev : physProfit;
    }

    function calculateSpread(Asset memory a, Exposure memory e, bool isLong, bool isOpening, uint32 lotSize) internal pure returns (uint256) {
       uint256 base = uint256(a.spread);
       int256 L = int256(e.longLots); 
       int256 S = int256(e.shortLots); 
       int256 size = int256(uint256(lotSize));

       if (isLong) { if (isOpening) L += size; else L -= size; } 
       else { if (isOpening) S += size; else S -= size; }
       
       if(L < 0) L = 0; if(S < 0) S = 0;
       
       uint256 numerator = (L > S) ? uint256(L - S) : uint256(S - L);
       uint256 denominator = uint256(L + S + 2);
       
       if (denominator == 0) return base;
       uint256 p = ((numerator * 1e18) / denominator) ** 2 / 1e18;
       bool dominant = (L > S && isLong) || (S > L && !isLong);
       return dominant ? (base * (1e18 + 3 * p)) / 1e18 : base;
    }

    function validateStops(uint256 entryPrice, bool isLong, uint256 stopLoss, uint256 takeProfit) internal pure returns (bool, string memory) {
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

    function computeFundingRateQuadratic(uint256 L, uint256 S, uint256 baseFunding) internal pure returns (uint256, uint256) {
        if (L == S) return (baseFunding, baseFunding);
        uint256 numerator = (L > S) ? (L - S) : (S - L);
        uint256 denominator = L + S + 2;
        uint256 r = (numerator * 1e18) / denominator;
        uint256 p = (r * r) / 1e18;
        uint256 dominantRate = (baseFunding * (1e18 + 3 * p)) / 1e18;
        return (L > S) ? (dominantRate, baseFunding) : (baseFunding, dominantRate);
    }
}

// ==========================================
// 4. MAIN CONTRACT
// ==========================================

contract BrokexCore {
    // ----------------------------------------------------------------
    // ERRORS
    // ----------------------------------------------------------------
    error NotOwner(); error NotPaymaster(); error ZeroAddr(); error AlreadyListed();
    error BadRatio(); error UnknownAsset(); error DelayTooShort(); error DelayTooLong();
    error ExposureNotZero(); error AssetDeleted(); error CloseOnlyMode();
    error BadSize(); error BadLev(); error MaxLongLimit(); error MaxShortLimit();
    error NotPending(); error PriceBad(); error NotOpen(); error NotYourTrade();
    error NotLiq(); error NotTriggered(); error Closed(); error TraderMismatch();
    error PairNotInProof(); error FutureProof(); error StalePrice();
    error TooManyLots(); error OrderNotActive(); error InvalidPartialSize();

    // ----------------------------------------------------------------
    // STATE
    // ----------------------------------------------------------------
    uint256 constant SECONDS_PER_WEEK = 604800;
    uint256 constant OFFSET_TO_MONDAY = 259200; 

    ISupraOraclePull public immutable oracle;
    IBrokexVault public brokexVault;
    address public immutable owner;
    address public paymaster;

    uint256 public nextTradeID;
    uint256 public nextOrderId; 
    uint256 public listedAssetsCount;

    // Airdrop
    uint32 public currentSeasonId;
    mapping(uint32 => mapping(address => uint256)) public seasonTraderVolume;
    mapping(uint32 => uint256) public seasonTotalVolume;
    mapping(uint32 => mapping(address => uint256)) public seasonTraderWinPnL;
    mapping(uint32 => uint256) public seasonTotalWinPnL;

    // Data
    mapping(uint256 => Trade) public trades;
    mapping(uint256 => OrderRequest) public orderRequests;
    mapping(uint32 => Asset) public assets;
    mapping(uint32 => Exposure) public exposures;
    mapping(uint32 => FundingState) public fundingStates;
    
    // Batch PnL
    uint64 public currentPnlRunId;
    mapping(uint64 => PnlRun) public pnlRuns;
    mapping(uint64 => mapping(uint32 => bool)) public assetProcessedInRun;
    bool public pnlCalculationActive;

    // Events
    event SeasonRotated(uint32 newSeasonId);
    event AirdropPoints(uint32 indexed seasonId, address indexed trader, uint256 volumePoints, uint256 pnlPoints);
    event OrderRequestEvent(uint256 indexed orderId, uint256 indexed tradeId, uint8 orderType, uint8 status);
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
    // AIRDROP LOGIC (RESTORED)
    // ----------------------------------------------------------------
    function startNewSeason() external onlyOwner { currentSeasonId++; emit SeasonRotated(currentSeasonId); }
    
    // ✅ RESTORED
    function _updateAirdropVolume(address trader, uint256 margin6) internal {
        seasonTraderVolume[currentSeasonId][trader] += margin6;
        seasonTotalVolume[currentSeasonId] += margin6;
        emit AirdropPoints(currentSeasonId, trader, margin6, 0);
    }
    
    // ✅ RESTORED
    function _updateAirdropPnL(address trader, int256 pnl18) internal {
        if (pnl18 > 0) {
            uint256 profit6 = uint256(pnl18) / 1e12; 
            seasonTraderWinPnL[currentSeasonId][trader] += profit6;
            seasonTotalWinPnL[currentSeasonId] += profit6;
            emit AirdropPoints(currentSeasonId, trader, 0, profit6);
        }
    }

    // ----------------------------------------------------------------
    // ADMIN & HELPERS
    // ----------------------------------------------------------------
    function listAsset(uint32 assetId, uint32 numerator, uint32 denominator, uint32 baseFundingRate, uint32 spread, uint32 commission, uint32 weekendFunding, uint16 securityMultiplier, uint16 maxPhysicalMove, uint8 maxLeverage) external onlyOwner {
        if (assets[assetId].listed) revert AlreadyListed();
        if (numerator == 0 || denominator == 0) revert BadRatio();
        assets[assetId] = Asset({assetId: assetId, numerator: numerator, denominator: denominator, baseFundingRate: baseFundingRate, spread: spread, commission: commission, weekendFunding: weekendFunding, securityMultiplier: securityMultiplier, maxPhysicalMove: maxPhysicalMove, maxLeverage: maxLeverage, maxLongLots: 1000000, maxShortLots: 1000000, maxOracleDelay: 60, allowOpen: true, listed: true});
        listedAssetsCount++;
    }
    // (Other admin setters omitted for brevity but logic is standard setters)
    function setAssetOracleDelay(uint32 assetId, uint32 newDelay) external onlyOwner { assets[assetId].maxOracleDelay = newDelay; }
    function setAssetRiskLimits(uint32 assetId, uint32 l, uint32 s) external onlyOwner { assets[assetId].maxLongLots = l; assets[assetId].maxShortLots = s; }
    function setAssetTradable(uint32 assetId, bool o) external onlyOwner { assets[assetId].allowOpen = o; }
    
    function _getVerifiedPrice(bytes calldata _bytesProof, uint32 _assetId) internal returns (uint256) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(_bytesProof);
        uint256 len = info.pairs.length;
        for(uint256 i = 0; i < len; i++) {
            if(info.pairs[i] == uint256(_assetId)) {
                // Inline extraction to save gas/size
                uint256 t = info.timestamp[i];
                if (t > 1000000000000) t = t / 1000;
                if (block.timestamp < t) revert FutureProof();
                if (block.timestamp - t > assets[_assetId].maxOracleDelay) revert StalePrice();
                
                uint256 p = info.prices[i];
                uint256 d = info.decimal[i];
                return (d > 6) ? p / (10 ** (d - 6)) : (d < 6 ? p * (10 ** (6 - d)) : p);
            }
        }
        revert PairNotInProof();
    }

    // ----------------------------------------------------------------
    // CORE TRADING
    // ----------------------------------------------------------------

    function addMargin(uint256 tradeId, uint64 amount6) external {
        Trade storage t = trades[tradeId];
        if (msg.sender != t.trader) revert NotYourTrade();
        if (t.state > 1) revert Closed(); 
        
        t.marginUsdc += amount6;
        _updateExposureLimits(t.assetId, 0, amount6, t.isLong, true);
        brokexVault.addMarginToTrade(t.trader, amount6);
        emit TradeEvent(tradeId, 6);
    }

    function closePositionPartially(uint256 tradeId, uint32 lotsToClose, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        if (msg.sender != t.trader) revert NotYourTrade();
        _executePartialClose(tradeId, lotsToClose, oracleProof);
    }

    // SL/TP Managers
    function createOrderRequest(uint256 tradeId, bool isStop, uint48 triggerPrice, uint32 lots) external {
        Trade storage t = trades[tradeId];
        if (msg.sender != t.trader) revert NotYourTrade();
        if (t.state != 1) revert NotOpen(); 
        _createOrderRequest(tradeId, isStop, triggerPrice, lots);
    }

    function cancelOrderRequest(uint256 orderId) external {
        OrderRequest storage req = orderRequests[orderId];
        Trade storage t = trades[req.tradeId];
        if (msg.sender != t.trader) revert NotYourTrade();
        if (req.status != 1) revert OrderNotActive();
        req.status = 3; 
        emit OrderRequestEvent(orderId, req.tradeId, req.isStop ? 1 : 2, 3);
    }

    function executeOrderRequest(uint256 orderId, bytes calldata oracleProof) external {
        OrderRequest storage req = orderRequests[orderId];
        if (req.status != 1) revert OrderNotActive();
        Trade storage t = trades[req.tradeId];
        
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        bool triggered = false;
        if (req.isStop) {
            if (t.isLong && price1e6 <= req.triggerPrice) triggered = true;
            if (!t.isLong && price1e6 >= req.triggerPrice) triggered = true;
        } else {
            if (t.isLong && price1e6 >= req.triggerPrice) triggered = true;
            if (!t.isLong && price1e6 <= req.triggerPrice) triggered = true;
        }

        if (!triggered) revert NotTriggered();

        req.status = 2; 
        
        // Smart Execution (Capping)
        uint32 currentLots = uint32(t.lotSize);
        uint32 lotsToExecute = req.lots;
        if (currentLots == 0) {
            emit OrderRequestEvent(orderId, req.tradeId, req.isStop ? 1 : 2, 2);
            return;
        }
        if (lotsToExecute > currentLots) lotsToExecute = currentLots;

        _executePartialClose(req.tradeId, lotsToExecute, oracleProof);
        emit OrderRequestEvent(orderId, req.tradeId, req.isStop ? 1 : 2, 2);
    }

    // INTERNAL LOGIC
    function _createOrderRequest(uint256 tradeId, bool isStop, uint48 triggerPrice, uint32 lots) internal {
        Trade storage t = trades[tradeId];
        if (lots > uint32(t.lotSize)) revert TooManyLots();
        
        (bool ok, string memory reason) = BrokexMath.validateStops(uint256(t.openPrice), t.isLong, isStop ? triggerPrice : 0, isStop ? 0 : triggerPrice);
        if (!ok) revert(reason);

        uint256 orderId = ++nextOrderId;
        orderRequests[orderId] = OrderRequest({id: orderId, tradeId: tradeId, isStop: isStop, triggerPrice: triggerPrice, lots: lots, status: 1});
        emit OrderRequestEvent(orderId, tradeId, isStop ? 1 : 2, 1);
    }

    function _executePartialClose(uint256 tradeId, uint32 lotsToClose, bytes calldata oracleProof) internal {
        Trade storage t = trades[tradeId];
        if (t.state != 1) revert NotOpen();
        
        uint32 currentLots = uint32(t.lotSize);
        if (lotsToClose > currentLots) lotsToClose = currentLots;
        if (lotsToClose == 0) revert InvalidPartialSize();

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        
        uint256 closeRatio1e18 = (uint256(lotsToClose) * 1e18) / uint256(currentLots);
        uint64 marginReleased = uint64((uint256(t.marginUsdc) * closeRatio1e18) / 1e18);
        uint64 lockReleased = uint64((uint256(t.lpLockedCapital) * closeRatio1e18) / 1e18);

        int256 netPnl = _calculateNetPnlPartial(t, price1e6, lotsToClose);

        _updateExposure(t.assetId, int32(lotsToClose), t.openPrice, t.isLong, false); 
        _updateExposureLimits(t.assetId, lockReleased, marginReleased, t.isLong, false);

        uint256 oldTotalVal = uint256(t.avgClosePrice) * uint256(t.closedLots);
        uint256 newCloseVal = price1e6 * uint256(lotsToClose);
        uint256 totalClosed = uint256(t.closedLots) + uint256(lotsToClose);
        t.avgClosePrice = uint48((oldTotalVal + newCloseVal) / totalClosed);
        t.closedLots += lotsToClose;

        t.lotSize -= int32(lotsToClose);
        t.marginUsdc -= marginReleased;
        t.lpLockedCapital -= lockReleased;

        _updateAirdropPnL(t.trader, netPnl);
        brokexVault.closeTrade(tradeId, netPnl);

        if (t.lotSize == 0) {
            t.state = 2; 
            t.closePrice = uint48(price1e6);
        }
        emit TradeEvent(tradeId, 2);
    }

    function _openMarketPosition(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) internal {
        if (!assets[assetId].listed) revert AssetDeleted();
        if (!assets[assetId].allowOpen) revert CloseOnlyMode();
        if (lotSize <= 0) revert BadSize();
        if (!BrokexMath.isRoundLeverage(leverage)) revert BadLev();

        uint256 price1e6 = _getVerifiedPrice(oracleProof, assetId);
        uint256 spread = BrokexMath.calculateSpread(assets[assetId], exposures[assetId], isLong, true, uint32(lotSize));
        uint256 entryPrice = isLong ? price1e6 + spread : price1e6 - spread;

        (bool ok, string memory r) = BrokexMath.validateStops(entryPrice, isLong, stopLoss, takeProfit);
        if(!ok) revert(r);

        uint256 margin6 = BrokexMath.calculateMargin6(assets[assetId], entryPrice, uint32(lotSize), leverage);
        uint256 lpLocked6 = BrokexMath.calculateLockedCapital(assets[assetId], entryPrice, uint32(lotSize), leverage);
        uint256 commission6 = (margin6 * assets[assetId].commission) / 10000;

        uint256 tradeId = ++nextTradeID;
        Trade storage t = trades[tradeId];
        
        t.trader = trader; t.assetId = assetId; t.isLong = isLong; t.isLimit = false;
        t.leverage = leverage; t.openPrice = uint48(entryPrice); 
        t.state = 1; t.openTimestamp = uint32(block.timestamp);
        t.lotSize = lotSize; 
        t.lpLockedCapital = uint64(lpLocked6); t.marginUsdc = uint64(margin6);
        
        FundingState memory fs = fundingStates[assetId];
        t.fundingIndex = isLong ? fs.longFundingIndex : fs.shortFundingIndex;

        _updateExposure(assetId, lotSize, uint48(entryPrice), isLong, true);
        _updateExposureLimits(assetId, uint64(lpLocked6), uint64(margin6), isLong, true);
        
        _updateAirdropVolume(trader, uint256(margin6));
        brokexVault.createPosition(tradeId, trader, margin6, commission6, lpLocked6);
        emit TradeEvent(tradeId, 1);

        if (stopLoss > 0) _createOrderRequest(tradeId, true, stopLoss, uint32(lotSize));
        if (takeProfit > 0) _createOrderRequest(tradeId, false, takeProfit, uint32(lotSize));
    }

    function _placeOrder(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) internal {
        if (!assets[assetId].listed) revert AssetDeleted();
        if (!assets[assetId].allowOpen) revert CloseOnlyMode();
        (bool ok, string memory reason) = BrokexMath.validateStops(uint256(targetPrice), isLong, stopLoss, takeProfit);
        if(!ok) revert(reason);

        uint256 margin6 = BrokexMath.calculateMargin6(assets[assetId], uint256(targetPrice), uint32(lotSize), leverage);
        uint256 lpLocked6 = BrokexMath.calculateLockedCapital(assets[assetId], uint256(targetPrice), uint32(lotSize), leverage);
        uint256 commission6 = (margin6 * assets[assetId].commission) / 10000;

        uint256 tradeId = ++nextTradeID;
        trades[tradeId] = Trade({
            trader: trader, assetId: assetId, isLong: isLong, isLimit: isLimit, 
            leverage: leverage, openPrice: targetPrice, state: 0, 
            openTimestamp: uint32(block.timestamp), fundingIndex: 0, 
            lotSize: lotSize, closedLots: 0, avgClosePrice: 0,
            stopLoss: stopLoss, takeProfit: takeProfit, closePrice: 0,
            lpLockedCapital: uint64(lpLocked6), marginUsdc: uint64(margin6)
        });
        brokexVault.createOrder(tradeId, trader, margin6, commission6, lpLocked6);
        emit TradeEvent(tradeId, 0);
    }

    function _executeOrder(uint256 tradeId, bytes calldata oracleProof) internal {
        Trade storage t = trades[tradeId];
        if (t.state != 0) revert NotPending();
        if (!assets[t.assetId].allowOpen) revert CloseOnlyMode();
        
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        bool executable = t.isLimit 
            ? (t.isLong ? price1e6 <= uint256(t.openPrice) : price1e6 >= uint256(t.openPrice))
            : (t.isLong ? price1e6 >= uint256(t.openPrice) : price1e6 <= uint256(t.openPrice));
        
        if (!executable) revert PriceBad();

        uint256 spread = BrokexMath.calculateSpread(assets[t.assetId], exposures[t.assetId], t.isLong, true, uint32(t.lotSize));
        uint256 execPrice = t.isLong ? price1e6 + spread : price1e6 - spread;

        t.openPrice = uint48(execPrice); t.state = 1; t.openTimestamp = uint32(block.timestamp);
        FundingState memory fs = fundingStates[t.assetId];
        t.fundingIndex = t.isLong ? fs.longFundingIndex : fs.shortFundingIndex;
        
        _updateExposure(t.assetId, t.lotSize, uint48(execPrice), t.isLong, true);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, true);
        _updateAirdropVolume(t.trader, uint256(t.marginUsdc));

        brokexVault.executeOrder(tradeId);
        emit TradeEvent(tradeId, 1);

        if (t.stopLoss > 0) { _createOrderRequest(tradeId, true, t.stopLoss, uint32(t.lotSize)); t.stopLoss = 0; }
        if (t.takeProfit > 0) { _createOrderRequest(tradeId, false, t.takeProfit, uint32(t.lotSize)); t.takeProfit = 0; }
    }

    function _cancelOrder(uint256 tradeId) internal {
        Trade storage t = trades[tradeId];
        if (t.state != 0) revert NotPending();
        t.state = 3;
        brokexVault.cancelOrder(tradeId);
        emit TradeEvent(tradeId, 3);
    }

    // ----------------------------------------------------------------
    // EXPOSURE & CALCS & UTILS
    // ----------------------------------------------------------------

    // ✅ FIXED: Liquidation Logic Re-Implemented Inline for Optimization
    function liquidatePosition(uint256 tradeId, bytes calldata oracleProof) external { 
        Trade storage t = trades[tradeId];
        if (t.state != 1) revert NotOpen();
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        
        Asset memory a = assets[t.assetId];
        FundingState memory f = fundingStates[t.assetId];

        uint256 openPrice = uint256(t.openPrice);
        uint256 margin = BrokexMath.getNotionalValue(a, openPrice, uint32(t.lotSize)) / uint256(t.leverage);
        uint256 liquidationLoss = (margin * 90) / 100;

        uint256 spread = BrokexMath.calculateSpread(a, exposures[t.assetId], !t.isLong, false, uint32(t.lotSize));
        uint256 spreadCost = BrokexMath.getNotionalValue(a, spread, uint32(t.lotSize));
        
        uint256 idx = t.isLong ? f.longFundingIndex : f.shortFundingIndex;
        uint256 fc = (uint256(idx) - uint256(t.fundingIndex)) * uint256(uint32(t.lotSize)) * uint256(a.numerator) / uint256(a.denominator);
        uint256 wc = _calculateWeekendFundingPartial(t, uint32(t.lotSize)) * uint256(a.numerator) / uint256(a.denominator);

        uint256 totalLoss = liquidationLoss + spreadCost + fc + wc;
        uint256 delta = (totalLoss * uint256(a.denominator)) / (uint256(uint32(t.lotSize)) * uint256(a.numerator));
        uint256 liqPrice = t.isLong ? (openPrice > delta ? openPrice - delta : 0) : openPrice + delta;

        bool isLiq = t.isLong ? price1e6 <= liqPrice : price1e6 >= liqPrice;
        if (!isLiq) revert NotLiq();

        _updateExposure(t.assetId, t.lotSize, t.openPrice, t.isLong, false);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, false);
        t.state = 2; t.closePrice = uint48(price1e6);
        brokexVault.liquidate(tradeId);
        emit TradeEvent(tradeId, 4);
    }

    function _updateExposure(uint32 assetId, int32 lotSize, uint48 price, bool isLong, bool increase) internal {
        Exposure storage e = exposures[assetId];
        uint256 rawVal = BrokexMath.getNotionalValue(assets[assetId], uint256(price), uint32(lotSize));
        uint128 value = uint128(rawVal);
        if (isLong) {
            if (increase) {
                if (uint256(uint256(int256(e.longLots))) + uint256(uint32(lotSize)) > uint256(assets[assetId].maxLongLots)) revert MaxLongLimit();
                e.longLots += lotSize; e.longValueSum += value;
            } else {
                e.longLots -= lotSize; e.longValueSum = BrokexMath.safeSub(e.longValueSum, value);
            }
        } else {
            if (increase) {
                if (uint256(uint256(int256(e.shortLots))) + uint256(uint32(lotSize)) > uint256(assets[assetId].maxShortLots)) revert MaxShortLimit();
                e.shortLots += lotSize; e.shortValueSum += value;
            } else {
                e.shortLots -= lotSize; e.shortValueSum = BrokexMath.safeSub(e.shortValueSum, value);
            }
        }
    }

    function _updateExposureLimits(uint32 assetId, uint64 lpLocked, uint64 margin, bool isLong, bool increase) internal {
        Exposure storage e = exposures[assetId];
        uint128 locked = uint128(lpLocked);
        uint128 marg = uint128(margin);
        if (isLong) {
            if (increase) {
                e.longMaxProfit += locked; e.longMaxLoss += marg;
            } else {
                e.longMaxProfit = BrokexMath.safeSub(e.longMaxProfit, locked); e.longMaxLoss = BrokexMath.safeSub(e.longMaxLoss, marg);
            }
        } else {
            if (increase) {
                e.shortMaxProfit += locked; e.shortMaxLoss += marg;
            } else {
                e.shortMaxProfit = BrokexMath.safeSub(e.shortMaxProfit, locked); e.shortMaxLoss = BrokexMath.safeSub(e.shortMaxLoss, marg);
            }
        }
    }

    function _calculateNetPnlPartial(Trade storage t, uint256 price1e6, uint32 calcLots) internal view returns (int256) {
        uint256 spread = BrokexMath.calculateSpread(assets[t.assetId], exposures[t.assetId], !t.isLong, false, uint32(t.lotSize));
        uint256 exitPrice = t.isLong ? (spread > price1e6 ? 0 : price1e6 - spread) : price1e6 + spread;
        int256 delta = t.isLong ? int256(exitPrice) - int256(uint256(t.openPrice)) : int256(uint256(t.openPrice)) - int256(exitPrice);
        Asset memory a = assets[t.assetId];
        int256 rawPnl = (delta * int256(uint256(calcLots)) * int256(uint256(a.numerator))) / int256(uint256(a.denominator));
        
        FundingState memory fs = fundingStates[t.assetId];
        uint256 currentIdx = t.isLong ? fs.longFundingIndex : fs.shortFundingIndex;
        uint256 fundingPaid = (uint256(currentIdx) - uint256(t.fundingIndex)) * uint256(calcLots) * uint256(a.numerator) / uint256(a.denominator);
        uint256 wFee = _calculateWeekendFundingPartial(t, calcLots);
        uint256 weekendFees = wFee * uint256(a.numerator) / uint256(a.denominator);

        return (rawPnl * 1e12) - int256(fundingPaid + weekendFees) * 1e12;
    }

    function _calculateWeekendFundingPartial(Trade storage t, uint32 calcLots) internal view returns (uint256) {
        Asset memory a = assets[t.assetId];
        if (a.weekendFunding == 0) return 0;
        uint256 closeTs = block.timestamp;
        if (closeTs <= t.openTimestamp) return 0;
        uint256 offset = 259200; 
        uint256 secondsPerWeek = 604800;
        uint256 openWeek = (uint256(t.openTimestamp) + offset) / secondsPerWeek;
        uint256 currentWeek = (closeTs + offset) / secondsPerWeek;
        if (currentWeek <= openWeek) return 0;
        return (currentWeek - openWeek) * uint256(a.weekendFunding) * uint256(calcLots);
    }

    function updateFundingRates(uint32[] calldata assetIds) external {
        for (uint256 i = 0; i < assetIds.length; i++) {
            uint32 assetId = assetIds[i];
            FundingState storage f = fundingStates[assetId];
            if (block.timestamp < f.lastUpdate + 1 hours) continue;
            Asset memory a = assets[assetId];
            Exposure memory e = exposures[assetId];
            uint256 L = uint256(int256(e.longLots) > 0 ? uint256(int256(e.longLots)) : 0);
            uint256 S = uint256(int256(e.shortLots) > 0 ? uint256(int256(e.shortLots)) : 0);
            (uint256 lR, uint256 sR) = BrokexMath.computeFundingRateQuadratic(L, S, uint256(a.baseFundingRate));
            f.longFundingIndex += uint128(lR);
            f.shortFundingIndex += uint128(sR);
            f.lastUpdate = uint64(block.timestamp);
        }
    }

    function getExposureAndAveragePrices(uint32 assetId) public view returns (uint32, uint32, uint256, uint256) {
        Exposure memory e = exposures[assetId];
        return (uint32(e.longLots), uint32(e.shortLots), (e.longLots > 0) ? uint256(e.longValueSum)/uint256(uint32(e.longLots)) : 0, (e.shortLots > 0) ? uint256(e.shortValueSum)/uint256(uint32(e.shortLots)) : 0);
    }
    
    // Wrappers External
    function openMarketPosition(uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external { _openMarketPosition(msg.sender, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof); }
    function placeOrder(uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external { _placeOrder(msg.sender, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit); }
    function executeOrder(uint256 tradeId, bytes calldata oracleProof) external { _executeOrder(tradeId, oracleProof); }
    function closePositionMarket(uint256 tradeId, bytes calldata oracleProof) external { 
        Trade storage t = trades[tradeId];
        if (msg.sender != t.trader) revert NotYourTrade();
        _executePartialClose(tradeId, uint32(t.lotSize), oracleProof); 
    }
    function cancelOrder(uint256 tradeId) external { 
        Trade storage t = trades[tradeId];
        if (msg.sender != t.trader) revert NotYourTrade();
        _cancelOrder(tradeId); 
    }

    // Paymaster
    function openMarketPositionFor(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external onlyPaymaster { _openMarketPosition(trader, assetId, isLong, leverage, lotSize, stopLoss, takeProfit, oracleProof); }
    function placeOrderFor(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external onlyPaymaster { _placeOrder(trader, assetId, isLong, isLimit, leverage, lotSize, targetPrice, stopLoss, takeProfit); }
    function executeOrderFor(uint256 tradeId, bytes calldata oracleProof) external onlyPaymaster { _executeOrder(tradeId, oracleProof); }
    function closePositionMarketFor(address trader, uint256 tradeId, bytes calldata oracleProof) external onlyPaymaster { 
        Trade storage t = trades[tradeId];
        if (t.trader != trader) revert TraderMismatch();
        _executePartialClose(tradeId, uint32(t.lotSize), oracleProof); 
    }
    function cancelOrderFor(address trader, uint256 tradeId) external onlyPaymaster { 
        Trade storage t = trades[tradeId];
        if (t.trader != trader) revert TraderMismatch();
        _cancelOrder(tradeId); 
    }

    // Batch PnL
    function updateUnrealizedPnl(bytes calldata singleProof, uint32[] calldata assetIds) external returns (uint64, bool, int256) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(singleProof);
        PnlRun storage run;
        if (currentPnlRunId == 0 || block.timestamp > pnlRuns[currentPnlRunId].startTimestamp + 2 minutes || pnlRuns[currentPnlRunId].completed) {
            currentPnlRunId++;
            run = pnlRuns[currentPnlRunId];
            run.runId = currentPnlRunId; run.startTimestamp = uint64(block.timestamp); run.totalAssetsAtStart = uint32(listedAssetsCount);
            pnlCalculationActive = true; emit PnlRunStarted(currentPnlRunId, uint32(listedAssetsCount));
        } else { run = pnlRuns[currentPnlRunId]; }
        if (block.timestamp > run.startTimestamp + 2 minutes) { emit PnlRunExpired(currentPnlRunId); return (currentPnlRunId, false, run.cumulativePnlX6); }
        for (uint256 i = 0; i < assetIds.length; i++) {
            uint32 assetId = assetIds[i];
            if(!assets[assetId].listed) continue; 
            if (assetProcessedInRun[currentPnlRunId][assetId]) continue;
            uint256 price1e6;
            bool found;
            for(uint256 k=0; k<info.pairs.length; k++) {
                if(info.pairs[k] == uint256(assetId)) {
                    uint256 p = info.prices[k]; uint256 d = info.decimal[k];
                    price1e6 = (d > 6) ? p/(10**(d-6)) : (d < 6 ? p*(10**(6-d)) : p);
                    found = true; break;
                }
            }
            if(!found) continue;

            int256 assetPnl = _calculateAssetPnlCapped(assetId, price1e6);
            run.cumulativePnlX6 += assetPnl;
            assetProcessedInRun[currentPnlRunId][assetId] = true;
            run.assetsProcessed++;
        }
        if (run.assetsProcessed >= run.totalAssetsAtStart) {
            run.completed = true; run.endTimestamp = uint64(block.timestamp); pnlCalculationActive = false;
            emit PnlRunCompleted(currentPnlRunId, run.cumulativePnlX6);
        }
        return (currentPnlRunId, run.completed, run.cumulativePnlX6);
    }

    function _calculateAssetPnlCapped(uint32 assetId, uint256 currentPrice1e6) internal view returns (int256) {
        Exposure memory e = exposures[assetId];
        Asset memory a = assets[assetId];
        if (e.longLots == 0 && e.shortLots == 0) return 0;
        int256 longPnl = 0;
        if (e.longLots > 0) {
            uint256 currentVal = (currentPrice1e6 * uint256(uint256(int256(e.longLots))) * uint256(a.numerator)) / uint256(a.denominator);
            uint256 entryVal = uint256(e.longValueSum);
            longPnl = int256(currentVal) - int256(entryVal);
            if (longPnl > 0) { if (uint256(longPnl) > uint256(e.longMaxProfit)) longPnl = int256(uint256(e.longMaxProfit)); } 
            else { if (uint256(-longPnl) > uint256(e.longMaxLoss)) longPnl = -int256(uint256(e.longMaxLoss)); }
        }
        int256 shortPnl = 0;
        if (e.shortLots > 0) {
            uint256 currentVal = (currentPrice1e6 * uint256(uint256(int256(e.shortLots))) * uint256(a.numerator)) / uint256(a.denominator);
            uint256 entryVal = uint256(e.shortValueSum);
            shortPnl = int256(entryVal) - int256(currentVal);
            if (shortPnl > 0) { if (uint256(shortPnl) > uint256(e.shortMaxProfit)) shortPnl = int256(uint256(e.shortMaxProfit)); } 
            else { if (uint256(-shortPnl) > uint256(e.shortMaxLoss)) shortPnl = -int256(uint256(e.shortMaxLoss)); }
        }
        return -(longPnl + shortPnl);
    }
    
    function getAirdropStats(uint32 seasonId, address trader) external view returns (uint256, uint256, uint256, uint256) {
        return (seasonTraderVolume[seasonId][trader], seasonTraderWinPnL[seasonId][trader], seasonTotalVolume[seasonId], seasonTotalWinPnL[seasonId]);
    }
}
