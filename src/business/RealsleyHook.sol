// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {HolderOnlyPoolTemplate} from "../templates/HolderOnlyPoolTemplate.sol";
import {ICredential} from "../interfaces/ICredential.sol";

/// @title RealsleyHook
/// @custom:routing AUTOMATIC by its flags. But it reverts swaps from anyone who does not hold the credential,
///                 so a general router finds the pool and can trade on it only for holders.
/// @notice A pool for checked accounts only. Only an account that holds this hook's credential in
///         the registry named at deployment may swap on the pool or add liquidity to it. For an
///         asset that may be held only by people who have passed a check.
/// @dev Built on HolderOnlyPoolTemplate and keeps all of it: a swap whose swapper cannot be
///      established is refused, liquidity comes only through the PositionManager named at
///      deployment and is checked against the position's holder, and removing liquidity is never
///      gated, so someone whose credential is withdrawn can always take their funds out. The
///      registry is asked when the action happens; if it reverts, the swap or deposit reverts.
///      It gates this pool, not the asset: the token can still move anywhere else. Moves no funds.
contract RealsleyHook is HolderOnlyPoolTemplate {
    /// @notice The registry that says who has passed the check.
    ICredential public immutable registry;
    /// @notice The kind of credential an account must hold.
    bytes32 public immutable holderCredential;

    error RegistryHasNoCode();

    constructor(
        IPoolManager poolManager_,
        address[] memory trustedRouters_,
        address positionManager_,
        ICredential registry_,
        bytes32 holderCredential_
    ) HolderOnlyPoolTemplate(poolManager_, trustedRouters_, positionManager_) {
        if (address(registry_).code.length == 0) revert RegistryHasNoCode();
        registry = registry_;
        holderCredential = holderCredential_;
    }

    function _isAllowed(address account, PoolKey calldata) internal view override returns (bool) {
        return registry.hasValidCredential(account, holderCredential);
    }
}
