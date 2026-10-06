// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

/// @title SwapperIdentity
/// @notice The one way the templates here learn who is swapping. Shared, so every hook answers the
///         question the same way.
/// @dev In a hook callback `sender` is the contract that called the PoolManager: a router, never a
///      person. hookData is whatever the caller typed. Neither says who is swapping.
abstract contract SwapperIdentity {
    /// @notice Routers whose `msgSender()` is believed. Fixed at deployment: no owner can add one.
    mapping(address router => bool) public trustedRouter;

    error NotAContract(address target);

    constructor(address[] memory trustedRouters_) {
        for (uint256 i = 0; i < trustedRouters_.length; i++) {
            // A try/catch around a call to an address without code still reverts, and that
            // would stop every swap that came through it.
            if (trustedRouters_[i].code.length == 0) revert NotAContract(trustedRouters_[i]);
            trustedRouter[trustedRouters_[i]] = true;
        }
    }

    /// @notice Who is swapping, given `sender`: the contract that called PoolManager.swap.
    /// @dev Only a router in `trustedRouter` is asked who called it. For any other caller, or a
    ///      trusted router whose answer reverts, nobody is recognised: address(0). A contract that
    ///      forwards other people's swaps is never treated as the swapper. Never reverts.
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
