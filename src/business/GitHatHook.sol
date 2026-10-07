// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {GatedSwapTemplate} from "../templates/GatedSwapTemplate.sol";

/// @title GitHatHook
/// @custom:routing AUTOMATIC by its flags. But it reverts every swap that does not come from a named executor,
///                 so a general router finds the pool and cannot trade on it.
/// @notice A pool only named programs may trade on, each swap up to a fixed size. A swap is let
///         through only when it comes from an executor named at deployment and requests at most
///         `maxInput` of the input currency.
/// @dev Built on GatedSwapTemplate and keeps all of it: exact-output swaps are refused, a request
///      of exactly the limit is allowed, and liquidity and donations are open to anyone. The limit
///      is per swap, not a budget: an executor may swap `maxInput` again in the next call. The
///      executors and the limit are fixed at deployment. Moves no funds.
contract GitHatHook is GatedSwapTemplate {
    /// @notice The most input one swap may request, in the input currency's smallest unit.
    uint256 public immutable maxInput;

    error NoExecutors();
    error LimitIsZero();

    constructor(IPoolManager poolManager_, address[] memory executors_, uint256 maxInput_)
        GatedSwapTemplate(poolManager_, executors_)
    {
        if (executors_.length == 0) revert NoExecutors();
        if (maxInput_ == 0) revert LimitIsZero();
        maxInput = maxInput_;
    }

    function _limitFor(address, PoolKey calldata, bytes calldata) internal view override returns (uint256) {
        return maxInput;
    }
}
