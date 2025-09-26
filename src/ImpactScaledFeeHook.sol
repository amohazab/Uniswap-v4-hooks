// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/**
 * ImpactScaledFeeHook:
 * - Approximates slippage via amountIn / depthDenominator (per-pool).
 * - If impact (bps) >= THRESHOLD_BPS, multiplies LP fee by FEE_MULTIPLIER.
 * - Minimal pattern (no BaseHook) to keep unit tests simple and robust.
 */
contract ImpactScaledFeeHook {
    using PoolIdLibrary for PoolKey;

    address public immutable poolManager;

    // impact threshold and multiplier
    uint16 public constant THRESHOLD_BPS = 100; // 1.00%
    uint24 public constant FEE_MULTIPLIER = 4; // 4× base fee

    // Per-pool "depth" denominator (token-in units)
    mapping(PoolId => uint256) public depthDenominator;

    constructor(address _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Configure per-pool depth denominator (admin/test helper)
    function setDepthDenominator(PoolKey calldata key, uint256 denom) external {
        depthDenominator[key.toId()] = denom;
    }

    /// Signature matches v4 IHooks.beforeSwap to stay plug-in compatible later
    function beforeSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    ) external returns (bytes4, BeforeSwapDelta, uint24 lpFeeOverride) {
        require(msg.sender == poolManager, "Not PoolManager");
        uint24 feeOverride = 0;

        // In this v4 snapshot: exact IN => amountSpecified < 0
        if (params.amountSpecified < 0) {
            uint256 amountIn = uint256(-params.amountSpecified);
            uint256 denom = depthDenominator[key.toId()];
            if (denom > 0) {
                uint256 impactBps = (amountIn * 10_000) / denom; // linear proxy
                if (impactBps >= THRESHOLD_BPS) {
                    feeOverride = key.fee * FEE_MULTIPLIER;
                }
            }
        }

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeOverride
        );
    }
}
