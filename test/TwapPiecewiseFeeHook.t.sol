// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {TwapPiecewiseFeeHook} from "../src/TwapPiecewiseFeeHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV3Pool} from "./utils/IUniswapV3Pool.sol";
import {TickMath} from "./utils/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract TwapPiecewiseFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    // Mainnet WETH/USDC 0.05% pool & tokens
    address constant V3_WETH_USDC_005 =
        0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    TwapPiecewiseFeeHook hook;
    address fakePM;

    function setUp() public {
        fakePM = address(0xBEEF);
        hook = new TwapPiecewiseFeeHook(fakePM);
    }

    function _poolKey(uint24 fee) internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: fee, // e.g., 3000 = 0.30%
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    // --- LOCAL SANITY TESTS ---

    function test_Local_BenignTowardTWAP_StaysBase() public {
        PoolKey memory key = _poolKey(3000);

        // Depth: make 1 ETH = 50 bps impact (denom=200 ETH)
        hook.setDepthDenominator(key, 200 ether);

        // TWAP 1000, current slightly ABOVE (simulate via sqrt prices)
        // We'll fake sqrt prices by small ratios: 1.01x above => ~100 bps deviation.
        // For simplicity, set twap = now (=> deviation=0), then set trade toward => should be base fee.
        hook.setTwapAndCurrent(key, 2 ** 96, 2 ** 96); // equal sqrt => deviation 0

        SwapParams memory params = SwapParams({
            zeroForOne: true, // price DOWN (toward/away doesn't matter since deviation=0)
            amountSpecified: -int256(1 ether), // exact-in; impact=50 bps (threshold)
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
        // Impact==threshold BUT deviation==0 -> gate fails -> base fee
        assertEq(feeOverride, 0, "benign: keep base fee");
    }

    function test_Local_AwayAndImpactOver_AddsLinearBump() public {
        PoolKey memory key = _poolKey(3000);
        hook.setDepthDenominator(key, 200 ether); // 3 ETH => 150 bps impact

        // Simulate now above TWAP (~+100 bps) so a BUY (oneForZero) would be AWAY.
        // We'll set twapX96 = 2^96, nowX96 = 2^96 * sqrt(1.01) approx:
        uint160 twapX96 = uint160(2 ** 96);
        // multiply by ~1.004987... (sqrt(1.01)) ~ 1.00499
        uint160 nowX96 = uint160((uint256(twapX96) * 1004987) / 1_000_000);

        hook.setTwapAndCurrent(key, twapX96, nowX96);

        // oneForZero = BUY ETH -> price UP => AWAY (since now > twap)
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(3 ether), // impact=150 bps > 50 bps threshold
            sqrtPriceLimitX96: 0
        });

        vm.prank(fakePM);
        (, , uint24 feeOverride) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );
        assertGt(
            feeOverride,
            0,
            "should override above base when away+impact>threshold"
        );
        // Not asserting exact value since linear bump uses integer divisions.
    }

    // --- FORK TEST: use v3 oracle to get a 1-hour TWAP, then apply the rule ---

    function test_Fork_OneHourTWAP_AwayTrade_Penalized() public {
        // select fork from foundry.toml's [rpc_endpoints].mainnet
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        // re-deploy on this fork
        hook = new TwapPiecewiseFeeHook(fakePM);

        // 1) read v3 current sqrt & 1h TWAP
        IUniswapV3Pool pool = IUniswapV3Pool(V3_WETH_USDC_005);
        (uint160 sqrtNow, , , , , , ) = pool.slot0();

        // TWAP over 3600s
        uint32[] memory secs = new uint32[](2);
        secs[0] = 0;
        secs[1] = 3600;
        //uint32[] memory secs = [uint32(0), uint32(3600)];
        (int56[] memory tickCums, ) = pool.observe(secs);
        int56 dtick = tickCums[0] - tickCums[1];
        int24 tickAvg = int24(dtick / int56(uint56(secs[1]))); // floor div OK
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(tickAvg);

        emit log_named_uint("sqrtNow", sqrtNow);
        emit log_named_uint("sqrtTwap(1h)", sqrtTwap);

        // 2) configure hook: depth denom & prices
        PoolKey memory key = _poolKey(3000);

        // Use v3 liquidity as rough guide to set denom (like previous project)
        uint128 liq = pool.liquidity();
        uint256 denom = uint256(liq) / 1e8;
        if (denom == 0) denom = 200 ether; // fallback for safety

        hook.setDepthDenominator(key, denom);
        hook.setTwapAndCurrent(key, sqrtTwap, sqrtNow);

        // 3) choose a trade that (a) has meaningful impact and (b) moves AWAY from TWAP
        // Determine if now > twap; if so, a BUY (oneForZero=false) moves further UP => AWAY.
        bool nowAbove = uint256(sqrtNow) > uint256(sqrtTwap);

        SwapParams memory params = SwapParams({
            zeroForOne: !nowAbove, // if now>twap we set oneForZero=false; else zeroForOne=true
            amountSpecified: -int256((denom * 150) / 10_000), // ~150 bps impact
            sqrtPriceLimitX96: 0
        });

        vm.prank(fakePM);
        (, , uint24 feeOverride) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );
        assertGt(feeOverride, 0, "away+impact over thresholds => penalized");
    }

    function test_Fork_OneHourTWAP_TowardTrade_BaseFee() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        // re-deploy on this fork
        hook = new TwapPiecewiseFeeHook(fakePM);

        IUniswapV3Pool pool = IUniswapV3Pool(V3_WETH_USDC_005);
        (uint160 sqrtNow, , , , , , ) = pool.slot0();

        uint32[] memory secs = new uint32[](2);
        secs[0] = 0;
        secs[1] = 3600;
        //uint32[] memory secs = [uint32(0), uint32(3600)];
        (int56[] memory tickCums, ) = pool.observe(secs);
        int56 dtick = tickCums[0] - tickCums[1];
        int24 tickAvg = int24(dtick / int56(uint56(secs[1])));
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(tickAvg);

        PoolKey memory key = _poolKey(3000);
        uint128 liq = pool.liquidity();
        uint256 denom = uint256(liq) / 1e8;
        if (denom == 0) denom = 200 ether;

        hook = new TwapPiecewiseFeeHook(fakePM); // re-deploy on this fork
        hook.setDepthDenominator(key, denom);
        hook.setTwapAndCurrent(key, sqrtTwap, sqrtNow);

        // TOWARD: if now > twap, a SELL (zeroForOne=true) moves price DOWN toward TWAP
        bool nowAbove = uint256(sqrtNow) > uint256(sqrtTwap);

        SwapParams memory params = SwapParams({
            zeroForOne: nowAbove, // toward move
            amountSpecified: -int256((denom * 150) / 10_000), // same impact
            sqrtPriceLimitX96: 0
        });

        vm.prank(fakePM);
        (, , uint24 feeOverride) = hook.beforeSwap(
            address(this),
            key,
            params,
            ""
        );
        assertEq(feeOverride, 0, "toward TWAP => base fee");
    }
}
