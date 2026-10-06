// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

/// @title OverrideFeeTemplate
/// @notice Template for a hook that sets the LP fee of each swap by who is swapping. A hook built on
///         it writes one function, `_feeFor`, and inherits everything a fee hook gets wrong silently.
/// @dev Two flags, so two bits in the address: beforeInitialize 0x2000 | beforeSwap 0x80 = 0x2080.
///      Moves no funds and returns no delta. What the template guarantees, whatever `_feeFor` does:
///        - a static-fee pool is refused, because there a fee override is ignored without any error;
///        - every swap carries the override flag, because a dynamic-fee pool starts at fee 0;
///        - a fee the PoolManager would reject is replaced by `baseFee`, so no swap reverts over it;
///        - the swapper is never taken from hookData.
abstract contract OverrideFeeTemplate is BaseHook {
    using LPFeeLibrary for uint24;

    /// @dev At 100% an exact-output swap cannot execute (Pool.sol, InvalidFeeForExactOut).
    uint24 internal constant FEE_CEILING = 1_000_000;

    /// @notice LP fee when `_feeFor` has nothing better to say, in pips (1e6 = 100%).
    uint24 public immutable baseFee;

    /// @notice Routers whose `msgSender()` is believed. Fixed at deployment.
    mapping(address router => bool) public trustedRouter;

    error FeeTooLarge(uint24 fee);
    error NotAContract(address target);
    error PoolFeeNotDynamic();

    constructor(IPoolManager poolManager_, uint24 baseFee_, address[] memory trustedRouters_) BaseHook(poolManager_) {
        if (baseFee_ >= FEE_CEILING) revert FeeTooLarge(baseFee_);
        baseFee = baseFee_;
        for (uint256 i = 0; i < trustedRouters_.length; i++) {
            // A try/catch around a call to an address without code still reverts, and that
            // would stop every swap that came through it.
            if (trustedRouters_[i].code.length == 0) revert NotAContract(trustedRouters_[i]);
            trustedRouter[trustedRouters_[i]] = true;
        }
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal virtual override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert PoolFeeNotDynamic();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = _feeFor(_swapperOf(sender), key, params);
        if (fee >= FEE_CEILING) fee = baseFee;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice The LP fee, in pips, for a swap by `swapper`. The one function a hook on this template writes.
    /// @dev Must not revert: it runs inside every swap. Wrap any outside call in try/catch and fall
    ///      back to `baseFee`. `swapper` is whatever `_swapperOf` returned for this swap.
    function _feeFor(address swapper, PoolKey calldata key, SwapParams calldata params)
        internal
        view
        virtual
        returns (uint24);

    /// @notice Who is swapping, given `sender`: the contract that called PoolManager.swap.
    /// @dev `sender` is a router, never a person. Only a router in `trustedRouter` is asked who called
    ///      it. For any other caller, or a trusted router whose answer reverts, nobody is recognised:
    ///      address(0). A contract that forwards other people's swaps is never treated as the swapper.
    function _swapperOf(address sender) internal view virtual returns (address swapper) {
        if (!trustedRouter[sender]) {
            return address(0);
        }
        try IMsgSender(sender).msgSender() returns (address actualSwapper) {
            return actualSwapper;
        } catch {
            return address(0);
        }
    }
}
