# Uniswap Hooks

## Intro  

This repository contains a series of experimental projects built around Uniswap v4 hooks. Each project explores a different aspect of hook functionality from dynamic fee adjustments to security testing.  

### Setup & Installation  
This project uses [Foundry](https://book.getfoundry.sh/) for development and testing.  

1. Install Foundry if not already installed:  
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. Clone this repository and install dependencies:
    ```
    git clone <your-repo-url>
    cd <repo>
    forge install
    ```
3. Run tests locally:
    ```
    forge test
    ```
4. To run fork tests, configure your mainnet RPC URL (I used Alchemy):
    ```
    forge test --fork-url FORK_URL
    ```

## Project 1: Impact-Scaled Fee Hook
### Overview
This project implements a hook that scales liquidity provider fees based on the estimated slippage caused by a trade. The idea is to discourage large, slippage-heavy swaps and reduce the incentives for MEV strategies like sandwich attacks.
### Hook Contract ``` ImpactScaledFeeHook.sol ```
- **State variables:**
    - ```depthDenominator``` (per-pool calibration to approximate liquidity depth).
- **Key constants:**
    - ```THRESHOLD_BPS``` = 100 (1%).
    - ```FEE_MULTIPLIER``` = 4 (applies 4× the base fee if threshold is exceeded).
- **Functions:**
    - ```setDepthDenominator(PoolKey, uint256)``` → allows setting the liquidity depth denominator.
    - ```beforeSwap(...)``` → main hook entry point. For exact-in swaps, it computes ```impactBps = amountIn / depth * 10,000```. If above threshold, overrides the fee by multiplying the pool’s base fee. Returns the selector, zero delta, and optional fee override.

### Test Contract: ```ImpactScaledFeeHookTest.sol```
- Local tests validate that:
    - Small swaps below threshold use the base fee.
    - Larger swaps above threshold apply the fee multiplier.
    - Exact-out swaps are ignored (no fee override).
- Fork test:
    - Reads live Uniswap v3 liquidity and price.
    - Calibrates denominator and validates that swaps with >1% impact correctly trigger the fee multiplier.

## Project 2: TWAP-Aware Piecewise Fee Hook
### Overview
This project extends the dynamic fee idea by penalizing only trades that are both large in impact and that push price away from a recent TWAP (Time-Weighted Average Price). The mechanism targets “toxic” or momentum-pushing trades while leaving benign or stabilizing trades unaffected.
### Hook Contract: ```TwapPiecewiseFeeHook.sol```
**State variables:**

```depthDenominator``` (per-pool liquidity proxy).

```twapSqrtPriceX96``` and ```currentSqrtPriceX96``` (stored reference and current prices).

**Key constants:**

```IMPACT_THRESHOLD_BPS``` = 50 (0.5%).

```DEVIATION_THRESHOLD_BPS``` = 50 (0.5%).

```FEE_CAP``` = 20,000 (2%).

**Functions:**

```setDepthDenominator(PoolKey, uint256)``` → calibrates liquidity depth.

```setTwapAndCurrent(PoolKey, uint160 twap, uint160 current)``` → sets TWAP and current sqrt prices.

```beforeSwap(...)``` → computes:
Impact BPS: same as project 1.
Deviation from TWAP: measures whether the trade moves price further away from TWAP.
If both exceed thresholds, applies a piecewise linear fee bump (capped).

```_computeDeviationAwayBps(...)``` → helper function that determines whether the trade moves price away or toward TWAP.

### Test Contract: ```TwapPiecewiseFeeHookTest.sol```
- Local tests:
    - Validate benign trades (toward TWAP) remain at base fee.
    - Validate away-from-TWAP trades with high impact incur fee bumps.
- Fork tests:
    - Use Uniswap v3 oracle to compute live TWAP vs. current price.
    - Force away-from-TWAP conditions and confirm penalization.
    - Validate toward-TWAP trades stay at base fee.


## Project 3: Reentrancy Attack Simulation
### Overview

This project explores Uniswap’s reentrancy protections by attempting to reenter the PoolManager during a swap. It is designed as a security test to ensure that nested calls are blocked.

### Hook Contract: ```ReentrancyAttackHook.sol```

**State variables:**

```poolManager``` (immutable address of PoolManager).

```didReenter``` (tracks if reentry was attempted).

**Functions:**

```getHookPermissions()``` → enables only beforeSwap.

```beforeSwap(...)``` → on first call, tries to perform a nested swap into the PoolManager using low-level .call. Sets didReenter to true to prevent infinite recursion. Always returns selector + zero delta.

### Test Contract: ```ReentrancyAttackForkTest.sol```

Deploys ```ReentrancyAttackHook``` with the BEFORE_SWAP flag.

Initializes a pool with the hook attached.

Attempts a swap, which triggers the hook’s nested swap attempt.

Expected behavior: the PoolManager rejects the reentry and reverts, proving that reentrancy protections are in place.
