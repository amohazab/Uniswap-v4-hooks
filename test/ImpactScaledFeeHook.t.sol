// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ImpactScaledFeeHook} from "../src/ImpactScaledFeeHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Pool} from "./utils/IUniswapV3Pool.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract ImpactScaledFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    // Mainnet constants (stable over time)
    address constant V3_WETH_USDC_005 =
        0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    ImpactScaledFeeHook hook;
    address fakePM;

    // Simple v4 pool key pointing to our hook
    function _poolKey(uint24 fee) internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(USDC), // just placeholders for the key
            currency1: Currency.wrap(WETH),
            fee: fee, // e.g., 3000 = 0.30%
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    // ---- Local (no fork) sanity tests ----

    function setUp() public {
        fakePM = address(0xBEEF);
        hook = new ImpactScaledFeeHook(fakePM);
    }

    function test_Local_NoOverride_WhenImpactBelow1Percent() public {
        PoolKey memory key = _poolKey(3000);

        // Calibrate: 1 ETH => 50 bps (so denom = 200 ETH)
        hook.setDepthDenominator(key, 200 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1 ether), // exact in (NEGATIVE)
            sqrtPriceLimitX96: 0
        });

        vm.prank(fakePM);
        (bytes4 sel, , uint24 feeOverride) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );
        assertEq(sel, hook.beforeSwap.selector);
        assertEq(feeOverride, 0, "below 1% -> keep base fee");
    }

    function test_Local_Override_WhenImpactAtLeast1Percent() public {
        PoolKey memory key = _poolKey(3000);

        // 3 ETH / 200 ETH = 150 bps ≥ 100 bps
        hook.setDepthDenominator(key, 200 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(3 ether),
            sqrtPriceLimitX96: 0
        });

        vm.prank(fakePM);
        (, , uint24 feeOverride) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );
        assertEq(feeOverride, 3000 * 4, "higher than 1% -> 4x base fee");
    }

    function test_Local_ExactOut_NoOverride() public {
        PoolKey memory key = _poolKey(3000);
        hook.setDepthDenominator(key, 200 ether);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(3 ether), // exact OUT (POSITIVE)
            sqrtPriceLimitX96: 0
        });

        vm.prank(fakePM);
        (, , uint24 feeOverride) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );
        assertEq(feeOverride, 0);
    }

    // ---- Fork-based calibration from Uniswap v3 ----

    function test_Fork_CalibrateDepthFromV3AndApply() public {
        // 1) Move execution to the fork
        string memory url = vm.rpcUrl("mainnet");
        vm.createSelectFork(url);

        // 2) Read real v3 state
        IUniswapV3Pool pool = IUniswapV3Pool(V3_WETH_USDC_005);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint128 liq = pool.liquidity();

        uint256 denom = uint256(liq) / 1e8; // simple heuristic
        emit log_named_uint("v3.sqrtPriceX96", sqrtPriceX96);
        emit log_named_uint("v3.liquidity", liq);
        emit log_named_uint("depthDenominator (approx)", denom);

        // 3) IMPORTANT: re-deploy the hook on the fork
        // (the instance from setUp() lived on the pre-fork state)
        hook = new ImpactScaledFeeHook(fakePM);

        // 4) Configure and test
        PoolKey memory key = _poolKey(3000);
        hook.setDepthDenominator(key, denom);

        uint256 amountIn = (denom * 150) / 10_000; // ≈150 bps impact

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: 0
        });

        vm.prank(fakePM);
        (, , uint24 feeOverride) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );
        assertEq(
            feeOverride,
            3000 * 4,
            "fork-calibrated denom should trigger surcharge"
        );
    }
}
