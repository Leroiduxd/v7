---

# Brokex Core — Units and Formula Documentation

## 1. Numeric Conventions and Units

Brokex uses fixed-point integer math. Every risk, price, fee, and ratio parameter must be interpreted with the correct unit.

### 1.1 USD amounts: `USD6`

All monetary risk values are stored in **USD with 6 decimals**, noted as `USD6`.

Examples:

* `1 USD` = `1_000_000`
* `1,000 USD` = `1_000 * 1e6`
* `50,000 USD` = `50_000 * 1e6`

This unit is used for values such as:

* `marginUsdc`
* `lpLockedCapital`
* `longMaxProfit`
* `shortMaxProfit`
* `longMaxLoss`
* `shortMaxLoss`
* `needLock`
* `imbalanceBufferUsd6`
* `imbalanceKUsd6`
* `alphaScale`

---

### 1.2 Prices: `price1e6`

Oracle prices are normalized to **6 decimals**.

Examples:

* BTC price `62,345.12` is stored as `62_345_120_000`
* EUR/USD price `1.084321` is stored as `1_084_321`

All internal price formulas assume prices are expressed in `1e6` precision.

---

### 1.3 Percentages and ratios: `BPS`

Percentages are stored in **basis points**.

* `10000` = 100%
* `9000` = 90%
* `8500` = 85%
* `15000` = 1.50x
* `40000` = 4.00x

Used for:

* `alphaCutBps`
* `minCoverBps`
* `minGlobalCoverBps`
* `imbalanceMaxRatioBps`
* `imbalanceMinRatioBps`
* `maxAssetLockBps`

---

### 1.4 WAD precision: `1e18`

Some dynamic factors are represented with **18 decimals**, especially:

* spread multipliers
* funding accumulators
* weekend funding percentages

Examples:

* `1e18` = 1.0
* `5e16` = 5%
* `2e17` = 20%

Used for:

* `spread`
* `baseFundingRate`
* `weekendFunding`
* funding indexes
* spread multiplier outputs

---

## 2. Asset-Level Parameters

Each listed asset contains the following important parameters.

### Risk and pricing parameters

* `numerator`, `denominator`: define lot notional conversion
* `spread`: base spread in WAD (`1e18`)
* `commission`: fee in basis points
* `baseFundingRate`: funding rate in WAD
* `weekendFunding`: extra weekend funding in WAD
* `securityMultiplier`: max-profit cap from leverage-based logic
* `maxPhysicalMove`: max physical move assumption, in percent
* `maxLeverage`: maximum allowed leverage
* `maxLongLots`, `maxShortLots`: hard directional lot caps
* `maxOracleDelay`: maximum age of oracle proof in seconds

### Alpha / capital efficiency parameters

* `alphaCutBps`: maximum reduction allowed by alpha
* `alphaScale`: depth parameter for alpha, in `USD6`
* `minCoverBps`: minimum local lock coverage required after close

### Market balance / concentration parameters

* `imbalanceBufferUsd6`: free zone before directional imbalance restriction starts
* `imbalanceKUsd6`: smoothing parameter for imbalance tightening, in `USD6`
* `imbalanceMaxRatioBps`: maximum dominant/minority ratio allowed just above buffer
* `imbalanceMinRatioBps`: minimum dominant/minority ratio allowed at very large risk
* `maxAssetLockBps`: max share of total LP capital that one asset may lock

---

## 3. Core Formulas

---

# 3.1 Notional Value

```solidity
notional = (price * lotSize * numerator) / denominator
```

### Meaning

This converts a lot size into its USD notional value.

### Inputs

* `price`: asset price in `1e6`
* `lotSize`: number of lots
* `numerator / denominator`: asset contract size ratio

### Output

* notional value in `USD6`

---

# 3.2 Margin

```solidity
margin = notional / leverage
```

### Meaning

This is the trader collateral required to open the position.

### Output

* margin in `USD6`

---

# 3.3 Locked LP Capital

```solidity
maxProfitLev = (margin * securityMultiplier) / 100
physMoveVal  = (entryPrice * maxPhysicalMove) / 100
physProfit   = getNotionalValue(asset, physMoveVal, lotSize)

lockedCapital = min(maxProfitLev, physProfit)
```

### Meaning

This estimates the maximum gain the trader may extract from the vault for this trade.

It is capped by two limits:

1. **leverage/security-based cap**
2. **physical move cap**

The protocol locks the smaller of the two.

### Output

* locked capital in `USD6`

---

# 3.4 Commission

```solidity
commission = (notional * commissionBps) / 10000
```

### Meaning

