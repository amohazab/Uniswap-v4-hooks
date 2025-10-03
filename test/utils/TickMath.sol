// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/TickMath.sol
library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 internal constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342 - 1;

    function getSqrtRatioAtTick(
        int24 tick
    ) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0
                ? uint256(-int256(tick))
                : uint256(int256(tick));
            require(absTick <= uint256(uint24(MAX_TICK)), "T");

            uint256 ratio = absTick & 0x1 != 0
                ? 0xFFFcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0)
                ratio = (ratio * 0xFFF97272373D413259A46990580e213a) >> 128;
            if (absTick & 0x4 != 0)
                ratio = (ratio * 0xFFF2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0)
                ratio = (ratio * 0xFFE5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0)
                ratio = (ratio * 0xFFCB9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0)
                ratio = (ratio * 0xFF973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0)
                ratio = (ratio * 0xFF2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0)
                ratio = (ratio * 0xFE5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0)
                ratio = (ratio * 0xFCbe86c7900a88AEDcffc83b479AA3A4) >> 128;
            if (absTick & 0x200 != 0)
                ratio = (ratio * 0xF987A7253ac413176F2b074CF7815E54) >> 128;
            if (absTick & 0x400 != 0)
                ratio = (ratio * 0xF3392B0822b70005940C7A398e4b70f3) >> 128;
            if (absTick & 0x800 != 0)
                ratio = (ratio * 0xE7159475a2c29B7443B29c7fa6e889D9) >> 128;
            if (absTick & 0x1000 != 0)
                ratio = (ratio * 0xD097f3Bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0)
                ratio = (ratio * 0xA9F746462d870fDF8A65DC1F90e061e5) >> 128;
            if (absTick & 0x4000 != 0)
                ratio = (ratio * 0x70D869A156D2A1B890bb3DF62baf32f7) >> 128;
            if (absTick & 0x8000 != 0)
                ratio = (ratio * 0x31BE135F97D08FD981231505542FCFA6) >> 128;
            if (absTick & 0x10000 != 0)
                ratio = (ratio * 0x9AA508B5b7a84e1C677DE54f3e99BC9) >> 128;
            if (absTick & 0x20000 != 0)
                ratio = (ratio * 0x5D6AF8DEdb81196699C329225ee604) >> 128;
            if (absTick & 0x40000 != 0)
                ratio = (ratio * 0x2216E584F5fa1ea926041BEDfe98) >> 128;
            if (absTick & 0x80000 != 0)
                ratio = (ratio * 0x48A170391f7DC42444E8FA2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            sqrtPriceX96 = uint160(
                (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1)
            );
        }
    }
}
