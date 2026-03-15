// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    BrokexVault
    -----------------------------------------
    PRINCIPES DE CE VAULT

    1) Tout est normalisé en 1e6 :
       - USDC = 1e6
       - LP shares = 1e6
       - LP price = 1e6
       Donc :
       1 LP token = 1_000_000 unités internes

    2) Dépôts LP
       - un LP dépose depuis son wallet, pas depuis son solde trader
       - chaque LP a une demande de dépôt par epoch
       - pendant l'epoch courante il peut augmenter ou réduire sa demande
       - au roll on calcule le prix
       - puis on "mint" globalement les nouvelles shares
       - ensuite chacun peut appeler processDeposit(depositId)
         pour créditer son solde LP personnel

    3) Retraits LP
       - un LP demande un retrait en LP shares
       - sa demande appartient à l'epoch courante de retrait
       - pendant l'epoch courante il peut augmenter ou réduire sa demande
       - ses LP shares sont immédiatement réservées :
         elles quittent son lpBalance personnel, mais ne sont PAS encore burn
       - le burn réel se fait au roll si le vault peut satisfaire une partie
       - le roll ne distribue pas directement par epoch de retrait
       - il crée des "withdraw pools" globaux
       - processWithdraw() affecte ensuite ces pools
         aux epochs de retrait dans l'ordre chronologique

    4) Ordre important dans rollEpoch()
       - on calcule d'abord le prix LP à partir de la photo du système
         AVANT mint et AVANT burn
       - ensuite seulement on burn les retraits satisfaits
       - puis on mint les dépôts de l'epoch
       - donc le prix stocké pour l'epoch est toujours le prix "pré-mouvements"

    5) Netting entrant / sortant
       - les nouveaux dépôts LP peuvent directement financer les retraits
       - donc les dollars entrants ne "dorment" pas inutilement
       - seul le solde net modifie lpFreeCapital

    6) Dust mode
       - si le capital LP devient très petit (< dustThreshold),
         on force un prix à 1$ et on ignore le pnl non réalisé
       - on NE fait PAS un hard reset total des balances utilisateurs,
         car cela casserait les soldes internes sans boucle sur tous les LP
*/

// ==========================================
// INTERFACES
// ==========================================

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IBrokexCore {
    /*
        On suppose ici que le PnL retourné est lui aussi en 1e6.
        Si ton Core retourne un autre format, il faudra convertir ici.
    */
    function getLastFinishedPnlRun() external view returns (int256 pnl, uint64 timestamp);
}

// ==========================================
// CONTRACT
// ==========================================