Opening commission charged on the position notional.

### Output

* commission in `USD6`

---

# 3.5 Dynamic Spread

```solidity
numerator   = abs(L - S)
denominator = L + S + 2
p           = ((numerator * 1e18) / denominator)^2 / 1e18

if dominant side:
    spread = baseSpread * (1 + 3p)
else:
    spread = baseSpread
```

Where:

* `L` = long lots after simulated action
* `S` = short lots after simulated action

### Meaning

The spread increases for the dominant side when the book becomes imbalanced.

This penalizes opening or closing in the already crowded direction.

### Important details

* the imbalance effect is quadratic
* the `+2` term prevents instability when the book is small
* only the dominant side pays the higher spread

### Output

* spread multiplier in WAD (`1e18`)

---

# 3.6 Weekend Funding

```solidity
weekendsCrossed = currentWeek - openWeek
weekendFundingTotal = weekendsCrossed * weekendFunding
```

### Meaning

Extra funding is charged for each weekend crossed by the position.

The week calculation is shifted so that the weekend boundary is handled consistently.

### Output

* cumulative weekend funding percentage in WAD (`1e18`)

---

# 3.7 Alpha Reduction

```solidity
matched  = min(longMaxProfit, shortMaxProfit)
dominant = max(longMaxProfit, shortMaxProfit)

balance = (matched * BPS) / dominant
depth   = (matched * BPS) / (matched + alphaScale)

cut   = alphaCutBps * balance * depth / (BPS * BPS)
alpha = BPS - cut
```

### Meaning

Alpha reduces the amount of LP capital that must be locked when both sides of the market are balanced.

It depends on two things:

### A. Balance

```solidity
balance = matched / dominant
```

* close to `1` when long and short risk are balanced
* close to `0` when one side dominates

### B. Depth

```solidity
depth = matched / (matched + alphaScale)
```

* small when matched risk is still shallow
* large when the book has meaningful depth

### Result

* small or imbalanced book → `alpha ≈ 100%`
* deep and balanced book → `alpha` decreases toward its minimum

### Bounds

If `alphaCutBps = 2000`, then minimum alpha is:

```text
10000 - 2000 = 8000 = 80%
```

So the protocol will still lock at least 80% of worst-side risk.

---

# 3.8 Needed LP Lock

```solidity
worstSide = max(longMaxProfit, shortMaxProfit)
needLock  = (worstSide * alpha) / 10000
```

### Meaning

This is the effective LP capital that should be locked for one asset after alpha reduction.

### Output

* needed lock in `USD6`

---

# 3.9 Market Imbalance Control

The protocol checks whether adding a new trade would push the market too far in one direction.

First, it simulates the new dominant-side risk:

```solidity
if isLong:
    longRisk += addedMaxProfit
else:
    shortRisk += addedMaxProfit
```

Then:

```solidity
totalRisk = longRisk + shortRisk
```

If `totalRisk <= buffer`, there is no imbalance restriction.

Otherwise, the maximum allowed dominant/minority ratio is:

```solidity
x = totalRisk - buffer
extra = (maxRatio - minRatio) * K^2 / (x^2 + K^2)
allowedRatio = minRatio + extra
```

### Meaning

This creates a smooth tightening curve:

* below buffer: free market formation
* slightly above buffer: still permissive
* much larger than buffer: ratio converges toward `minRatio`

### Interpretation

* `buffer` defines the free zone
* `K` defines how quickly the system tightens
* `maxRatio` is the initial leniency
* `minRatio` is the strict final regime

---

# 3.10 Open Imbalance Check

After computing the new risks:

```solidity
dominant = max(longRisk, shortRisk)
minority = min(longRisk, shortRisk)

allowed = dominant * 10000 <= minority * allowedRatioBps
```

### Meaning

The new trade is accepted only if the dominant side is not too large compared with the minority side.

If the minority side is zero and the system is outside the free buffer, the trade is rejected.

---

# 3.11 Asset Concentration Check

```solidity
newNeedLock = computeNeedLockAfterOpen(...)
totalLpCapital = lpFreeCapital + lpLockedCapital
maxAllowedForAsset = totalLpCapital * maxAssetLockBps / 10000
```

The trade is rejected if:

```solidity
newNeedLock > maxAllowedForAsset
```

### Meaning

No single asset may lock too large a portion of total LP capital.

This protects the vault against concentration risk.

---

# 3.12 Funding Rate Curve

```solidity
r = abs(L - S) / (L + S + 2)
p = r^2
dominantRate = baseFunding * (1 + 3p)
```

### Meaning

Funding increases for the dominant side as the market becomes more imbalanced.

