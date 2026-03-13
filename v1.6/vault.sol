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
    // Minimal execution primitives
    // -----------------------------

    function lockTraderFunds(address trader, uint256 amount6) external onlyCore {
        require(trader != address(0), "trader=0");
        require(amount6 > 0, "amount=0");
        require(freeBalance[trader] >= amount6, "insufficient free");

        freeBalance[trader] -= amount6;
        lockedBalance[trader] += amount6;
    }

    function unlockTraderFunds(address trader, uint256 amount6) external onlyCore {
        require(trader != address(0), "trader=0");
        require(amount6 > 0, "amount=0");
        require(lockedBalance[trader] >= amount6, "insufficient locked");

        lockedBalance[trader] -= amount6;
        freeBalance[trader] += amount6;
    }

    function lockLpCapital(uint256 amount6) external onlyCore {
        require(amount6 > 0, "amount=0");
        require(lpFreeCapital >= (minLpFreeReserve6 + amount6), "lpFree reserved");

        lpFreeCapital -= amount6;
        lpLockedCapital += amount6;
    }

    function unlockLpCapital(uint256 amount6) external onlyCore {
        require(amount6 > 0, "amount=0");
        require(lpLockedCapital >= amount6, "lpLocked underflow");

        lpLockedCapital -= amount6;
        lpFreeCapital += amount6;
    }

    /**
    * @notice Prélève une commission déjà réservée dans le lockedBalance du trader.
    * @dev À utiliser :
    * - immédiatement après un market open
    * - à l'exécution d'un pending order
    * Répartition :
    * - 30% owner
    * - 70% LP free capital
    */
    function collectCommissionFromLocked(address trader, uint256 commission6) external onlyCore {
        require(trader != address(0), "trader=0");
        require(commission6 > 0, "commission=0");
        require(lockedBalance[trader] >= commission6, "locked < commission");

        lockedBalance[trader] -= commission6;

        uint256 ownerCut6 = (commission6 * COMMISSION_OWNER_BPS) / COMMISSION_BPS_DENOM;
        uint256 lpCut6 = commission6 - ownerCut6;

        freeBalance[owner] += ownerCut6;
        lpFreeCapital += lpCut6;
    }

    function settlePnl(address trader, int256 pnl6) external onlyCore {
        require(trader != address(0), "trader=0");

        if (pnl6 > 0) {
            uint256 profit = uint256(pnl6);

            require(lpFreeCapital >= profit, "lp insolvent");

            lpFreeCapital -= profit;
            freeBalance[trader] += profit;

            currentEpochRealizedPnl -= int256(profit);

        } else if (pnl6 < 0) {
            uint256 loss = uint256(-pnl6);

            require(freeBalance[trader] >= loss, "trader insolvent");

            freeBalance[trader] -= loss;

            uint256 provision = (loss * provisionCheckBps) / COMMISSION_BPS_DENOM;
            uint256 lpShare = loss - provision;

            ownerFeeReserve += provision;
            lpFreeCapital += lpShare;

            currentEpochRealizedPnl += int256(loss);
        }
    }
    
}
