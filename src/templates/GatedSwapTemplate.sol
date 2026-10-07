// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title GatedSwapTemplate
/// @custom:routing AUTOMATIC by its flags. But it reverts every swap that does not come from a named executor,
///                 so a general router finds the pool and cannot trade on it.
/// @notice Template for a hook that lets a swap through only from a named executor and only up to a
///         limit. A hook built on it writes `_limitFor`, and `_consume` if the limit is a budget.
/// @dev One flag, so one bit in the address: beforeSwap 0x80. Moves no funds and returns no delta.
///      This is the one template that reverts swaps on purpose; everything else on the pool is left
///      alone: anyone may add or remove liquidity or donate.
///      The limit is on the input a swap REQUESTS. A swap that stops at its price limit uses less
///      than it requested and is still counted in full, so a budget is never exceeded, only
///      under-used.
///      hookData is believed here, unlike in the other templates, because only an executor can get
///      a swap this far: what an executor sends is the executor's word. The executors are therefore
///      part of this hook's security boundary.
abstract contract GatedSwapTemplate is BaseHook {
    /// @notice Contracts that may swap on a pool with this hook. Fixed at deployment.
    mapping(address => bool) public executor;

    error NotAnExecutor(address sender);
    error ExactOutputNotSupported();
    error OverLimit(uint256 requested, uint256 limit);

    constructor(IPoolManager poolManager_, address[] memory executors_) BaseHook(poolManager_) {
        for (uint256 i = 0; i < executors_.length; i++) {
            executor[executors_[i]] = true;
        }
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 requested = _gate(sender, key, params, hookData);
        _consume(sender, key, requested, hookData);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice The most input this swap may request. The one function every hook on this template writes.
    /// @dev Called only for an executor. May read hookData and outside contracts; a revert here
    ///      refuses the swap, which for a gate is the fail-closed outcome.
    function _limitFor(address sender, PoolKey calldata key, bytes calldata hookData)
        internal
        view
        virtual
        returns (uint256);

    /// @notice Runs once the gate has let a swap through, with the input it requested.
    /// @dev Empty by default. A hook whose limit is a budget records the spend here.
    function _consume(address sender, PoolKey calldata key, uint256 requested, bytes calldata hookData)
        internal
        virtual {}

    /// @notice Refuses the swap, by reverting, unless it may go through. Returns the input it requests.
    /// @dev The executor is checked first, so a stranger's swap is refused before `_limitFor` reads
    ///      its hookData or calls any outside contract. An exact-output swap is refused: it names its
    ///      output, and the input it will use is not known until the swap has run. A request of
    ///      exactly the limit is allowed.
    function _gate(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        view
        virtual
        returns (uint256 requested)
    {
        if (!executor[sender]) revert NotAnExecutor(sender);
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();

        requested = uint256(-params.amountSpecified);
        uint256 limit = _limitFor(sender, key, hookData);
        if (requested > limit) revert OverLimit(requested, limit);
    }
}
