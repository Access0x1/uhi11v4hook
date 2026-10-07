// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SwapperIdentity} from "./SwapperIdentity.sol";
import {FeeOverride} from "./FeeOverride.sol";

/// @title OverrideFeeTemplate
/// @custom:routing MANUAL. Dynamic-fee pools only. Uniswap's interface does not route to a hook built on this
///                 until Uniswap Labs allowlists its address. The PoolManager itself accepts it.
/// @notice Template for a hook that sets the LP fee of each swap by who is swapping. A hook built on
///         it writes one function, `_feeFor`, and inherits everything a fee hook gets wrong silently.
/// @dev Two flags, so two bits in the address: beforeInitialize 0x2000 | beforeSwap 0x80 = 0x2080.
///      Moves no funds and returns no delta. What the template guarantees, whatever `_feeFor` does:
///        - a static-fee pool is refused, because there a fee override is ignored without any error;
///        - every swap carries the override flag, because a dynamic-fee pool starts at fee 0;
///        - a fee the PoolManager would reject is replaced by `baseFee`, so no swap reverts over it;
///        - the swapper is never taken from hookData.
abstract contract OverrideFeeTemplate is BaseHook, SwapperIdentity, FeeOverride {
    constructor(IPoolManager poolManager_, uint24 baseFee_, address[] memory trustedRouters_)
        BaseHook(poolManager_)
        SwapperIdentity(trustedRouters_)
        FeeOverride(baseFee_)
    {}

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        _requireDynamicFee(key);
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = _asOverride(_feeFor(_swapperOf(sender), key, params));
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /// @notice The LP fee, in pips, for a swap by `swapper`. The one function a hook on this template writes.
    /// @dev Must not revert: it runs inside every swap. Wrap any outside call in try/catch and fall
    ///      back to `baseFee`. `swapper` is whatever `_swapperOf` returned for this swap.
    function _feeFor(address swapper, PoolKey calldata key, SwapParams calldata params)
        internal
        view
        virtual
        returns (uint24);
}
