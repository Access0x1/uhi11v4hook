// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {FeesCollectedTemplate} from "../templates/FeesCollectedTemplate.sol";

/// @title SebasTNHook
/// @custom:routing AUTOMATIC. No swap callback at all: to a swap this is a pool without a hook.
/// @notice The books of a pool's liquidity providers. Each time a position collects LP fees
///         through the PositionManager named at deployment, the hook adds them to a running
///         total for the position's holder, per pool and per currency, and says so in an event.
/// @dev Built on FeesCollectedTemplate and keeps all of it: it never stops a liquidity change, and
///      a position not held through that PositionManager is skipped. It counts what was
///      collected; it holds nothing, pays nothing and changes no fee. The totals belong to
///      whoever held the position when the fees were collected: a position's NFT can change
///      hands, and fees collected after that count for the new holder. Anyone may read them.
contract SebasTNHook is FeesCollectedTemplate {
    /// @notice pool => account => LP fees collected so far in currency0.
    mapping(PoolId => mapping(address => uint256)) public collected0;
    /// @notice pool => account => LP fees collected so far in currency1.
    mapping(PoolId => mapping(address => uint256)) public collected1;

    event FeesCollected(PoolId indexed poolId, address indexed account, uint256 fees0, uint256 fees1);

    constructor(IPoolManager poolManager_, address positionManager_)
        BaseHook(poolManager_)
        FeesCollectedTemplate(positionManager_)
    {}

    function _onFeesCollected(PoolKey calldata key, address account, uint256 fees0, uint256 fees1) internal override {
        PoolId id = key.toId();
        collected0[id][account] += fees0;
        collected1[id][account] += fees1;
        emit FeesCollected(id, account, fees0, fees1);
    }
}
