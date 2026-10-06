// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title FeeOverride
/// @notice The three things a hook that sets the LP fee per swap gets wrong without any error,
///         as functions a hook calls from its own callbacks. Owns no callback.
abstract contract FeeOverride {
    using LPFeeLibrary for uint24;

    /// @dev At 100% an exact-output swap cannot execute (Pool.sol, InvalidFeeForExactOut).
    uint24 internal constant FEE_CEILING = 1_000_000;

    /// @notice LP fee when the hook's rule has nothing better to say, in pips (1e6 = 100%).
    uint24 public immutable baseFee;

    error FeeTooLarge(uint24 fee);
    error PoolFeeNotDynamic();

    constructor(uint24 baseFee_) {
        if (baseFee_ >= FEE_CEILING) revert FeeTooLarge(baseFee_);
        baseFee = baseFee_;
    }

    /// @dev For beforeInitialize. On a static-fee pool a fee override is ignored without any error.
    function _requireDynamicFee(PoolKey calldata key) internal pure {
        if (!key.fee.isDynamicFee()) revert PoolFeeNotDynamic();
    }

    /// @dev For beforeSwap's third return value. A fee the PoolManager would reject is replaced by
    ///      `baseFee`, and the override flag is always set: a dynamic-fee pool starts at fee 0, so a
    ///      swap without an override would be free.
    function _asOverride(uint24 fee) internal view returns (uint24) {
        if (fee >= FEE_CEILING) fee = baseFee;
        return fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }
}
