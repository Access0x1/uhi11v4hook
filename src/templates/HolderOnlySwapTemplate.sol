// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SwapperIdentity} from "./SwapperIdentity.sol";

/// @title HolderOnlySwapTemplate
/// @notice Template for a pool only certain people may swap on: holders of a credential, an NFT, a
///         completed check. A hook built on it writes one function, `_isAllowed`.
/// @dev One flag, so one bit in the address: beforeSwap 0x80. Moves no funds and returns no delta.
///      A gate fails closed, the opposite of the fee and receipt templates:
///        - a swap whose swapper cannot be established is refused. That is every swap that does not
///          come through a router trusted at deployment, because only such a router is believed
///          about who called it. A wallet cannot swap here through any other route;
///        - if `_isAllowed` reverts, the swap reverts.
///      The check is made when the swap happens, so an allowance withdrawn takes effect at once.
///      Only swaps are gated. Anyone may add or remove liquidity or donate, and a holder may still
///      swap on behalf of someone else: the gate knows who called the router, not whose money it is.
abstract contract HolderOnlySwapTemplate is BaseHook, SwapperIdentity {
    /// @param swapper address(0) when the swap did not come through a trusted router.
    error SwapperNotAllowed(address swapper);

    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        BaseHook(poolManager_)
        SwapperIdentity(trustedRouters_)
    {}

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address swapper = _swapperOf(sender);
        if (swapper == address(0) || !_isAllowed(swapper, key)) revert SwapperNotAllowed(swapper);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Whether `swapper` may swap on this pool now. The one function a hook on this template writes.
    /// @dev `swapper` is never address(0) here. Do NOT wrap an outside call in try/catch and return
    ///      true on failure: for a gate, a check that cannot be made is a refusal.
    function _isAllowed(address swapper, PoolKey calldata key) internal view virtual returns (bool);
}
