// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {HolderOnlyPoolTemplate} from "../templates/HolderOnlyPoolTemplate.sol";

/// @dev The one question asked of the collection.
interface IHasBalance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title NFTeriaHook
/// @custom:routing AUTOMATIC by its flags. But it reverts swaps from anyone who does not hold a token of the
///                 collection, so a general router finds the pool and can trade on it only for holders.
/// @notice A pool for the holders of one collection. Only an account that holds at least one token
///         of the collection named at deployment may swap on the pool or add liquidity to it.
/// @dev Built on HolderOnlyPoolTemplate and keeps all of it: a swap whose swapper cannot be
///      established is refused, liquidity comes only through the PositionManager named at
///      deployment and is checked against the position's holder, and removing liquidity is never
///      gated. The check is made when the action happens: sell the token and the next swap is
///      refused. A token can be lent or bought for one transaction; holding is all this proves.
///      If the collection's `balanceOf` reverts, so does the swap. Moves no funds.
contract NFTeriaHook is HolderOnlyPoolTemplate {
    /// @notice The collection whose holders may use the pool. Any contract with `balanceOf(address)`.
    IHasBalance public immutable collection;

    error CollectionHasNoCode();

    constructor(
        IPoolManager poolManager_,
        address[] memory trustedRouters_,
        address positionManager_,
        IHasBalance collection_
    ) HolderOnlyPoolTemplate(poolManager_, trustedRouters_, positionManager_) {
        if (address(collection_).code.length == 0) revert CollectionHasNoCode();
        collection = collection_;
    }

    function _isAllowed(address account, PoolKey calldata) internal view override returns (bool) {
        return collection.balanceOf(account) != 0;
    }
}
