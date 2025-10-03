// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/**
 * TWAP-aware, piecewise dynamic fee hook (unit-test friendly).
 *
 * Intuition:
 * - Compute two signals per swap:
 *   1) impact_bps ≈ amountIn / depth * 10_000  (depth is a per-pool proxy you set)
 *   2) deviation_away_bps = |Pnow - PTWAP|/PTWAP * 10_000 if trade pushes price AWAY from TWAP; else 0
 * - If BOTH signals exceed thresholds, add a linear fee bump above the pool's base fee (capped).
 *
 * Notes:
 * - To keep this minimal and robust in tests, we don't inherit BaseHook here.
 * - Tests (including fork) set: depth, TWAP sqrt price, and current sqrt price through setters.
 * - In production, you'd source TWAP/current price via an oracle/keeper and/or switch to BaseHook.
 */
contract TwapPiecewiseFeeHook {
    using PoolIdLibrary for PoolKey;

    // --- Config ---
    address public immutable poolManager;

    // Thresholds (in basis points, i.e., 1% = 100 bps)
    uint16 public constant IMPACT_THRESHOLD_BPS = 50; // 0.50%
    uint16 public constant DEVIATION_THRESHOLD_BPS = 50; // 0.50%

    // Fee params (Uniswap fee units: 3000 = 0.30%)
    uint24 public constant FEE_CAP = 20_000; // 2.00% cap
    // Linear slope: +1 basis point of fee per 10 bps of impact above threshold
    // (You can tune this in code later if desired.)
    uint16 public constant SLOPE_IMPACT_PER_10BPS = 1; // => +0.01% per 100 bps over threshold
    // Deviation gates the rule here (no linear add from deviation for simplicity)

    // --- Per-pool state ---
    // Depth denominator (token-in units); you set per pool
    mapping(PoolId => uint256) public depthDenominator;

    // Stored prices for deviation calculation (set by tests/keeper)
    mapping(PoolId => uint160) public twapSqrtPriceX96; // Q64.96
    mapping(PoolId => uint160) public currentSqrtPriceX96; // Q64.96

    constructor(address _poolManager) {
        poolManager = _poolManager;
    }

    // --- Admin/Test setters (no access control here for brevity) ---

    function setDepthDenominator(PoolKey calldata key, uint256 denom) external {
        depthDenominator[key.toId()] = denom;
    }

    function setTwapAndCurrent(
        PoolKey calldata key,
        uint160 twapX96,
        uint160 currentX96
    ) external {
        twapSqrtPriceX96[key.toId()] = twapX96;
        currentSqrtPriceX96[key.toId()] = currentX96;
    }

    // --- Hook entrypoint (matches IHooks.beforeSwap signature) ---

    function beforeSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    ) external returns (bytes4, BeforeSwapDelta, uint24 lpFeeOverride) {
        require(msg.sender == poolManager, "Not PoolManager");

        // 1) impact_bps
        uint256 impactBps = 0;
        if (params.amountSpecified < 0) {
            uint256 amountIn = uint256(-params.amountSpecified); // exact-in in this v4 snapshot
            uint256 denom = depthDenominator[key.toId()];
            if (denom > 0) {
                impactBps = (amountIn * 10_000) / denom;
            }
        }
        // 2) deviation_away_bps (gates the rule)
        uint256 deviationAwayBps = _computeDeviationAwayBps(
            key,
            params.zeroForOne
        );

        uint24 feeOverride = 0;
        if (
            impactBps >= IMPACT_THRESHOLD_BPS &&
            deviationAwayBps >= DEVIATION_THRESHOLD_BPS
        ) {
            // piecewise linear bump from impact above threshold
            uint256 over = impactBps - IMPACT_THRESHOLD_BPS;
            // +1 bp of fee per 10 bps of "over" (tunable)
            uint256 addFeeBps = (over / 10) * SLOPE_IMPACT_PER_10BPS;

            uint256 newFee = uint256(key.fee) + addFeeBps * 100; // 1 bp = 100 in Uniswap fee units
            if (newFee > FEE_CAP) newFee = FEE_CAP;
            feeOverride = uint24(newFee);
        }

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeOverride
        );
    }

    // --- Helpers ---

    /// @dev Returns deviation (bps) if trade pushes price AWAY from TWAP; else 0.
    function _computeDeviationAwayBps(
        PoolKey calldata key,
        bool zeroForOne
    ) internal view returns (uint256) {
        uint160 twapX96 = twapSqrtPriceX96[key.toId()];
        uint160 nowX96 = currentSqrtPriceX96[key.toId()];
        if (twapX96 == 0 || nowX96 == 0) return 0;

        // ratio r = now / twap in Q64.64
        // rQ64 = (nowX96 << 64) / twapX96
        uint256 rQ64 = (uint256(nowX96) << 64) / uint256(twapX96);

        // price ratio ≈ r^2. Compare r^2 versus 1.0 to get |Pnow/PTWAP - 1|
        // r2Q64 = (rQ64 * rQ64) >> 64
        uint256 r2Q64 = (rQ64 * rQ64) >> 64;

        // deviation_bps = |r2 - 1| * 10_000
        uint256 oneQ64 = 1 << 64;
        uint256 devQ64 = r2Q64 > oneQ64 ? (r2Q64 - oneQ64) : (oneQ64 - r2Q64);
        uint256 deviationBps = (devQ64 * 10_000) / oneQ64;

        // Determine trade's price move direction:
        // In Uniswap, zeroForOne => price decreases; oneForZero => price increases.
        bool tradeMovesDown = zeroForOne;
        bool tradeMovesUp = !zeroForOne;

        // Is current above or below TWAP?
        bool nowAbove = rQ64 > oneQ64; // now/twap > 1

        // Away logic:
        // - if nowAbove and trade would push UP => away
        // - if nowBelow and trade would push DOWN => away
        bool away = (nowAbove && tradeMovesUp) || (!nowAbove && tradeMovesDown);

        return away ? deviationBps : 0;
    }
}
