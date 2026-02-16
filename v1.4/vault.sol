// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    BrokexVault V4.3 (Provisioning / Escrow Model)
    
    UPDATES from V2.1:
    - Removed 1% Trader Profit Fee.
    - Added 'ownerFeeReserve' to sequester fees during the epoch.
    - Added 'provisionCheckBps' (15%) taken on every LP win.
    - Added Settlement logic in 'rollEpoch' to pay Owner max 20% of Net Realized PnL.
*/

// ==========================================
// INTERFACES
// ==========================================

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IBrokexCore {
    function getLastFinishedPnlRun() external view returns (int256 pnl, uint64 timestamp);
}

// ==========================================
// CONTRACT
// ==========================================

contract BrokexVault {
    // -----------------------------
    // Constants / units
    // -----------------------------
    uint8 public constant STABLE_DECIMALS = 6;
    uint256 private constant WAD = 1e18;
    uint256 private constant USDC_TO_WAD = 1e12;

    // Fees (basis points)
    uint256 public constant COMMISSION_OWNER_BPS = 3000; // 30% of opening fee
    uint256 public constant COMMISSION_BPS_DENOM = 10000;

    // ✅ NEW: Target Performance Fee (20%) of Net Realized Profit
    uint256 public constant TARGET_PERF_FEE_BPS = 2000; 

    // Dust threshold: 5 USD
    uint256 public constant DUST_CAPITAL6 = 5_000_000; 

    // -----------------------------
    // Roles & Tokens
    // -----------------------------
    address public owner;
    address public core;       
    bool public coreSet;       
    IERC20 public usdc;        

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyCore() {
        require(msg.sender == core, "Not core");
        _;
    }

    // -----------------------------
    // Trader balances (Accounting)
    // -----------------------------
    mapping(address => uint256) public freeBalance;    
    mapping(address => uint256) public lockedBalance;  

    // -----------------------------
    // LP capital accounting
    // -----------------------------
    uint256 public lpFreeCapital;      
    uint256 public lpLockedCapital;    

    // ✅ NEW: Escrow & Provisioning State
    int256 public currentEpochRealizedPnl; // Tracks Net PnL of LPs
    uint256 public ownerFeeReserve;        // The Escrow Pot
    uint256 public provisionCheckBps;      // Default 15% (1500)

    // -----------------------------
    // Trades
    // -----------------------------
    enum TradeState {
        Pending,
        Open,
        Closed,
        Cancelled
    }

    struct Trade {
        uint256 id;
        address owner;        
        uint256 margin;       
        uint256 commission;   
        uint256 lpLock;       
        TradeState state;
    }

    mapping(uint256 => Trade) public trades;

    // -----------------------------
    // LP Epoch system
    // -----------------------------
    uint256 public constant EPOCH_DURATION = 86400 seconds;
    uint256 public currentEpoch;
    uint256 public epochStartTimestamp;

    mapping(uint256 => uint256) public lpTokenPrice;
    mapping(uint256 => int256)  public epochEquitySnapshot18;
    uint256 public totalShares;

    mapping(uint256 => uint256) public totalPendingDeposits;
    mapping(address => mapping(uint256 => uint256)) public pendingDepositOf;
    mapping(address => uint256[]) public epochsWithDeposits;
    mapping(address => mapping(uint256 => bool)) public epochListed;

    // -----------------------------
    // LP Withdraw system
    // -----------------------------
    struct WithdrawBucket {
        uint256 totalSharesInitial18;
        uint256 sharesRemaining18;
        uint256 totalUsdAllocated6;
    }

    struct UserWithdraw {
        uint256 sharesRequested18;
        uint256 usdWithdrawn6;
    }

    mapping(uint256 => WithdrawBucket) public withdrawBuckets;
    mapping(uint256 => mapping(address => UserWithdraw)) public userWithdraws;
    mapping(address => uint256[]) public withdrawEpochsOf;
    mapping(address => mapping(uint256 => bool)) public withdrawEpochListed;

    uint256 public oldestWithdrawEpoch;
    bool public hasWithdrawBuckets;

    struct PayoutTranche {
        uint256 sharesRemaining18;
        uint256 priceWad;
    }

    mapping(uint256 => PayoutTranche) public payoutByEpoch;
    uint256 public oldestPayoutEpoch;
    bool public hasPayoutTranches;

    uint256 public totalWithdrawSharesOutstanding18;
    uint256 public totalPaidSharesPendingAlloc18;

    // -----------------------------
    // Withdraw reserve guard
    // -----------------------------
    uint256 public withdrawSharesUnfunded18;
    uint256 public minLpFreeReserve6;

    // -----------------------------
    // Events
    // -----------------------------
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event CoreSet(address indexed core);

    event TraderDeposit(address indexed trader, uint256 amount6);
    event TraderWithdraw(address indexed trader, uint256 amount6);

    event OrderCreated(uint256 indexed tradeId, address indexed trader, uint256 margin6, uint256 commission6, uint256 lpLock6);
    event OrderExecuted(uint256 indexed tradeId);
    event OrderCancelled(uint256 indexed tradeId);

    event PositionCreated(uint256 indexed tradeId, address indexed trader, uint256 margin6, uint256 commission6, uint256 lpLock6);
    event TradeClosed(uint256 indexed tradeId, int256 pnl18, int256 actualPnl18);
    event TradeLiquidated(uint256 indexed tradeId, uint256 marginSeized6);

    event LpDepositRequested(address indexed lp, uint256 indexed epoch, uint256 newPending6, uint256 delta6);
    event LpDepositReduced(address indexed lp, uint256 indexed epoch, uint256 newPending6, uint256 delta6);

    event WithdrawRequested(address indexed lp, uint256 indexed requestEpoch, uint256 sharesAdded18, uint256 newUserShares18, uint256 newBucketTotalShares18);
    event WithdrawClaimed(address indexed lp, uint256 indexed requestEpoch, uint256 amount6);

    event PayoutCreated(uint256 indexed payEpoch, uint256 sharesPaid18, uint256 usdReserved6, uint256 priceWad);
    event PayoutAssignedToBucket(uint256 indexed payEpoch, uint256 indexed bucketEpoch, uint256 sharesAssigned18, uint256 usdAllocated6);

    event EpochRolled(uint256 indexed epochClosed, uint256 indexed epochOpened, uint256 priceWad, int256 equitySnapshot18, uint256 depositsAdded6, uint256 sharesMinted18);
    event DustSwept(uint256 capitalSwept6);
    
    // ✅ NEW EVENTS
    event PerformanceFeePaid(uint256 indexed epoch, uint256 netProfit6, uint256 feeTaken6);
    event ProvisionUpdated(uint256 newBps);

    // -----------------------------
    // Constructor & Settings
    // -----------------------------
    constructor(address _usdc) {
        require(_usdc != address(0), "Invalid USDC");
        owner = msg.sender;
        currentEpoch = 0;
        epochStartTimestamp = block.timestamp;
        usdc = IERC20(_usdc);
        provisionCheckBps = 1500; // ✅ Default 15% provisioning
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "owner=0");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setCore(address _core) external onlyOwner {
        require(!coreSet, "Core already set");
        require(_core != address(0), "Invalid core");
        core = _core;
        coreSet = true;
        emit CoreSet(_core);
    }

    // ✅ NEW: Allow owner to adjust provisioning (Max 20%)
    function setProvisionCheck(uint256 _bps) external onlyOwner {
        require(_bps <= 2000, "Max 20%");
        provisionCheckBps = _bps;
        emit ProvisionUpdated(_bps);
    }

    // -----------------------------
    // Helpers
    // -----------------------------
    function _toWadFrom6(uint256 amount6) internal pure returns (uint256) {
        return amount6 * USDC_TO_WAD;
    }

    function _to6FromWad(uint256 amount18) internal pure returns (uint256) {
        return amount18 / USDC_TO_WAD;
    }

    function _mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0, "div0");
                return prod0 / denominator;
            }
            require(denominator > prod1, "overflow");
            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
            return result;
        }
    }

    // -----------------------------
    // Dust handling
    // -----------------------------
    function _totalLpCapital6() internal view returns (uint256) {
        return lpFreeCapital + lpLockedCapital;
    }

    function sweepDust() public {
        uint256 cap6 = _totalLpCapital6();
        if (cap6 == 0 && ownerFeeReserve == 0) return;
        
        // If funds are extremely low, we assume protocol reset.
        if (cap6 < DUST_CAPITAL6) {
            uint256 totalSweep = cap6 + ownerFeeReserve;
            
            freeBalance[owner] += totalSweep;
            lpFreeCapital = 0;
            lpLockedCapital = 0;
            ownerFeeReserve = 0;
            totalShares = 0;

            withdrawSharesUnfunded18 = 0;
            minLpFreeReserve6 = 0;
            currentEpochRealizedPnl = 0;

            emit DustSwept(totalSweep);
        }
    }

    // -----------------------------
    // Trader funds (Real USDC)
    // -----------------------------
    function traderDeposit(uint256 amount6) external {
        require(amount6 > 0, "amount=0");
        bool success = usdc.transferFrom(msg.sender, address(this), amount6);
        require(success, "Transfer failed");
        freeBalance[msg.sender] += amount6;
        emit TraderDeposit(msg.sender, amount6);
    }

    function traderWithdraw(uint256 amount6) external {
        require(amount6 > 0, "amount=0");
        require(freeBalance[msg.sender] >= amount6, "insufficient free");
        freeBalance[msg.sender] -= amount6;
        bool success = usdc.transfer(msg.sender, amount6);
        require(success, "Transfer failed");
        emit TraderWithdraw(msg.sender, amount6);
    }

    function _lockTrader(address trader, uint256 amount6) internal {
        require(freeBalance[trader] >= amount6, "insufficient free to lock");
        freeBalance[trader] -= amount6;
        lockedBalance[trader] += amount6;
    }

    function _unlockTrader(address trader, uint256 amount6) internal {
        require(lockedBalance[trader] >= amount6, "insufficient locked");
        lockedBalance[trader] -= amount6;
        freeBalance[trader] += amount6;
    }

    function _lpLock(uint256 amount6) internal {
        require(lpFreeCapital >= (minLpFreeReserve6 + amount6), "lpFree reserved for withdrawals");
        lpFreeCapital -= amount6;
        lpLockedCapital += amount6;
    }

    function _lpUnlock(uint256 amount6) internal {
        require(lpLockedCapital >= amount6, "lpLocked underflow");
        lpLockedCapital -= amount6;
        lpFreeCapital += amount6;
    }

    function _collectCommission(address trader, uint256 commission6) internal {
        require(lockedBalance[trader] >= commission6, "locked < commission");
        lockedBalance[trader] -= commission6;

        uint256 ownerCut6 = (commission6 * COMMISSION_OWNER_BPS) / COMMISSION_BPS_DENOM;
        uint256 lpCut6 = commission6 - ownerCut6;

        if (ownerCut6 > 0) freeBalance[owner] += ownerCut6;
        if (lpCut6 > 0) lpFreeCapital += lpCut6;
    }

    // ✅ MODIFIED: Implements Provisioning & Removes 1% Trader Fee
    function _unlockAndSettle(address trader, uint256 marginLocked6, int256 pnl18) internal {
        require(lockedBalance[trader] >= marginLocked6, "locked < margin");
        lockedBalance[trader] -= marginLocked6;

        if (pnl18 >= 0) {
            // Trader Wins -> LP Loses
            uint256 profit6 = _to6FromWad(uint256(pnl18));
            require(lpFreeCapital >= profit6, "lp insolvent (profit)");

            // Trader gets 100% of profit (No 1% fee anymore)
            freeBalance[trader] += (marginLocked6 + profit6);
            lpFreeCapital -= profit6;
        } else {
            // Trader Loses -> LP Wins
            uint256 loss6 = _to6FromWad(uint256(-pnl18));
            if (loss6 > marginLocked6) loss6 = marginLocked6;

            freeBalance[trader] += (marginLocked6 - loss6);
            
            // ✅ PROVISIONING LOGIC (The Escrow)
            // LP Net Profit here = loss6.
            // We skim 'provisionCheckBps' (e.g. 15%) immediately.
            uint256 provision6 = (loss6 * provisionCheckBps) / COMMISSION_BPS_DENOM;
            uint256 lpShare6 = loss6 - provision6;

            // Add provision to Escrow
            ownerFeeReserve += provision6;
            // Add remainder to LP Capital
            lpFreeCapital += lpShare6;
        }
    }

    // -----------------------------
    // Trades: Restricted to Core
    // -----------------------------
    function createOrder(uint256 tradeId, address trader, uint256 margin6, uint256 commission6, uint256 lpLock6) external onlyCore {
        require(trader != address(0), "trader=0");
        require(trades[tradeId].id == 0, "tradeId exists");
        require(margin6 > 0, "margin=0");
        require(lpLock6 > 0, "lpLock=0");

        _lockTrader(trader, margin6 + commission6);

        trades[tradeId] = Trade({id: tradeId, owner: trader, margin: margin6, commission: commission6, lpLock: lpLock6, state: TradeState.Pending});
        emit OrderCreated(tradeId, trader, margin6, commission6, lpLock6);
    }

    function executeOrder(uint256 tradeId) external onlyCore {
        Trade storage t = trades[tradeId];
        require(t.id != 0, "trade missing");
        require(t.state == TradeState.Pending, "not pending");

        _lpLock(t.lpLock);
        _collectCommission(t.owner, t.commission);

        t.state = TradeState.Open;
        emit OrderExecuted(tradeId);
    }

    function cancelOrder(uint256 tradeId) external onlyCore {
        Trade storage t = trades[tradeId];
        require(t.id != 0, "trade missing");
        require(t.state == TradeState.Pending, "not pending");

        t.state = TradeState.Cancelled;
        _unlockTrader(t.owner, t.margin + t.commission);
        emit OrderCancelled(tradeId);
    }

    function createPosition(uint256 tradeId, address trader, uint256 margin6, uint256 commission6, uint256 lpLock6) external onlyCore {
        require(trader != address(0), "trader=0");
        require(trades[tradeId].id == 0, "tradeId exists");
        require(margin6 > 0, "margin=0");
        require(lpLock6 > 0, "lpLock=0");

        _lockTrader(trader, margin6 + commission6);
        _lpLock(lpLock6);
        _collectCommission(trader, commission6);

        trades[tradeId] = Trade({id: tradeId, owner: trader, margin: margin6, commission: commission6, lpLock: lpLock6, state: TradeState.Open});
        emit PositionCreated(tradeId, trader, margin6, commission6, lpLock6);
    }

    // ✅ MODIFIED: Updates Realized PnL Tracker
   // ✅ MODIFIED: Support Partial Close & Capping on released amounts
    function closeTrade(
        uint256 tradeId, 
        int256 pnl18, 
        uint256 marginToRelease6, 
        uint256 lpLockToRelease6,
        bool isFullClose // Source de vérité venant du Core
    ) external onlyCore {
        Trade storage t = trades[tradeId];
        
        require(t.id != 0, "trade missing");
        // On autorise la fermeture (partielle ou totale) UNIQUEMENT si le trade est ouvert
        require(t.state == TradeState.Open, "not open");

        // Sécurités (Le Core doit envoyer des montants cohérents, mais le Vault vérifie)
        require(t.margin >= marginToRelease6, "release > trade margin");
        require(t.lpLock >= lpLockToRelease6, "release > trade lpLock");

        // --- 1. LOGIQUE DE PLAFONNEMENT (CAPPING) ---
        int256 actualPnl18 = pnl18;

        if (pnl18 > 0) {
            // GAIN : Capé au LP Capital qu'on libère maintenant
            uint256 maxProfit18 = _toWadFrom6(lpLockToRelease6);
            if (uint256(pnl18) > maxProfit18) {
                actualPnl18 = int256(maxProfit18);
            }
        } else if (pnl18 < 0) {
            // PERTE : Capée à la Marge qu'on libère maintenant
            uint256 maxLoss18 = _toWadFrom6(marginToRelease6);
            if (uint256(-pnl18) > maxLoss18) {
                actualPnl18 = -int256(maxLoss18);
            }
        }

        // --- 2. MISE À JOUR DU STRUCT (DÉCROISSANCE) ---
        t.margin -= marginToRelease6;
        t.lpLock -= lpLockToRelease6;
        // On ne touche pas à t.commission (déjà payée à l'ouverture)

        // --- 3. GESTION DE L'ÉTAT (SOURCE: CORE) ---
        if (isFullClose) {
            t.state = TradeState.Closed;
        }

        // --- 4. MOUVEMENTS DE FONDS ---
        _lpUnlock(lpLockToRelease6);
        _unlockAndSettle(t.owner, marginToRelease6, actualPnl18);

        // --- 5. SUIVI PNL GLOBAL ---
        currentEpochRealizedPnl -= actualPnl18;

        emit TradeClosed(tradeId, pnl18, actualPnl18);
    }

    // ✅ MODIFIED: Updates Realized PnL Tracker
    function liquidate(uint256 tradeId) external onlyCore {
        Trade storage t = trades[tradeId];
        require(t.id != 0, "trade missing");
        require(t.state == TradeState.Open, "not open");

        _lpUnlock(t.lpLock);
        _unlockAndSettle(t.owner, t.margin, -int256(_toWadFrom6(t.margin)));

        // Liquidation = Trader loses 100% margin -> LP gains 100% margin
        currentEpochRealizedPnl += int256(_toWadFrom6(t.margin));

        t.state = TradeState.Closed;
        emit TradeLiquidated(tradeId, t.margin);
    }

    // -----------------------------
    // LP: deposit requests
    // -----------------------------
    function requestLpDeposit(uint256 amount6) external {
        require(amount6 > 0, "amount=0");
        bool success = usdc.transferFrom(msg.sender, address(this), amount6);
        require(success, "Transfer failed");

        uint256 e = currentEpoch;
        if (!epochListed[msg.sender][e]) {
            epochListed[msg.sender][e] = true;
            epochsWithDeposits[msg.sender].push(e);
        }
        pendingDepositOf[msg.sender][e] += amount6;
        totalPendingDeposits[e] += amount6;
        emit LpDepositRequested(msg.sender, e, pendingDepositOf[msg.sender][e], amount6);
    }

    function reduceLpDeposit(uint256 amount6) external {
        require(amount6 > 0, "amount=0");
        uint256 e = currentEpoch;
        uint256 cur = pendingDepositOf[msg.sender][e];
        require(cur >= amount6, "reduce > pending");

        pendingDepositOf[msg.sender][e] = cur - amount6;
        totalPendingDeposits[e] -= amount6;

        bool success = usdc.transfer(msg.sender, amount6);
        require(success, "Transfer failed");
        emit LpDepositReduced(msg.sender, e, pendingDepositOf[msg.sender][e], amount6);
    }

    // -----------------------------
    // LP: withdrawal request
    // -----------------------------
    function requestLpWithdrawFromEpochs(uint256[] calldata depositEpochs) external {
        uint256 reqEpoch = currentEpoch;
        if (!withdrawEpochListed[msg.sender][reqEpoch]) {
            withdrawEpochListed[msg.sender][reqEpoch] = true;
            withdrawEpochsOf[msg.sender].push(reqEpoch);
        }

        uint256 sharesToAdd18 = 0;
        for (uint256 i = 0; i < depositEpochs.length; i++) {
            uint256 e = depositEpochs[i];
            uint256 dep6 = pendingDepositOf[msg.sender][e];
            require(dep6 > 0, "empty deposit epoch");
            uint256 price = lpTokenPrice[e];
            require(price > 0, "epoch not closed");
            uint256 dep18 = _toWadFrom6(dep6);
            uint256 shares18 = (dep18 * WAD) / price;
            pendingDepositOf[msg.sender][e] = 0; 
            sharesToAdd18 += shares18;
        }
        require(sharesToAdd18 > 0, "shares=0");

        WithdrawBucket storage b = withdrawBuckets[reqEpoch];
        b.totalSharesInitial18 += sharesToAdd18;
        b.sharesRemaining18 += sharesToAdd18;

        UserWithdraw storage u = userWithdraws[reqEpoch][msg.sender];
        u.sharesRequested18 += sharesToAdd18;

        if (!hasWithdrawBuckets) {
            hasWithdrawBuckets = true;
            oldestWithdrawEpoch = reqEpoch;
        }
        totalWithdrawSharesOutstanding18 += sharesToAdd18;
        withdrawSharesUnfunded18 += sharesToAdd18;
        emit WithdrawRequested(msg.sender, reqEpoch, sharesToAdd18, u.sharesRequested18, b.totalSharesInitial18);
    }

    // -----------------------------
    // Epoch rollover
    // -----------------------------
    bool public firstRollDone;

    function rollEpoch() external {
        // 1. Sécurité : Le tout premier lancement (passage de 0 à 1) doit être fait par l'owner.
        if (currentEpoch == 0) {
            require(msg.sender == owner, "First roll: owner only");
        }

        // 2. Condition Temporelle : On ne vérifie la durée QUE si on n'est pas au démarrage (Epoch > 0).
        // Cela permet de lancer l'Epoch 1 immédiatement après le déploiement sans attendre 24h.
        if (currentEpoch > 0) {
            require(block.timestamp >= epochStartTimestamp + EPOCH_DURATION, "epoch not ended");
        }

        int256 unrealizedPnlTraders18 = 0;

        // 3. PnL Non Réalisé : On n'appelle le Core QUE si on n'est pas au démarrage.
        // À l'Epoch 0, il n'y a pas de trades ouverts, donc le PnL est forcé à 0.
        // Cela évite de devoir faire tourner un script de PnL à vide avant de lancer le protocole.
        if (currentEpoch > 0) {
            require(core != address(0), "Core not set");
            (int256 pnlCore, uint64 tsCore) = IBrokexCore(core).getLastFinishedPnlRun();
            
            // Sécurités de timestamp PnL classiques
            require(block.timestamp >= tsCore, "PnL in future?");
            require(block.timestamp - tsCore <= 120, "PnL stale (>2min)");
            
            // ✅ Conversion 1e6 (core) -> 1e18 (WAD) pour être cohérent avec le vault
            // 1e18 / 1e6 = 1e12
            unrealizedPnlTraders18 = pnlCore * int256(1e12);
        }

        // --- À PARTIR D'ICI, LE RESTE DE LA LOGIQUE EST IDENTIQUE ---

        if (_totalLpCapital6() > 0 && _totalLpCapital6() < DUST_CAPITAL6) {
            sweepDust();
            return;
        }

        // Settlement des Frais de Performance (Escrow)
        if (currentEpochRealizedPnl > 0) {
            uint256 netProfit6 = _to6FromWad(uint256(currentEpochRealizedPnl));
            uint256 entitledFee6 = (netProfit6 * TARGET_PERF_FEE_BPS) / COMMISSION_BPS_DENOM;

            if (ownerFeeReserve >= entitledFee6) {
                freeBalance[owner] += entitledFee6;
                lpFreeCapital += (ownerFeeReserve - entitledFee6);
                emit PerformanceFeePaid(currentEpoch, netProfit6, entitledFee6);
            } else {
                freeBalance[owner] += ownerFeeReserve;
                emit PerformanceFeePaid(currentEpoch, netProfit6, ownerFeeReserve);
            }
        } else {
            lpFreeCapital += ownerFeeReserve;
        }

        // Reset pour la prochaine époque
        ownerFeeReserve = 0;
        currentEpochRealizedPnl = 0;

        // Calcul de l'Equity et du Prix
        uint256 e = currentEpoch;
        int256 lpEquity18 = int256(_toWadFrom6(lpFreeCapital + lpLockedCapital));
        int256 equity18 = lpEquity18 - unrealizedPnlTraders18;
        uint256 priceWad;

        if (totalShares == 0) {
            // Au premier lancement, comme unrealizedPnlTraders18 est forcé à 0 plus haut,
            // et totalShares est 0, le prix sera fixé à 1.0 (WAD).
            require(unrealizedPnlTraders18 == 0, "unrealizedPnL must be 0 when totalShares=0");
            priceWad = WAD;
            require(equity18 >= 0, "equity<0");
        } else {
            require(equity18 > 0, "equity<=0");
            priceWad = (uint256(equity18) * WAD) / totalShares;
            require(priceWad > 0, "price=0");
        }

        lpTokenPrice[e] = priceWad;
        epochEquitySnapshot18[e] = equity18;

        // Traitement des Dépôts (Minting des Shares)
        uint256 deposits6 = totalPendingDeposits[e];
        uint256 sharesMinted18 = 0;
        if (deposits6 > 0) {
            uint256 deposits18 = _toWadFrom6(deposits6);
            sharesMinted18 = (deposits18 * WAD) / priceWad;
            totalShares += sharesMinted18;
            lpFreeCapital += deposits6;
        }

        // Traitement des Retraits (Réservation du Capital)
        uint256 unpaidMinusPaid18 = 0;
        if (totalWithdrawSharesOutstanding18 > totalPaidSharesPendingAlloc18) {
            unpaidMinusPaid18 = totalWithdrawSharesOutstanding18 - totalPaidSharesPendingAlloc18;
        }

        if (unpaidMinusPaid18 > 0 && lpFreeCapital > 0) {
            uint256 free18 = _toWadFrom6(lpFreeCapital);
            uint256 maxPayShares18 = (free18 * WAD) / priceWad;
            uint256 payShares18 = maxPayShares18;
            if (payShares18 > unpaidMinusPaid18) payShares18 = unpaidMinusPaid18;
            if (payShares18 > withdrawSharesUnfunded18) payShares18 = withdrawSharesUnfunded18;

            if (payShares18 > 0) {
                uint256 usdReserved6 = _to6FromWad(_mulDiv(payShares18, priceWad, WAD));
                require(lpFreeCapital >= usdReserved6, "lpFree < reserve");
                lpFreeCapital -= usdReserved6;
                require(totalShares >= payShares18, "totalShares underflow");
                totalShares -= payShares18;
                withdrawSharesUnfunded18 -= payShares18;

                PayoutTranche storage pt = payoutByEpoch[e];
                pt.sharesRemaining18 += payShares18;
                pt.priceWad = priceWad;
                totalPaidSharesPendingAlloc18 += payShares18;

                if (!hasPayoutTranches) {
                    hasPayoutTranches = true;
                    oldestPayoutEpoch = e;
                }
                emit PayoutCreated(e, payShares18, usdReserved6, priceWad);
            }
        }

        if (withdrawSharesUnfunded18 == 0) minLpFreeReserve6 = 0;
        else minLpFreeReserve6 = _to6FromWad(_mulDiv(withdrawSharesUnfunded18, priceWad, WAD));

        // Passage à l'époque suivante
        currentEpoch = e + 1;
        epochStartTimestamp = block.timestamp;
        
        // On marque que le premier roll est fait (utile pour la logique owner only du début)
        if (!firstRollDone) firstRollDone = true; 
        
        emit EpochRolled(e, currentEpoch, priceWad, equity18, deposits6, sharesMinted18);
    }


    function processWithdrawals(uint256 maxSteps) external {
        require(maxSteps > 0, "steps=0");
        if (!hasPayoutTranches || !hasWithdrawBuckets) return;

        uint256 steps = 0;
        uint256 payEpoch = oldestPayoutEpoch;
        uint256 bucketEpoch = oldestWithdrawEpoch;

        while (steps < maxSteps) {
            PayoutTranche storage pt = payoutByEpoch[payEpoch];
            WithdrawBucket storage b = withdrawBuckets[bucketEpoch];

            if (pt.sharesRemaining18 == 0) {
                payEpoch = payEpoch + 1;
                oldestPayoutEpoch = payEpoch;
                if (payEpoch >= currentEpoch) break;
                steps++;
                continue;
            }
            if (b.sharesRemaining18 == 0) {
                bucketEpoch = bucketEpoch + 1;
                oldestWithdrawEpoch = bucketEpoch;
                if (bucketEpoch >= currentEpoch) break;
                steps++;
                continue;
            }

            uint256 assign18 = pt.sharesRemaining18;
            if (assign18 > b.sharesRemaining18) assign18 = b.sharesRemaining18;

            uint256 usdAllocated6 = _to6FromWad(_mulDiv(assign18, pt.priceWad, WAD));
            b.totalUsdAllocated6 += usdAllocated6;
            b.sharesRemaining18 -= assign18;
            pt.sharesRemaining18 -= assign18;

            totalPaidSharesPendingAlloc18 -= assign18;
            totalWithdrawSharesOutstanding18 -= assign18;

            emit PayoutAssignedToBucket(payEpoch, bucketEpoch, assign18, usdAllocated6);
            steps++;
        }
    }

    // ✅ MODIFIED: Direct USDC transfer
    function claimWithdraw(uint256 requestEpoch) external {
        WithdrawBucket storage b = withdrawBuckets[requestEpoch];
        UserWithdraw storage u = userWithdraws[requestEpoch][msg.sender];

        require(u.sharesRequested18 > 0, "no request");
        require(b.totalSharesInitial18 > 0, "bucket empty");

        uint256 totalDue6 = _mulDiv(b.totalUsdAllocated6, u.sharesRequested18, b.totalSharesInitial18);
        require(totalDue6 > u.usdWithdrawn6, "nothing to claim");

        uint256 pay6 = totalDue6 - u.usdWithdrawn6;
        u.usdWithdrawn6 = totalDue6;
        
        // Direct Transfer
        bool success = usdc.transfer(msg.sender, pay6);
        require(success, "Transfer failed");

        emit WithdrawClaimed(msg.sender, requestEpoch, pay6);
    }

    // -----------------------------
    // Views
    // -----------------------------
    function getLpEpochsCount(address lp) external view returns (uint256) {
        return epochsWithDeposits[lp].length;
    }

    function getLpEpochAt(address lp, uint256 index) external view returns (uint256) {
        return epochsWithDeposits[lp][index];
    }

    function computeLpShares(address lp) external view returns (uint256 shares18, uint256 pendingCurrentEpoch6) {
        uint256[] memory list = epochsWithDeposits[lp];
        uint256 len = list.length;
        uint256 s = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 e = list[i];
            uint256 dep6 = pendingDepositOf[lp][e];
            if (dep6 == 0) continue;
            uint256 price = lpTokenPrice[e];
            if (price == 0) continue;
            uint256 dep18 = _toWadFrom6(dep6);
            s += (dep18 * WAD) / price;
        }
        shares18 = s;
        pendingCurrentEpoch6 = pendingDepositOf[lp][currentEpoch];
    }

    function getLpSharesForEpoch(address lp, uint256 e) external view returns (uint256 shares18) {
        uint256 dep6 = pendingDepositOf[lp][e];
        if (dep6 == 0) return 0;
        uint256 price = lpTokenPrice[e];
        if (price == 0) return 0;
        uint256 dep18 = _toWadFrom6(dep6);
        return (dep18 * WAD) / price;
    }

    function getWithdrawEpochsCount(address lp) external view returns (uint256) {
        return withdrawEpochsOf[lp].length;
    }

    function getWithdrawEpochAt(address lp, uint256 index) external view returns (uint256) {
        return withdrawEpochsOf[lp][index];
    }

    function getClaimableNow(address lp, uint256 requestEpoch) external view returns (uint256 claimable6) {
        WithdrawBucket storage b = withdrawBuckets[requestEpoch];
        UserWithdraw storage u = userWithdraws[requestEpoch][lp];
        if (u.sharesRequested18 == 0 || b.totalSharesInitial18 == 0) return 0;
        uint256 totalDue6 = _mulDiv(b.totalUsdAllocated6, u.sharesRequested18, b.totalSharesInitial18);
        if (totalDue6 <= u.usdWithdrawn6) return 0;
        return totalDue6 - u.usdWithdrawn6;
    }

    function getTraderTotalBalance(address trader) external view returns (uint256 total6) {
        return freeBalance[trader] + lockedBalance[trader];
    }

    function getLpTotalCapital6() external view returns (uint256 total6) {
        return lpFreeCapital + lpLockedCapital;
    }

    function getLpTotalCapital18() external view returns (uint256 total18) {
        return _toWadFrom6(lpFreeCapital + lpLockedCapital);
    }

    // -----------------------------
    // ✅ ADD MARGIN (New Function)
    // -----------------------------

    /**
     * @notice Ajoute de la marge à un trade existant depuis le freeBalance du trader
     * @dev Appelé uniquement par le Core pour garantir la synchro
     * @param tradeId L'ID du trade concerné
     * @param amount6 Le montant à ajouter en USDC (6 décimales)
     */
    function addMarginToTrade(uint256 tradeId, uint256 amount6) external onlyCore {
        require(amount6 > 0, "amount=0");
        
        Trade storage t = trades[tradeId];
        
        // Vérification du Owner (Sécurité interne)
        // Note: Le Core fait déjà cette vérif, mais c'est bien de l'avoir ici aussi.
        require(t.owner != address(0), "Trade not found");
        
        // Vérification de l'état (0=Pending, 1=Open)
        // On interdit l'ajout sur un trade fermé (2) ou annulé (3)
        require(t.state == TradeState.Pending || t.state == TradeState.Open, "Trade closed/cancelled");

        // Vérification Solde Trader
        require(freeBalance[t.owner] >= amount6, "Insufficient free balance");

        // Exécution du transfert interne
        freeBalance[t.owner] -= amount6;
        lockedBalance[t.owner] += amount6;
        
        // Mise à jour de la marge stockée dans le struct Trade du Vault
        t.margin += amount6;
    }
}