* balanced book → both sides pay base funding
* imbalanced book → dominant side pays more

This discourages crowded positioning over time.

---

# 3.13 Net PnL

First, the exit spread is applied:

For longs:

```solidity
exitPrice = marketPrice - spreadAmount
```

For shorts:

```solidity
exitPrice = marketPrice + spreadAmount
```

Then raw PnL is:

```solidity
delta = isLong ? exitPrice - openPrice : openPrice - exitPrice

rawPnl = delta * lotSize * numerator * 1e12 / denominator
```

### Why `1e12`?

Because prices are `1e6`, and this step converts the result into `1e18` precision before fee subtraction.

---

# 3.14 Funding and Weekend Fees

Funding paid:

```solidity
fundingPaid = exitNotional * deltaFundingIndex / 1e18
```

Weekend fee:

```solidity
weekendFee = exitNotional * weekendPercent / 1e18
```

Total extra fees:

```solidity
extraFees = fundingPaid + weekendFee
```

Final PnL:

```solidity
finalPnl = rawPnl - extraFees * 1e12
```

### Output

* final PnL in `1e18`

Later, the core converts it to `USD6` using division by `1e12`.

---

# 3.15 Positive and Negative PnL Caps

When closing, realized PnL is capped.

### Positive side

```solidity
maxGain = lpLockedCapital * 1e12
```

Trader profit cannot exceed the LP capital reserved for that position.

### Negative side

If loss reaches the liquidation threshold:

```solidity
liqCut = marginOut * 90%
```

Then the trade is treated as fully exhausting remaining margin:

```solidity
pnl = -marginOut
```

### Meaning

This ensures the trader cannot lose more than remaining collateral, while LP profit stays bounded by trader margin mechanics.

---

# 3.16 Local and Global Cover Checks

When extra LP funds must be released to pay trader profit, the protocol verifies that the vault remains sufficiently covered.

### Local cover

```solidity
lockAfter * 10000 >= newNeed * minCoverBps
```

### Global cover

```solidity
lockedAfter * 10000 >= totalNeedLock * minGlobalCoverBps
```

### Meaning

Even after paying profits, the protocol must keep enough lock:

* locally for the asset
* globally for the whole vault

This prevents over-draining the LP lock pool.

---

# 3.17 Unrealized PnL Aggregation

For monitoring purposes, the protocol estimates unrealized asset PnL:

### Long side

```solidity
longPnl = currentValue - entryValue
```

Capped by:

* `longMaxProfit` on the upside
* `longMaxLoss` on the downside

### Short side

```solidity
shortPnl = entryValue - currentValue
```

Capped by:

* `shortMaxProfit` on the upside
* `shortMaxLoss` on the downside

Then:

```solidity
assetPnl = -(longPnl + shortPnl)
```

### Meaning

This gives the vault-side unrealized PnL contribution for each asset, bounded by the protocol’s internal risk caps.

---

## 4. Practical Parameter Examples

### Example A — Imbalance parameters

```solidity
imbalanceBufferUsd6     = 50_000 * 1e6;   // 50,000 USD
imbalanceKUsd6          = 100_000 * 1e6;  // 100,000 USD
imbalanceMaxRatioBps    = 30000;          // 3.00x
imbalanceMinRatioBps    = 11500;          // 1.15x
maxAssetLockBps         = 1200;           // 12%
```

### Example B — Alpha parameters

```solidity
alphaCutBps             = 1500;           // max 15% reduction
alphaScale              = 75_000 * 1e6;   // 75,000 USD depth scale
minCoverBps             = 9000;           // 90%
minGlobalCoverBps       = 9000;           // 90%
```

---

## 5. Important Calibration Note

`alphaScale` must be expressed in `USD6`, exactly like `matched`, `longMaxProfit`, and `shortMaxProfit`.

So:

```solidity
alphaScale = 1_000_000
```

means only **1 USD**, not 1,000,000 USD.

If the intention is:

* `1,000 USD` → use `1_000 * 1e6`
* `100,000 USD` → use `100_000 * 1e6`
* `1,000,000 USD` → use `1_000_000 * 1e6`

This is one of the most important calibration points in the system.

---

## 6. High-Level Summary

Brokex combines multiple layers of protection:

1. **Per-trade margin and LP lock**
2. **Dynamic spread**
3. **Dynamic funding**
4. **Alpha-based capital efficiency**
5. **Directional imbalance control**
6. **Per-asset concentration limits**
7. **Local and global cover constraints**

The design goal is to protect LP solvency while still allowing capital-efficient operation when the market is balanced.

---
