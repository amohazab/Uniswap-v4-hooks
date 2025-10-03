// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
//import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/**
 * ReentrancyAttackHook (fork experiment)
 *
 * When PoolManager calls beforeSwap on this hook, the hook will attempt to
 * reenter the PoolManager by calling swap(...) again (nested). Low-level .call
 * is used to capture nested-call behavior without signature mismatches bubbling.
 */
contract ReentrancyAttackHook {
    address public immutable poolManager;
    bool public didReenter;

    constructor(address _poolManager) {
        poolManager = _poolManager;
        didReenter = false;
    }

    // implement the permissions function exactly as your v4-core expects
    function getHookPermissions()
        external
        pure
        returns (Hooks.Permissions memory p)
    {
        // Enable ONLY beforeSwap; everything else false
        p.beforeSwap = true;
        // (all other p.* remain false by default)
    }

    /// beforeSwap hook (matches common Uniswap v4 beforeSwap signature)
    /// We return the selector and an "empty delta" encoded as bytes (the exact shape
    /// may be validated by the real manager; if so, the manager will reject/init will revert).
    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == poolManager, "Not PoolManager");

        if (!didReenter) {
            didReenter = true;

            SwapParams memory nested = SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -int256(1),
                sqrtPriceLimitX96: 0
            });

            // Encode with the **actual** swap signature your IPoolManager has.
            // If it is 3-arg: (key, params, bytes)
            (bool ok, bytes memory ret) = poolManager.call(
                abi.encodeWithSelector(
                    IPoolManager.swap.selector,
                    key,
                    nested,
                    bytes("")
                )
            );
            ok;
            ret;
        }

        // Return correct selector + ZERO_DELTA + no fee override
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
