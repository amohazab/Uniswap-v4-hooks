// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract HookDeployer {
    /// Deploy `creationCode || constructorArgs` via CREATE2 at an address
    /// whose bits satisfy the given `flags` mask (e.g., Hooks.BEFORE_SWAP_FLAG).
    function deployWithFlags(
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint160 flags
    ) external returns (address addr) {
        bytes memory init = bytes.concat(creationCode, constructorArgs);
        bytes32 codehash = keccak256(init);

        for (uint256 i = 0; i < type(uint256).max; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                salt,
                                codehash
                            )
                        )
                    )
                )
            );
            // Address must have the desired flag bits set
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == flags) {
                assembly {
                    addr := create2(0, add(init, 32), mload(init), salt)
                    if iszero(extcodesize(addr)) {
                        revert(0, 0)
                    }
                }
                return addr;
            }
        }
        revert("HookDeployer: no salt found");
    }
}