contract BrokexVault {
    // --------------------------------------
    // Basic roles / addresses
    // --------------------------------------
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

    // --------------------------------------
    // Constants
    // --------------------------------------
    uint256 public constant epochDuration = 1 days;
    uint256 public constant oneDollar = 1_000_000;      // 1.000000
    uint256 public constant dustThreshold = 10_000_000; // 10 USDC

    uint256 public constant COMMISSION_OWNER_BPS = 3000;
    uint256 public constant COMMISSION_BPS_DENOM = 10000;
    uint256 public constant TARGET_PERF_FEE_BPS = 2000;

    uint256 public provisionCheckBps = 1500;
    uint256 public ownerFeeReserve;
    int256 public currentEpochRealizedPnl;

    // --------------------------------------
    // Trader balances
    // --------------------------------------
    mapping(address => uint256) public freeBalance;
    mapping(address => uint256) public lockedBalance;

    // --------------------------------------
    // LP accounting
    // --------------------------------------
    /*
        lpFreeCapital:
        liquidité LP libre et utilisable immédiatement

        lpLockedCapital:
        liquidité LP déjà engagée dans des trades ouverts

        lpBalance[user]:
        nombre de LP shares disponibles dans le wallet interne du LP
        (hors shares déjà réservées pour un retrait)

        totalLpShares:
        total supply globale de LP shares
    */
    uint256 public lpFreeCapital;
    uint256 public lpLockedCapital;

    mapping(address => uint256) public lpBalance;
    uint256 public totalLpShares;

    // --------------------------------------
    // Epochs
    // --------------------------------------
    uint256 public currentEpoch;
    uint256 public epochStartTimestamp;
    uint256 public lastPrice;

    struct EpochData {
        /*
            price:
            prix LP calculé sur la photo AVANT mint / burn du roll

            timestamp:
            moment précis du roll

            totalShares:
            totalLpShares APRÈS burn + mint de cette epoch
        */
        uint256 price;
        uint256 timestamp;
        uint256 totalShares;
    }

    mapping(uint256 => EpochData) public epochs;

    // --------------------------------------
    // LP deposits
    // --------------------------------------
    struct DepositRequest {
        address user;
        uint256 epoch;
        uint256 amount;      // montant USDC demandé en dépôt (1e6)
        bool processed;      // processDeposit déjà fait ou non
    }

    uint256 public nextDepositId;
    mapping(uint256 => DepositRequest) public depositRequests;

    /*
        pendingDeposits[epoch]:
        total des dollars déposés pendant cette epoch,
        pas encore intégrés au capital LP avant le roll
    */
    mapping(uint256 => uint256) public pendingDeposits;

    /*
        Un utilisateur a au plus une demande de dépôt par epoch
    */
    mapping(address => mapping(uint256 => uint256)) public userDepositId;

    // --------------------------------------
    // LP withdraw requests
    // --------------------------------------
    struct WithdrawRequest {
        address user;
        uint256 epoch;
        uint256 shares;       // shares réservées pour ce retrait
        uint256 claimedAmount; // dollars déjà claimés par cet utilisateur pour cette epoch
    }

    uint256 public nextWithdrawId;
    mapping(uint256 => WithdrawRequest) public withdrawRequests;

    /*
        Un utilisateur a au plus une demande de retrait par epoch
    */
    mapping(address => mapping(uint256 => uint256)) public userWithdrawId;

    struct WithdrawEpochData {
        /*
            totalShares:
            total demandé au retrait sur cette epoch

            remainingShares:
            partie pas encore satisfaite / pas encore affectée

            satisfiedShares:
            partie déjà satisfaite au fil du temps

            allocatedAmount:
            dollars déjà alloués à cette epoch de retrait
            via processWithdraw()
        */
        uint256 totalShares;
        uint256 remainingShares;
        uint256 satisfiedShares;
        uint256 allocatedAmount;
        bool exists;
    }

    mapping(uint256 => WithdrawEpochData) public withdrawEpochs;

    /*
        totalPendingWithdrawShares:
        total global de shares demandées au retrait
        mais PAS ENCORE globalement satisfaites / burnées au roll
    */
    uint256 public totalPendingWithdrawShares;

    /*
        Pour traiter les epochs de retrait chronologiquement,
        on garde un pointeur vers la plus vieille epoch non encore terminée.
    */
    uint256 public oldestWithdrawEpoch;
    bool public hasWithdrawQueue;

    // --------------------------------------
    // Withdraw pools created at roll
    // --------------------------------------
    struct WithdrawPool {
        /*
            Chaque roll peut créer un "pool" de retraits satisfaits
            au prix du roll de cette epoch.

            shares:
            combien de LP shares ont été burnées globalement

            amount:
            combien de dollars cela représente à ce prix-là
        */
        uint256 shares;
        uint256 amount;
        bool exists;
    }

    /*
        On indexe le pool par l'epoch de roll.
        Un roll donné crée au maximum un pool.
    */
    mapping(uint256 => WithdrawPool) public withdrawPools;

    uint256 public oldestWithdrawPoolEpoch;
    bool public hasWithdrawPools;

    // --------------------------------------
    // Events
    // --------------------------------------
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event CoreSet(address indexed coreAddress);

    event TraderDeposit(address indexed trader, uint256 amount);
    event TraderWithdraw(address indexed trader, uint256 amount);

    event DepositUpdated(
        address indexed user,
        uint256 indexed epoch,
        uint256 indexed depositId,
        uint256 amount,
        bool increase
    );

    event DepositProcessed(
        uint256 indexed depositId,
        address indexed user,
        uint256 amount,
        uint256 shares
    );

    event WithdrawUpdated(
        address indexed user,
        uint256 indexed epoch,
        uint256 indexed withdrawId,
        uint256 shares,
        bool increase
    );

    event EpochRolled(
        uint256 indexed closedEpoch,
        uint256 price,
        uint256 sharesBurned,
        uint256 withdrawAmountReserved,
        uint256 sharesMinted,
        uint256 totalSharesAfterRoll,
        uint256 newLpFreeCapital,
        uint256 timestamp
    );

    event WithdrawPoolCreated(
        uint256 indexed poolEpoch,
        uint256 shares,
        uint256 amount
    );

    event WithdrawProcessed(
        uint256 indexed poolEpoch,
        uint256 indexed withdrawEpoch,
        uint256 sharesAssigned,
        uint256 amountAssigned
    );

    event WithdrawClaimed(
        address indexed user,
        uint256 indexed withdrawEpoch,
        uint256 indexed withdrawId,
        uint256 amount
    );

    event DustModeUsed(
        uint256 indexed epoch,
        uint256 timestamp
    );

    // --------------------------------------
    // Constructor
    // --------------------------------------
    constructor(address usdcAddress) {
        require(usdcAddress != address(0), "Invalid USDC");
        owner = msg.sender;
        usdc = IERC20(usdcAddress);
        epochStartTimestamp = block.timestamp;
        lastPrice = oneDollar;
    }

    // ======================================
    // INTERNAL HELPERS
    // ======================================

    /*
        Convertit un montant USDC (1e6) en LP shares (1e6)
        au prix donné (1e6)
    */
    function _sharesFromAmount(uint256 amount, uint256 price) internal pure returns (uint256) {
        return (amount * oneDollar) / price;
    }

    /*
        Convertit des LP shares (1e6) en dollars (1e6)
        au prix donné (1e6)
    */
    function _amountFromShares(uint256 shares, uint256 price) internal pure returns (uint256) {
        return (shares * price) / oneDollar;
    }

    /*
        Réserve théorique à garder libre pour les retraits NON ENCORE satisfaits.
        Cette valeur est seulement une estimation prudentielle.
        Le vrai prix effectif est calculé uniquement au roll.
    */
    function getEstimatedWithdrawReserve() public view returns (uint256) {
        uint256 price = lastPrice;
        if (price == 0) price = oneDollar;
        return _amountFromShares(totalPendingWithdrawShares, price);
    }

    /*
        Capital LP total "photo" du système
    */
    function getLpCapital() public view returns (uint256) {
        return lpFreeCapital + lpLockedCapital;
    }

    // ======================================
    // ADMIN
    // ======================================

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "owner zero");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setCore(address coreAddress) external onlyOwner {
        require(!coreSet, "Core already set");
        require(coreAddress != address(0), "Invalid core");
        core = coreAddress;
        coreSet = true;
        emit CoreSet(coreAddress);
    }

    // ======================================
    // TRADER FUNDS
    // ======================================

    /*
        Dépôt trader classique :
        wallet -> freeBalance trader
    */
    function traderDeposit(uint256 amount) external {
        require(amount > 0, "amount zero");

        bool success = usdc.transferFrom(msg.sender, address(this), amount);
        require(success, "transfer failed");

        freeBalance[msg.sender] += amount;
        emit TraderDeposit(msg.sender, amount);
    }

    /*
        Retrait trader classique :
        freeBalance trader -> wallet
    */
    function traderWithdraw(uint256 amount) external {
        require(amount > 0, "amount zero");
        require(freeBalance[msg.sender] >= amount, "insufficient free");

        freeBalance[msg.sender] -= amount;

        bool success = usdc.transfer(msg.sender, amount);
        require(success, "transfer failed");

        emit TraderWithdraw(msg.sender, amount);
    }

    // ======================================
    // LP DEPOSITS
    // ======================================

    /*
        lpDeposit(amount, true)
        -> augmente la demande de dépôt LP de l'epoch courante

        lpDeposit(amount, false)
        -> réduit la demande de dépôt LP de l'epoch courante
           et renvoie l'USDC au wallet

        IMPORTANT:
        - ça ne touche pas au solde trader
        - ça transfère directement depuis / vers le wallet
    */
    function lpDeposit(uint256 amount, bool increase) external {
        require(amount > 0, "amount zero");

        uint256 epoch = currentEpoch;
        uint256 depositId = userDepositId[msg.sender][epoch];

        // Si l'utilisateur n'a pas encore de demande de dépôt
        // pour cette epoch, on lui en crée une.
        if (depositId == 0) {
            nextDepositId++;
            depositId = nextDepositId;

            userDepositId[msg.sender][epoch] = depositId;
            depositRequests[depositId] = DepositRequest({
                user: msg.sender,
                epoch: epoch,
                amount: 0,
                processed: false
            });
        }

        DepositRequest storage request = depositRequests[depositId];
        require(!request.processed, "already processed");
        require(request.epoch == currentEpoch, "wrong epoch");

        if (increase) {
            bool success = usdc.transferFrom(msg.sender, address(this), amount);
            require(success, "transfer failed");

            request.amount += amount;
            pendingDeposits[epoch] += amount;
        } else {
            require(request.amount >= amount, "not enough deposit");

            request.amount -= amount;
            pendingDeposits[epoch] -= amount;

            bool success = usdc.transfer(msg.sender, amount);
            require(success, "transfer failed");
        }

        emit DepositUpdated(msg.sender, epoch, depositId, amount, increase);
    }

    /*
        Après qu'une epoch ait été roll,
        n'importe qui peut process la demande de dépôt pour
        créditer le LP en shares.

        IMPORTANT:
        - le mint global a déjà été pris en compte dans totalLpShares au roll
        - ici on ne change PAS totalLpShares
        - ici on crédite seulement le lpBalance utilisateur
    */
    function processDeposit(uint256[] calldata depositIds) external {
        for (uint256 i = 0; i < depositIds.length; i++) {
            uint256 depositId = depositIds[i];
            DepositRequest storage request = depositRequests[depositId];
    
            require(request.user != address(0), "deposit not found");
            require(!request.processed, "already processed");
            require(currentEpoch > request.epoch, "epoch not closed");
    
            uint256 price = epochs[request.epoch].price;
            require(price > 0, "price not set");
    
            uint256 shares = _sharesFromAmount(request.amount, price);
            require(shares > 0, "shares zero");
    
            request.processed = true;
            lpBalance[request.user] += shares;
    
            emit DepositProcessed(depositId, request.user, request.amount, shares);
        }
    }

    // ======================================
    // LP WITHDRAW REQUESTS
    // ======================================

    /*
        lpWithdraw(shares, true)
        -> ajoute une demande de retrait sur l'epoch courante

        lpWithdraw(shares, false)
        -> réduit cette demande de retrait si on est toujours dans la même epoch

        CHOIX IMPORTANT:
        Quand un LP demande un retrait, ses shares sont immédiatement
        sorties de son lpBalance personnel et réservées dans sa request.
        Elles ne sont pas encore burnées du total supply.
        Le burn réel se fera plus tard au roll si le vault peut satisfaire
        une partie de la file de retrait.

        Ce choix évite qu'un utilisateur puisse redemander plusieurs fois
        les mêmes shares.
    */
    function lpWithdraw(uint256 shares, bool increase) external {
        require(shares > 0, "shares zero");

        uint256 epoch = currentEpoch;
        uint256 withdrawId = userWithdrawId[msg.sender][epoch];

        if (withdrawId == 0) {
            nextWithdrawId++;
            withdrawId = nextWithdrawId;

            userWithdrawId[msg.sender][epoch] = withdrawId;
            withdrawRequests[withdrawId] = WithdrawRequest({
                user: msg.sender,
                epoch: epoch,
                shares: 0,
                claimedAmount: 0
            });
        }

        WithdrawRequest storage request = withdrawRequests[withdrawId];
        require(request.epoch == currentEpoch, "wrong epoch");

        WithdrawEpochData storage bucket = withdrawEpochs[epoch];
        if (!bucket.exists) {
            bucket.exists = true;

            if (!hasWithdrawQueue) {
                hasWithdrawQueue = true;
                oldestWithdrawEpoch = epoch;
            }
        }

        if (increase) {
            require(lpBalance[msg.sender] >= shares, "not enough lp balance");

            // On réserve immédiatement les shares
            lpBalance[msg.sender] -= shares;
            request.shares += shares;

            bucket.totalShares += shares;
            bucket.remainingShares += shares;
            totalPendingWithdrawShares += shares;
        } else {
            require(request.shares >= shares, "not enough withdraw");

            // On rend les shares au LP tant que l'epoch n'est pas close
            request.shares -= shares;
            lpBalance[msg.sender] += shares;

            bucket.totalShares -= shares;
            bucket.remainingShares -= shares;
            totalPendingWithdrawShares -= shares;
        }

        emit WithdrawUpdated(msg.sender, epoch, withdrawId, shares, increase);
    }

    // ======================================
    // ROLL EPOCH
    // ======================================

    /*
        RÈGLE DE ROLL

        Epoch 0:
        - seulement owner
        - prix = 1$

        Epoch suivantes:
        - n'importe qui peut appeler
        - il faut 24h écoulées
        - le PnL run du Core doit dater de moins de 2 minutes

        ORDRE INTERNE DU ROLL
        1) on prend la photo du système
        2) on calcule le prix LP avant tout mouvement
        3) on calcule combien de retraits peuvent être satisfaits
           avec lpFreeCapital + dépôts entrants
        4) on burn globalement cette partie
        5) on mint globalement les dépôts de l'epoch
        6) on stocke le snapshot de l'epoch
        7) la répartition chronologique par epoch de retrait se fera plus tard
           dans processWithdraw()
    */
    function rollEpoch() external {
        uint256 epoch = currentEpoch;
        uint256 capitalBefore = lpFreeCapital + lpLockedCapital;

        uint256 price;
        uint256 sharesBurned;
        uint256 withdrawAmountReserved;
        uint256 sharesMinted;

        // ----------------------------------
        // 0) First epoch special case
        // ----------------------------------
        if (epoch == 0) {
            require(msg.sender == owner, "first roll owner only");
            price = oneDollar;
        } else {
            require(block.timestamp >= epochStartTimestamp + epochDuration, "epoch not finished");
            require(core != address(0), "core not set");

            // ----------------------------------
            // 1) Settle owner performance fee for the epoch that is ending
            // ----------------------------------
            if (currentEpochRealizedPnl > 0) {
                uint256 netProfit6 = uint256(currentEpochRealizedPnl);
                uint256 entitledFee6 = (netProfit6 * TARGET_PERF_FEE_BPS) / COMMISSION_BPS_DENOM;

                if (ownerFeeReserve >= entitledFee6) {
                    freeBalance[owner] += entitledFee6;
                    lpFreeCapital += (ownerFeeReserve - entitledFee6);
                } else {
                    freeBalance[owner] += ownerFeeReserve;
                }
            } else {
                // Si le bilan net est nul ou négatif, le owner ne prend rien.
                // Toute la réserve provisoire retourne au LP free capital.
                lpFreeCapital += ownerFeeReserve;
            }

            // Reset pour la nouvelle epoch
            ownerFeeReserve = 0;
            currentEpochRealizedPnl = 0;

            // ----------------------------------
            // 2) Compute LP price BEFORE mint / burn
            // ----------------------------------
            uint256 capital = lpFreeCapital + lpLockedCapital;

            if (capital < dustThreshold) {
                price = oneDollar;
            } else {
                (int256 unrealizedPnl, uint64 pnlTimestamp) = IBrokexCore(core).getLastFinishedPnlRun();

                require(block.timestamp >= pnlTimestamp, "future pnl timestamp");
                require(block.timestamp - pnlTimestamp <= 120, "pnl too old");

                if (totalLpShares == 0) {
                    price = oneDollar;
                } else {
                    int256 equity = int256(capital) + unrealizedPnl;
                    require(equity > 0, "equity not positive");

                    price = (uint256(equity) * oneDollar) / totalLpShares;
                    require(price > 0, "price zero");
                }
            }
        }

        lastPrice = price;

        // ----------------------------------
        // 3) Read deposits of the closing epoch
        // ----------------------------------
        uint256 deposits = pendingDeposits[epoch];

        // ----------------------------------
        // 4) Global withdraw satisfaction
        //    available cash = current lpFreeCapital + new deposits
        // ----------------------------------
        uint256 availableCash = lpFreeCapital + deposits;

        if (totalPendingWithdrawShares > 0 && availableCash > 0) {
            uint256 maxSharesFromCash = (availableCash * oneDollar) / price;

            sharesBurned = maxSharesFromCash;
            if (sharesBurned > totalPendingWithdrawShares) {
                sharesBurned = totalPendingWithdrawShares;
            }

            if (sharesBurned > 0) {
                withdrawAmountReserved = (sharesBurned * price) / oneDollar;

                require(totalLpShares >= sharesBurned, "burn exceeds supply");
                totalLpShares -= sharesBurned;

                totalPendingWithdrawShares -= sharesBurned;

                WithdrawPool storage pool = withdrawPools[epoch];
                pool.exists = true;
                pool.shares += sharesBurned;
                pool.amount += withdrawAmountReserved;

                if (!hasWithdrawPools) {
                    hasWithdrawPools = true;
                    oldestWithdrawPoolEpoch = epoch;
                }

                emit WithdrawPoolCreated(epoch, sharesBurned, withdrawAmountReserved);
            }
        }

        // ----------------------------------
        // 5) Global mint of deposits of the epoch
        // ----------------------------------
        if (deposits > 0) {
            sharesMinted = (deposits * oneDollar) / price;
            require(sharesMinted > 0, "mint shares zero");
            totalLpShares += sharesMinted;
        }

        // ----------------------------------
        // 6) Net update of lpFreeCapital
        // ----------------------------------
        lpFreeCapital = lpFreeCapital + deposits - withdrawAmountReserved;

        // ----------------------------------
        // 7) Update reserve variable for future lockLpCapital calls
        // ----------------------------------

        // ----------------------------------
        // 8) Save epoch snapshot
        // price = before mint / burn
        // totalShares = after mint / burn
        // ----------------------------------
        epochs[epoch] = EpochData({
            price: price,
            timestamp: block.timestamp,
            totalShares: totalLpShares
        });

        // ----------------------------------
        // 9) Advance epoch
        // ----------------------------------
        currentEpoch = epoch + 1;
        epochStartTimestamp = block.timestamp;

        emit EpochRolled(
            epoch,
            price,
            sharesBurned,
            withdrawAmountReserved,
            sharesMinted,
            totalLpShares,
            lpFreeCapital,
            block.timestamp
        );

        capitalBefore; // juste pour éviter warning si jamais tu ne l'utilises pas ailleurs
    }

    // ======================================
    // PROCESS WITHDRAW
    // ======================================

    /*
        Cette fonction est volontairement séparée de rollEpoch()
        pour éviter une grosse boucle dans le roll.

        Elle prend les pools de retraits créés au roll
        et les affecte chronologiquement aux epochs de retrait :
        epoch N, puis N+1, puis N+2, etc.

        IMPORTANT:
        - ordre strict entre epochs
        - prorata à l'intérieur d'une même epoch
        - si plusieurs pools existent à des prix différents,
          ils sont consommés chronologiquement aussi
    */
    function processWithdraw(uint256 maxSteps) external {
        require(maxSteps > 0, "steps zero");
        if (!hasWithdrawQueue || !hasWithdrawPools) return;

        uint256 steps = 0;
        uint256 poolEpoch = oldestWithdrawPoolEpoch;
        uint256 withdrawEpoch = oldestWithdrawEpoch;

        while (steps < maxSteps) {
            // Si plus de pools à traiter, on sort
            if (!hasWithdrawPools) break;
            if (!hasWithdrawQueue) break;

            WithdrawPool storage pool = withdrawPools[poolEpoch];
            WithdrawEpochData storage bucket = withdrawEpochs[withdrawEpoch];

            // ------------------------------
            // Avance sur les pools vides
            // ------------------------------
            if (!pool.exists || pool.shares == 0 || pool.amount == 0) {
                poolEpoch++;

                oldestWithdrawPoolEpoch = poolEpoch;

                if (poolEpoch >= currentEpoch) {
                    hasWithdrawPools = false;
                    break;
                }

                steps++;
                continue;
            }

            // ------------------------------
            // Avance sur les epochs de retrait déjà satisfaites
            // ------------------------------
            if (!bucket.exists || bucket.remainingShares == 0) {
                withdrawEpoch++;

                oldestWithdrawEpoch = withdrawEpoch;

                if (withdrawEpoch >= currentEpoch) {
                    hasWithdrawQueue = false;
                    break;
                }

                steps++;
                continue;
            }

            // ------------------------------
            // On prend le minimum entre :
            // - ce que contient le pool
            // - ce qu'il reste à satisfaire sur cette epoch
            // ------------------------------
            uint256 sharesAssigned = pool.shares;
            if (sharesAssigned > bucket.remainingShares) {
                sharesAssigned = bucket.remainingShares;
            }

            /*
                Les dollars alloués doivent rester cohérents avec le prix
                implicite du pool. Comme un pool peut être consommé
                en plusieurs morceaux, on fait un prorata sur CE pool.
            */
            uint256 amountAssigned = (pool.amount * sharesAssigned) / pool.shares;

            // On met à jour le bucket de retrait
            bucket.remainingShares -= sharesAssigned;
            bucket.satisfiedShares += sharesAssigned;
            bucket.allocatedAmount += amountAssigned;

            // On met à jour le pool
            pool.shares -= sharesAssigned;
            pool.amount -= amountAssigned;

            emit WithdrawProcessed(poolEpoch, withdrawEpoch, sharesAssigned, amountAssigned);

            steps++;
        }
    }

    // ======================================
    // CLAIM WITHDRAW
    // ======================================

    /*
        Le claim se fait par epoch de retrait.
        Comme chaque utilisateur n'a qu'une demande par epoch,
        il suffit de fournir l'epoch.

        La somme disponible = quote-part de l'utilisateur
        dans allocatedAmount de cette epoch
        moins ce qu'il a déjà claim.
    */
    function claimWithdraw(uint256[] calldata withdrawEpochs_) external {
        uint256 totalAmount = 0;
    
        for (uint256 i = 0; i < withdrawEpochs_.length; i++) {
            uint256 withdrawEpoch = withdrawEpochs_[i];
            uint256 withdrawId = userWithdrawId[msg.sender][withdrawEpoch];
            require(withdrawId != 0, "withdraw not found");
    
            WithdrawRequest storage request = withdrawRequests[withdrawId];
            WithdrawEpochData storage bucket = withdrawEpochs[withdrawEpoch];
    
            require(request.user == msg.sender, "not your withdraw");
            require(bucket.totalShares > 0, "empty epoch");
    
            uint256 totalDue = (bucket.allocatedAmount * request.shares) / bucket.totalShares;
            require(totalDue > request.claimedAmount, "nothing to claim");
    
            uint256 amount = totalDue - request.claimedAmount;
            request.claimedAmount = totalDue;
    
            totalAmount += amount;
    
            emit WithdrawClaimed(msg.sender, withdrawEpoch, withdrawId, amount);
        }
    
        bool success = usdc.transfer(msg.sender, totalAmount);
        require(success, "transfer failed");
    }

    // ======================================
    // VIEWS
    // ======================================

    /*
        Combien un user peut claim maintenant sur une epoch de retrait donnée
    */
    function getClaimableWithdraw(address user, uint256 withdrawEpoch) external view returns (uint256) {
        uint256 withdrawId = userWithdrawId[user][withdrawEpoch];
        if (withdrawId == 0) return 0;

        WithdrawRequest storage request = withdrawRequests[withdrawId];
        WithdrawEpochData storage bucket = withdrawEpochs[withdrawEpoch];

        if (bucket.totalShares == 0) return 0;

        uint256 totalDue = (bucket.allocatedAmount * request.shares) / bucket.totalShares;
        if (totalDue <= request.claimedAmount) return 0;

        return totalDue - request.claimedAmount;
    }

    /*
        Solde LP "libre" d'un utilisateur
        = shares encore disponibles et non réservées à un retrait
    */
    function getLpBalance(address user) external view returns (uint256) {
        return lpBalance[user];
    }

    /*
        Demande de retrait de l'utilisateur pour une epoch
    */
    function getUserWithdraw(address user, uint256 epoch)
        external
        view
        returns (
            uint256 withdrawId,
            uint256 shares,
            uint256 claimedAmount
        )
    {
        withdrawId = userWithdrawId[user][epoch];
        if (withdrawId == 0) return (0, 0, 0);

        WithdrawRequest storage request = withdrawRequests[withdrawId];
        return (withdrawId, request.shares, request.claimedAmount);
    }

    /*
        Demande de dépôt de l'utilisateur pour une epoch
    */
    function getUserDeposit(address user, uint256 epoch)
        external
        view
        returns (
            uint256 depositId,
            uint256 amount,
            bool processed
        )
    {
        depositId = userDepositId[user][epoch];
        if (depositId == 0) return (0, 0, false);

        DepositRequest storage request = depositRequests[depositId];
        return (depositId, request.amount, request.processed);
    }

    // ======================================
    // MINIMAL EXECUTION PRIMITIVES
    // ======================================

    /*
        On laisse pour l'instant uniquement le noyau trader
        que tu avais déjà gardé.

        Les fonctions lockLpCapital / unlockLpCapital / collectCommission /
        settlePnl pourront être rebranchées ensuite.

        Le design actuel est déjà prêt à accueillir plus tard
        une réserve prudente via getEstimatedWithdrawReserve().
    */

    function lockTraderFunds(address trader, uint256 amount) external onlyCore {
        require(trader != address(0), "trader zero");
        require(amount > 0, "amount zero");
        require(freeBalance[trader] >= amount, "insufficient free");

        freeBalance[trader] -= amount;
        lockedBalance[trader] += amount;
    }

    function unlockTraderFunds(address trader, uint256 amount) external onlyCore {
        require(trader != address(0), "trader zero");
        require(amount > 0, "amount zero");
        require(lockedBalance[trader] >= amount, "insufficient locked");

        lockedBalance[trader] -= amount;
        freeBalance[trader] += amount;
    }

    function lockLpCapital(uint256 amount6) external onlyCore {
        require(amount6 > 0, "amount=0");

        uint256 estimatedReserve = getEstimatedWithdrawReserve();
        require(lpFreeCapital >= (estimatedReserve + amount6), "lpFree reserved");

        lpFreeCapital -= amount6;
        lpLockedCapital += amount6;
    }

    function unlockLpCapital(uint256 amount6) external onlyCore {
        require(amount6 > 0, "amount=0");
        require(lpLockedCapital >= amount6, "lpLocked underflow");

        lpLockedCapital -= amount6;
        lpFreeCapital += amount6;
    }

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
