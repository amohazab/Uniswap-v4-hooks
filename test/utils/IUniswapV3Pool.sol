// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function liquidity() external view returns (uint128);

    /// @notice Oracle: cumulative tick & seconds-per-liquidity for TWAPs
    /// @param secondsAgos [0, Δt] -> returns cumulative values at now and Δt seconds ago
    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128
        );
}
