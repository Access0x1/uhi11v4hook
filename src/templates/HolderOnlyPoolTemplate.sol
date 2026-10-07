// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SwapperIdentity} from "./SwapperIdentity.sol";
import {IPositionOwner} from "./FeesCollectedTemplate.sol";

/// @title HolderOnlyPoolTemplate
/// @custom:routing AUTOMATIC by its flags. But it reverts swaps from anyone who does not hold the credential,
///                 so a general router finds the pool and can trade on it only for holders.
/// @notice Template for a pool only certain people may swap on or add liquidity to: holders of a
///         credential, an NFT, a completed check. A hook built on it writes one function, `_isAllowed`.
/// @dev Two flags, so two bits in the address: beforeAddLiquidity 0x800 | beforeSwap 0x80 = 0x880.
///      Moves no funds and returns no delta.
///      A gate fails closed, the opposite of the fee and receipt templates:
///        - a swap whose swapper cannot be established is refused. That is every swap that does not
///          come through a router trusted at deployment, because only such a router is believed
///          about who called it;
///        - liquidity is accepted only through the PositionManager named at deployment, and only
///          for a position whose NFT is held by someone allowed. The holder is the one checked, not
///          whoever pays: nobody can open a position for a third party who is not allowed;
///        - if `_isAllowed` reverts, the swap or the deposit reverts.
///      Checks are made when the action happens, so an allowance withdrawn takes effect at once.
///      REMOVING liquidity is never gated: someone who loses their allowance can always take their
///      funds out. Donations are not gated either.
///      What it does not do: it knows who called the router and who holds the position, not whose
///      money it is; and a position's NFT can be transferred to someone not allowed, who then holds
///      it and earns its fees but cannot add to it.
abstract contract HolderOnlyPoolTemplate is BaseHook, SwapperIdentity {
    /// @notice The only liquidity caller accepted. Its ERC-721 names each position's holder.
    address public immutable positionManager;

    /// @param swapper address(0) when the swap did not come through a trusted router.
    error SwapperNotAllowed(address swapper);
    /// @param provider address(0) when the liquidity did not come through the PositionManager.
    error LiquidityProviderNotAllowed(address provider);
    error PositionManagerHasNoCode();

    constructor(IPoolManager poolManager_, address[] memory trustedRouters_, address positionManager_)
        BaseHook(poolManager_)
        SwapperIdentity(trustedRouters_)
    {
        if (positionManager_.code.length == 0) revert PositionManagerHasNoCode();
        positionManager = positionManager_;
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.beforeAddLiquidity = true;
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

    /// @dev Runs only for a positive change of liquidity. The PositionManager sets a position's salt
    ///      to its token id and mints the token before it adds the liquidity, so the holder can be
    ///      read here even for a position being opened. If the lookup reverts, so does the deposit.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        if (sender != positionManager) {
            revert LiquidityProviderNotAllowed(address(0));
        }

        address provider = IPositionOwner(positionManager).ownerOf(uint256(params.salt));
        if (!_isAllowed(provider, key)) revert LiquidityProviderNotAllowed(provider);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Whether `account` may swap on, or add liquidity to, this pool now. The one function a
    ///         hook on this template writes.
    /// @dev `account` is never address(0) here. Do NOT wrap an outside call in try/catch and return
    ///      true on failure: for a gate, a check that cannot be made is a refusal.
    function _isAllowed(address account, PoolKey calldata key) internal view virtual returns (bool);
}
