// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Counter
/// @custom:routing AUTOMATIC. Static-fee pools, no returns-delta flag.
/// @notice Counts three things per pool: swaps about to run, swaps that ran, and liquidity additions
///         about to run. It moves no funds and changes no price or fee.
/// @dev The example hook. Replace it with yours; keep the shape. Three callbacks, so three bits in the address: 0x800 | 0x80 | 0x40 = 0x8C0.
contract Counter is BaseHook {
    /// @notice Times beforeSwap ran in a call that completed, per pool.
    mapping(PoolId => uint256) public beforeSwapCount;

    /// @notice Times afterSwap ran in a call that completed, per pool.
    mapping(PoolId => uint256) public afterSwapCount;

    /// @notice Times beforeAddLiquidity ran in a call that completed, per pool.
    mapping(PoolId => uint256) public beforeAddLiquidityCount;

    /// @dev BaseHook's constructor checks this contract's own address against getHookPermissions()
    ///      and reverts with HookAddressNotValid if the low 14 bits disagree.
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice The callbacks this hook implements. Every flag set here has a function below; a flag
    ///         set without one would revert HookNotImplemented on every swap or deposit of the pool.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeAddLiquidity = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
    }

    /// @dev Runs inside PoolManager.modifyLiquidity before the position changes, and only when the
    ///      liquidity delta is positive. Removing liquidity is a different flag, which this hook
    ///      does not carry.
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        beforeAddLiquidityCount[key.toId()]++;
        return this.beforeAddLiquidity.selector;
    }

    /// @dev Runs inside PoolManager.swap before the pool validates or executes the swap. Returns
    ///      (selector, the hook's own delta, a fee override). The delta is zero and, without the
    ///      beforeSwapReturnDelta bit, is not read. A fee of 0 means no override; an override is
    ///      only honoured on a dynamic-fee pool in any case.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount[key.toId()]++;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Runs inside PoolManager.swap after the pool's price and liquidity have moved.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        afterSwapCount[key.toId()]++;
        return (this.afterSwap.selector, 0);
    }
}
