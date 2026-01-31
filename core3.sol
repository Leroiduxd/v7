// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
    BROKEX CORE V22 (LIMIT & STOP ORDERS)
    - Logic: Full V21 Base (Airdrop, Paymaster, Oracle Batch).
    - Feature: Added 'isLimit' flag to Orders.
    - Execution: 
        * Limit: Buy Low / Sell High (Reversal)
        * Stop: Buy High / Sell Low (Breakout)
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
    // ERRORS (Space Saving)
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

    struct Trade {
        address trader;
        uint32 assetId;
        bool isLong;
        bool isLimit; // ✅ NOUVEAU CHAMP (True=Limit, False=Stop)
        uint8 leverage;
        uint48 openPrice;      
        uint8 state; 
        uint32 openTimestamp;
        uint128 fundingIndex;
        uint48 closePrice;     
        int32 lotSize;
        uint48 stopLoss;
        uint48 takeProfit;
        uint64 lpLockedCapital;
        uint64 marginUsdc;
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

    mapping(uint256 => Trade) public trades;
    mapping(uint32 => Asset) public assets;
    mapping(uint32 => Exposure) public exposures;
    mapping(uint32 => FundingState) public fundingStates;
    
    uint64 public currentPnlRunId;
    mapping(uint64 => PnlRun) public pnlRuns;
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
        // Sécurité : On ne peut définir le paymaster que s'il n'est pas encore défini (adresse 0)
        require(paymaster == address(0), "PAYMASTER_ALREADY_SET");
        
        // Sécurité : On empêche de mettre une adresse vide
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

    function getSeasonGlobalStats(uint32 seasonId) external view returns (uint256 totalVolume, uint256 totalWinPnL) {
        return (seasonTotalVolume[seasonId], seasonTotalWinPnL[seasonId]);
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
        assets[assetId] = Asset({assetId: assetId, numerator: numerator, denominator: denominator, baseFundingRate: baseFundingRate, spread: spread, commission: commission, weekendFunding: weekendFunding, securityMultiplier: securityMultiplier, maxPhysicalMove: maxPhysicalMove, maxLeverage: maxLeverage, maxLongLots: 1000000, maxShortLots: 1000000, maxOracleDelay: 60, allowOpen: true, listed: true});
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
        Exposure storage e = exposures[assetId];
        if (e.longLots != 0 || e.shortLots != 0) revert ExposureNotZero();
        delete assets[assetId];
    }

    function updateLotSize(uint32 assetId, uint32 newNum, uint32 newDen) external onlyOwner {
        Exposure storage e = exposures[assetId];
        if (e.longLots != 0 || e.shortLots != 0) revert ExposureNotZero();
        assets[assetId].numerator = newNum;
        assets[assetId].denominator = newDen;
    }

    // ----------------------------------------------------------------
    // 5. EXPOSURE LOGIC
    // ----------------------------------------------------------------

    function _updateExposure(uint32 assetId, int32 lotSize, uint48 price, bool isLong, bool increase) internal {
        Exposure storage e = exposures[assetId];
        uint256 rawVal = _getNotionalValue(assetId, uint256(price), uint32(lotSize));
        uint128 value = uint128(rawVal);

        if (isLong) {
            if (increase) {
                if (uint256(uint256(int256(e.longLots))) + uint256(uint32(lotSize)) > uint256(assets[assetId].maxLongLots)) revert MaxLongLimit();
                e.longLots += lotSize;
                e.longValueSum += value;
            } else {
                e.longLots -= lotSize;
                e.longValueSum = _safeSub(e.longValueSum, value);
            }
        } else {
            if (increase) {
                if (uint256(uint256(int256(e.shortLots))) + uint256(uint32(lotSize)) > uint256(assets[assetId].maxShortLots)) revert MaxShortLimit();
                e.shortLots += lotSize;
                e.shortValueSum += value;
            } else {
                e.shortLots -= lotSize;
                e.shortValueSum = _safeSub(e.shortValueSum, value);
            }
        }
    }

    function _updateExposureLimits(uint32 assetId, uint64 lpLocked, uint64 margin, bool isLong, bool increase) internal {
        Exposure storage e = exposures[assetId];
        uint128 locked = uint128(lpLocked);
        uint128 marg = uint128(margin);

        if (isLong) {
            if (increase) {
                e.longMaxProfit += locked;
                e.longMaxLoss += marg;
            } else {
                e.longMaxProfit = _safeSub(e.longMaxProfit, locked);
                e.longMaxLoss = _safeSub(e.longMaxLoss, marg);
            }
        } else {
            if (increase) {
                e.shortMaxProfit += locked;
                e.shortMaxLoss += marg;
            } else {
                e.shortMaxProfit = _safeSub(e.shortMaxProfit, locked);
                e.shortMaxLoss = _safeSub(e.shortMaxLoss, marg);
            }
        }
    }

    // ----------------------------------------------------------------
    // 6. CALCULS
    // ----------------------------------------------------------------

    function _safeSub(uint128 a, uint128 b) internal pure returns (uint128) {
        return (b > a) ? 0 : a - b;
    }

    function _getNotionalValue(uint32 assetId, uint256 price, uint32 lotSize) internal view returns (uint256) {
        Asset memory a = assets[assetId];
        return (price * uint256(lotSize) * uint256(a.numerator)) / uint256(a.denominator);
    }

    function _isRoundLeverage(uint8 lev) internal pure returns (bool) {
        return (lev == 1 || lev == 2 || lev == 3 || lev == 5 || lev == 10 || lev == 20 || lev == 25 || lev == 50 || lev == 100);
    }

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
        Asset memory a = assets[assetId];
        Exposure memory e = exposures[assetId];
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

    function calculateWeekendFunding(uint256 tradeId) public view returns (uint256) {
        Trade memory t = trades[tradeId];
        Asset memory a = assets[t.assetId];
        if (a.weekendFunding == 0) return 0;

        uint256 closeTs = block.timestamp;
        if (closeTs <= t.openTimestamp) return 0;

        uint256 offset = 259200; 
        uint256 secondsPerWeek = 604800;
        uint256 openWeek = (uint256(t.openTimestamp) + offset) / secondsPerWeek;
        uint256 currentWeek = (closeTs + offset) / secondsPerWeek;

        if (currentWeek <= openWeek) return 0;
        uint256 weekendsCrossed = currentWeek - openWeek;
        
        return weekendsCrossed * uint256(a.weekendFunding) * uint256(uint32(t.lotSize));
    }

    function calculateMargin6(uint32 assetId, uint256 entryPrice, uint32 lotSize, uint8 leverage) public view returns (uint256) {
        uint256 notional = _getNotionalValue(assetId, entryPrice, lotSize);
        return notional / uint256(leverage);
    }

    function calculateLockedCapital(uint32 assetId, uint256 entryPrice, uint32 lotSize, uint8 leverage) public view returns (uint256) {
        Asset memory a = assets[assetId];
        uint256 notional = _getNotionalValue(assetId, entryPrice, lotSize);
        uint256 margin = notional / uint256(leverage);
        
        uint256 maxProfitLev = (margin * uint256(a.securityMultiplier)) / 100;
        uint256 physMoveVal = (entryPrice * uint256(a.maxPhysicalMove)) / 100;
        uint256 physProfit = _getNotionalValue(assetId, physMoveVal, lotSize);
        return (maxProfitLev < physProfit) ? maxProfitLev : physProfit;
    }

    function calculateLiquidationPrice(uint256 tradeId) public view returns (uint256) {
        Trade memory t = trades[tradeId];
        Asset memory a = assets[t.assetId];
        FundingState memory f = fundingStates[t.assetId];

        uint256 openPrice = uint256(t.openPrice);
        uint256 margin = _getNotionalValue(t.assetId, openPrice, uint32(t.lotSize)) / uint256(t.leverage);
        uint256 liquidationLoss = (margin * 90) / 100; 

        uint256 spread = calculateSpread(t.assetId, !t.isLong, false, uint32(t.lotSize));
        uint256 spreadCost = _getNotionalValue(t.assetId, spread, uint32(t.lotSize));
        
        uint256 currentIdx = t.isLong ? f.longFundingIndex : f.shortFundingIndex;
        uint256 fundingCost = (uint256(currentIdx) - uint256(t.fundingIndex)) * uint256(uint32(t.lotSize)) * uint256(a.numerator) / uint256(a.denominator);
        uint256 weekendCost = calculateWeekendFunding(tradeId) * uint256(a.numerator) / uint256(a.denominator);

        uint256 totalLossAllowable = liquidationLoss + spreadCost + fundingCost + weekendCost;
        uint256 deltaPrice = (totalLossAllowable * uint256(a.denominator)) / (uint256(uint32(t.lotSize)) * uint256(a.numerator));

        if (t.isLong) {
            return (deltaPrice >= openPrice) ? 0 : openPrice - deltaPrice;
        } else {
            return openPrice + deltaPrice;
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
        FundingState storage f = fundingStates[assetId];
        if (block.timestamp < f.lastUpdate + 1 hours) return;

        Exposure memory e = exposures[assetId];
        Asset memory a = assets[assetId];

        uint256 L = uint256(int256(e.longLots) > 0 ? uint256(int256(e.longLots)) : 0);
        uint256 S = uint256(int256(e.shortLots) > 0 ? uint256(int256(e.shortLots)) : 0);
        uint256 baseFunding = uint256(a.baseFundingRate);

        (uint256 longRate, uint256 shortRate) = _computeFundingRateQuadratic(L, S, baseFunding);

        f.longFundingIndex += uint128(longRate);
        f.shortFundingIndex += uint128(shortRate);
        f.lastUpdate = uint64(block.timestamp);
    }

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


    // ----------------------------------------------------------------
    // 10. INTERNAL LOGIC (SHARED)
    // ----------------------------------------------------------------

    function openMarketPosition(address trader, uint32 assetId, bool isLong, uint8 leverage, int32 lotSize, uint48 stopLoss, uint48 takeProfit, bytes calldata oracleProof) external onlyPaymaster {
        if (!assets[assetId].listed) revert AssetDeleted();
        if (!assets[assetId].allowOpen) revert CloseOnlyMode();
        if (lotSize <= 0) revert BadSize();
        if (!_isRoundLeverage(leverage)) revert BadLev();

        uint256 price1e6 = _getVerifiedPrice(oracleProof, assetId);
        uint256 spread = calculateSpread(assetId, isLong, true, uint32(lotSize));
        uint256 entryPrice = isLong ? price1e6 + spread : price1e6 - spread;

        (bool stopsOk, string memory reason) = validateStops(entryPrice, isLong, stopLoss, takeProfit);
        if(!stopsOk) revert(reason);

        uint256 margin6 = calculateMargin6(assetId, entryPrice, uint32(lotSize), leverage);
        uint256 lpLocked6 = calculateLockedCapital(assetId, entryPrice, uint32(lotSize), leverage);
        uint256 commission6 = (margin6 * assets[assetId].commission) / 10000;

        uint256 tradeId = ++nextTradeID;
        Trade storage t = trades[tradeId];
        t.trader = trader; t.assetId = assetId; t.isLong = isLong; t.isLimit = false; // Market trade n'est pas limit
        t.leverage = leverage; t.openPrice = uint48(entryPrice); t.state = 1; t.openTimestamp = uint32(block.timestamp);
        FundingState memory fs = fundingStates[assetId];
        t.fundingIndex = isLong ? fs.longFundingIndex : fs.shortFundingIndex;
        t.lotSize = lotSize; t.stopLoss = stopLoss; t.takeProfit = takeProfit;
        t.lpLockedCapital = uint64(lpLocked6); t.marginUsdc = uint64(margin6);

        _updateExposure(assetId, lotSize, uint48(entryPrice), isLong, true);
        _updateExposureLimits(assetId, uint64(lpLocked6), uint64(margin6), isLong, true);
        
        _updateAirdropVolume(trader, uint256(margin6));
        brokexVault.createPosition(tradeId, trader, margin6, commission6, lpLocked6);
        emit TradeEvent(tradeId, 1);
    }

    // ✅ MODIFIÉ: isLimit ajouté
    function placeOrder(address trader, uint32 assetId, bool isLong, bool isLimit, uint8 leverage, int32 lotSize, uint48 targetPrice, uint48 stopLoss, uint48 takeProfit) external onlyPaymaster {
        if (!assets[assetId].listed) revert AssetDeleted();
        if (!assets[assetId].allowOpen) revert CloseOnlyMode();
        (bool stopsOk, string memory reason) = validateStops(uint256(targetPrice), isLong, stopLoss, takeProfit);
        if(!stopsOk) revert(reason);

        uint256 margin6 = calculateMargin6(assetId, uint256(targetPrice), uint32(lotSize), leverage);
        uint256 lpLocked6 = calculateLockedCapital(assetId, uint256(targetPrice), uint32(lotSize), leverage);
        uint256 commission6 = (margin6 * assets[assetId].commission) / 10000;

        uint256 tradeId = ++nextTradeID;
        // ✅ On stocke isLimit
        trades[tradeId] = Trade({trader: trader, assetId: assetId, isLong: isLong, isLimit: isLimit, leverage: leverage, openPrice: targetPrice, state: 0, openTimestamp: uint32(block.timestamp), fundingIndex: 0, closePrice: 0, lotSize: lotSize, stopLoss: stopLoss, takeProfit: takeProfit, lpLockedCapital: uint64(lpLocked6), marginUsdc: uint64(margin6)});
        brokexVault.createOrder(tradeId, trader, margin6, commission6, lpLocked6);
        emit TradeEvent(tradeId, 0);
    }

    // ✅ MODIFIÉ: Logique Limit vs Stop
    function executeOrder(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        if (t.state != 0) revert NotPending();
        if (!assets[t.assetId].allowOpen) revert CloseOnlyMode();

        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        
        bool executable;
        if (t.isLimit) {
            // Limit: Acheter plus bas ou Vendre plus haut
            executable = t.isLong ? price1e6 <= uint256(t.openPrice) : price1e6 >= uint256(t.openPrice);
        } else {
            // Stop: Acheter sur breakout (plus haut) ou Vendre sur breakdown (plus bas)
            executable = t.isLong ? price1e6 >= uint256(t.openPrice) : price1e6 <= uint256(t.openPrice);
        }
        
        if (!executable) revert PriceBad();

        uint256 spread = calculateSpread(t.assetId, t.isLong, true, uint32(t.lotSize));
        // Execution price: le prix actuel + spread
        uint256 execPrice = t.isLong ? price1e6 + spread : price1e6 - spread;

        t.openPrice = uint48(execPrice); t.state = 1; t.openTimestamp = uint32(block.timestamp);
        FundingState memory fs = fundingStates[t.assetId];
        t.fundingIndex = t.isLong ? fs.longFundingIndex : fs.shortFundingIndex;

        _updateExposure(t.assetId, t.lotSize, uint48(execPrice), t.isLong, true);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, true);
        _updateAirdropVolume(t.trader, uint256(t.marginUsdc));

        brokexVault.executeOrder(tradeId);
        emit TradeEvent(tradeId, 1);
    }

    function closePositionMarket(address trader, uint256 tradeId, bytes calldata oracleProof) external onlyPaymaster {
        Trade storage t = trades[tradeId];
        // Sécurité : Seul le propriétaire peut fermer manuellement
        if (t.trader != trader) revert NotYourTrade();

        if (t.state != 1) revert NotOpen();
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        _finalizeClose(t, price1e6, tradeId);
    }

    function liquidatePosition(uint256 tradeId, bytes calldata oracleProof) external {
        Trade storage t = trades[tradeId];
        if (t.state != 1) revert NotOpen();
        uint256 price1e6 = _getVerifiedPrice(oracleProof, t.assetId);
        uint256 liqPrice = calculateLiquidationPrice(tradeId);
        bool isLiq = t.isLong ? price1e6 <= liqPrice : price1e6 >= liqPrice;
        if (!isLiq) revert NotLiq();

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

    function updateSLTP(address trader, uint256 tradeId, uint48 newSL, uint48 newTP) external onlyPaymaster {
        Trade storage t = trades[tradeId];
        // Sécurité : Seul le propriétaire peut modifier
        if (t.trader != trader) revert NotYourTrade();
        
        if (t.state > 1) revert Closed();
        (bool ok, string memory reason) = validateStops(uint256(t.openPrice), t.isLong, newSL, newTP);
        if (!ok) revert(reason);
        t.stopLoss = newSL; t.takeProfit = newTP;
        emit TradeEvent(tradeId, 5);
    }

    function cancelOrder(address trader, uint256 tradeId) external onlyPaymaster {
        Trade storage t = trades[tradeId];
        // Sécurité : Seul le propriétaire peut annuler
        if (t.trader != trader) revert NotYourTrade();

        if (t.state != 0) revert NotPending();
        t.state = 3;
        brokexVault.cancelOrder(tradeId);
        emit TradeEvent(tradeId, 3);
    }

    function _finalizeClose(Trade storage t, uint256 price1e6, uint256 tradeId) internal {
        int256 netPnl = _calculateNetPnl(t, price1e6, tradeId);
        _updateExposure(t.assetId, t.lotSize, t.openPrice, t.isLong, false);
        _updateExposureLimits(t.assetId, t.lpLockedCapital, t.marginUsdc, t.isLong, false);
        t.state = 2; t.closePrice = uint48(price1e6);
        _updateAirdropPnL(t.trader, netPnl);
        brokexVault.closeTrade(tradeId, netPnl);
        emit TradeEvent(tradeId, 2);
    }

    function _calculateNetPnl(Trade storage t, uint256 price1e6, uint256 tradeId) internal view returns (int256) {
        uint256 spread = calculateSpread(t.assetId, !t.isLong, false, uint32(t.lotSize));
        uint256 exitPrice;
        if (t.isLong) {
            if (spread > price1e6) exitPrice = 0; else exitPrice = price1e6 - spread;
        } else {
            exitPrice = price1e6 + spread;
        }

        int256 delta = t.isLong ? int256(exitPrice) - int256(uint256(t.openPrice)) : int256(uint256(t.openPrice)) - int256(exitPrice);
        Asset memory a = assets[t.assetId];
        int256 lotSize256 = int256(uint256(uint32(t.lotSize)));
        int256 rawPnl = (delta * lotSize256 * int256(uint256(a.numerator))) / int256(uint256(a.denominator));
        
        FundingState memory fs = fundingStates[t.assetId];
        uint256 currentIdx = t.isLong ? fs.longFundingIndex : fs.shortFundingIndex;
        uint256 fundingPaid = (uint256(currentIdx) - uint256(t.fundingIndex)) * uint256(uint32(t.lotSize)) * uint256(a.numerator) / uint256(a.denominator);
        uint256 weekendFees = calculateWeekendFunding(tradeId) * uint256(a.numerator) / uint256(a.denominator);

        return (rawPnl * 1e12) - int256(fundingPaid + weekendFees) * 1e12;
    }

    // ----------------------------------------------------------------
    // 11. UNREALIZED PNL (BATCH)
    // ----------------------------------------------------------------

    function updateUnrealizedPnl(bytes calldata singleProof, uint32[] calldata assetIds) external returns (uint64 runId, bool runCompleted, int256 currentPnl) {
        ISupraOraclePull.PriceInfo memory info = oracle.verifyOracleProofV2(singleProof);
        PnlRun storage run;
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
            int256 assetPnl = _calculateAssetPnlCapped(assetId, price1e6);
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

    function _calculateAssetPnlCapped(uint32 assetId, uint256 currentPrice1e6) internal view returns (int256 pnlX6) {
        Exposure memory e = exposures[assetId];
        Asset memory a = assets[assetId];
        if (e.longLots == 0 && e.shortLots == 0) return 0;

        int256 longPnl = 0;
        if (e.longLots > 0) {
            uint256 currentVal = (currentPrice1e6 * uint256(uint256(int256(e.longLots))) * uint256(a.numerator)) / uint256(a.denominator);
            uint256 entryVal = uint256(e.longValueSum);
            longPnl = int256(currentVal) - int256(entryVal);
            if (longPnl > 0) {
                if (uint256(longPnl) > uint256(e.longMaxProfit)) longPnl = int256(uint256(e.longMaxProfit));
            } else {
                if (uint256(-longPnl) > uint256(e.longMaxLoss)) longPnl = -int256(uint256(e.longMaxLoss));
            }
        }

        int256 shortPnl = 0;
        if (e.shortLots > 0) {
            uint256 currentVal = (currentPrice1e6 * uint256(uint256(int256(e.shortLots))) * uint256(a.numerator)) / uint256(a.denominator);
            uint256 entryVal = uint256(e.shortValueSum);
            shortPnl = int256(entryVal) - int256(currentVal);
            if (shortPnl > 0) {
                if (uint256(shortPnl) > uint256(e.shortMaxProfit)) shortPnl = int256(uint256(e.shortMaxProfit));
            } else {
                if (uint256(-shortPnl) > uint256(e.shortMaxLoss)) shortPnl = -int256(uint256(e.shortMaxLoss));
            }
        }
        return -(longPnl + shortPnl);
    }

    // ----------------------------------------------------------------
    // 12. VIEWS UTILS
    // ----------------------------------------------------------------

    function getExposureAndAveragePrices(uint32 assetId) public view returns (uint32 longLots, uint32 shortLots, uint256 avgLongPrice, uint256 avgShortPrice) {
        Exposure memory e = exposures[assetId];
        longLots = uint32(e.longLots);
        shortLots = uint32(e.shortLots);
        if (e.longLots > 0) avgLongPrice = uint256(e.longValueSum) / uint256(uint32(e.longLots));
        if (e.shortLots > 0) avgShortPrice = uint256(e.shortValueSum) / uint256(uint32(e.shortLots));
    }

    function getAssetRiskLimits(uint32 assetId) external view returns (uint32 maxLong, uint32 maxShort, uint32 oracleDelay, bool isOpenAllowed) {
        Asset memory a = assets[assetId];
        return (a.maxLongLots, a.maxShortLots, a.maxOracleDelay, a.allowOpen);
    }

    function getLastFinishedPnlRun() external view returns (int256 pnl, uint64 timestamp) {
        if (currentPnlRunId > 0) {
            PnlRun memory run = pnlRuns[currentPnlRunId];
            if (run.completed) return (run.cumulativePnlX6, run.endTimestamp);
            else if (currentPnlRunId > 1) {
                PnlRun memory prev = pnlRuns[currentPnlRunId - 1];
                if (prev.completed) return (prev.cumulativePnlX6, prev.endTimestamp);
            }
        }
        return (0, 0);
    }

    function getAirdropStats(uint32 seasonId, address trader) external view returns (uint256 myVolume, uint256 myWinPnL, uint256 totalSeasonVolume, uint256 totalSeasonWinPnL) {
        return (
            seasonTraderVolume[seasonId][trader],
            seasonTraderWinPnL[seasonId][trader],
            seasonTotalVolume[seasonId],
            seasonTotalWinPnL[seasonId]
        );
    }

    // ----------------------------------------------------------------
    // 13. BATCH VIEW HELPERS (Optimized Polling)
    // ----------------------------------------------------------------

    /**
     * @notice Récupère l'état d'une liste spécifique d'IDs
     * @param tradeIds Tableau des IDs à vérifier (ex: [150, 155, 192])
     * @return states Tableau des états correspondants (ex: [1, 1, 2])
     */
    function getTradeStatesFromList(uint256[] calldata tradeIds) external view returns (uint8[] memory states) {
        uint256 len = tradeIds.length;
        // Limite de sécurité pour le RPC
        if (len > 1000) revert("List too long");

        states = new uint8[](len);
        
        for (uint256 i = 0; i < len; i++) {
            states[i] = trades[tradeIds[i]].state;
        }
    }

    /**
     * @notice Récupère les SL et TP pour une liste spécifique d'IDs
     * @param tradeIds Tableau des IDs à vérifier (ex: [150, 155, 192])
     * @return stopLosses Tableau des prix Stop Loss correspondants
     * @return takeProfits Tableau des prix Take Profit correspondants
     */
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

    // ----------------------------------------------------------------
    // 14. ADD MARGIN FUNCTIONS
    // ----------------------------------------------------------------

   

    /**
     * @dev Logique interne pour l'ajout de marge
     */
    function addMargin(address trader, uint256 tradeId, uint64 amount6) external onlyPaymaster {
        Trade storage t = trades[tradeId];
        
        // 1. Sécurité : Vérifier le propriétaire
        if (t.trader != trader) revert NotYourTrade();
        
        // 2. Sécurité : Vérifier l'état (0=Pending, 1=Open uniquement)
        if (t.state > 1) revert Closed();
        
        // 3. Mise à jour du Struct Trade
        t.marginUsdc += amount6;

        // 4. Mise à jour de l'Exposition (Impact Risque)
        // Le trader ajoute du cash -> Il peut perdre plus -> Le protocole (LP) peut gagner plus.
        // Donc on AUGMENTE la MaxLoss du côté du protocole.
        // On ne change pas le MaxProfit (lpLockedCapital reste le même) ni les lots.
        _updateExposureLimits(t.assetId, 0, uint64(amount6), t.isLong, true);

        // 5. Appel au Vault pour sécuriser les fonds (Transfert Free -> Locked)
        brokexVault.addMarginToTrade(tradeId, uint256(amount6));

        // 6. Émission de l'Event (Code 6 = Add Margin)
        emit TradeEvent(tradeId, 6);
    }
}
