// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {ReentrancyAttackHook} from "../src/ReentrancyAttackHook.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {HookDeployer} from "./utils/HookDeployer.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract ReentrancyAttackForkTest is Test {
    // Common tokens (used only in PoolKey composition)
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Known mainnet PoolManager address (replace if your repo uses a different one)
    // checksummed (preferred)
    address public constant POOL_MANAGER_MAINNET =
        0x000000000004444c5dc75cB358380D2e3dE08A90;

    IPoolManager public pm = IPoolManager(POOL_MANAGER_MAINNET);

    PoolKey public key;
    ReentrancyAttackHook public hook;
    bytes32 public poolId;

    function setUp() public {
        //string memory rpc = vm.envString("MAINNET_RPC_URL");
        string memory rpc = vm.rpcUrl("mainnet");
        uint256 fork = vm.createFork(rpc);
        vm.selectFork(fork);

        (address token0, address token1) = USDC < WETH
            ? (USDC, WETH)
            : (WETH, USDC);
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    /// Initialize pool with hook and try nested-swap reentry during beforeSwap.
    function test_initializePoolWithHook_and_attemptReentry() public {
        // 1) Deploy a hook with the BEFORE_SWAP flag set in its address
        HookDeployer d = new HookDeployer();
        address hookAddr = d.deployWithFlags(
            type(ReentrancyAttackHook).creationCode,
            abi.encode(address(pm)), // constructor args
            Hooks.BEFORE_SWAP_FLAG // required flag
        );
        hook = ReentrancyAttackHook(hookAddr);

        // 2) Put the hook into the PoolKey and initialize
        key.hooks = IHooks(hookAddr);

        bool initOk = true;
        try pm.initialize(key, uint160(1 << 96)) {
            // ok
        } catch (bytes memory reason) {
            initOk = false;
            emit log_bytes(reason);
        }
        if (!initOk) {
            revert("initialize failed (hook flags/return shape not accepted)");
        }

        // 3) Attempt swap (as before). Make sure you’re using the correct signature:
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1),
            sqrtPriceLimitX96: 0
        });

        bool swapped = true;
        try pm.swap(key, params, bytes("")) {
            emit log_string("swap succeeded (unexpected).");
        } catch (bytes memory reason) {
            swapped = false;
            emit log_bytes(reason);
        }

        //pm.swap(key, params, bytes(""));

        assertFalse(
            swapped,
            "Expected nested reentry to be blocked (swap should revert)."
        );
    }
}
