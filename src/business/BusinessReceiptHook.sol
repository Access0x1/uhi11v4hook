// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SwapReceiptTemplate} from "../templates/SwapReceiptTemplate.sol";

/// @title BusinessReceiptHook
/// @custom:routing AUTOMATIC. One flag, afterSwap; no returns-delta and no dynamic fee. A swap routed
///                 without hookData goes through and leaves no receipt.
/// @notice What every business hook in this folder is, today: a pool whose swaps can leave a
///         receipt. A swap that names a payee and an order reference in its hookData gets one
///         `Receipt` event, carrying what the swap actually moved. That is all it does.
/// @dev Deliberately the least a hook can do and still be worth deploying. Everything below is
///      SwapReceiptTemplate's guarantee, unchanged:
///        - it never reverts a swap, moves no funds, returns no delta, changes no price or fee;
///        - it has no owner, no settings and no upgrade path;
///        - the payer on a receipt comes from a trusted router or is empty, never from hookData.
///      The one rule added here: a receipt must name someone. Which payee ids mean something is
///      the business's own app's to say; the hook does not keep a list.
///
///      Each business has its own contract so that each has its own address and its own pools,
///      and so that a business can grow its own behaviour later without touching the others.
///      Until one does, they are the same code, proven once in test/BusinessHooks.t.sol.
abstract contract BusinessReceiptHook is SwapReceiptTemplate {
    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        SwapReceiptTemplate(poolManager_, trustedRouters_)
    {}

    /// @notice The business this hook belongs to, as it writes its own name.
    function business() public pure virtual returns (string memory);

    /// @dev Any payee but the empty one. Cannot revert.
    function _payeeIsValid(bytes32 payee) internal pure override returns (bool) {
        return payee != bytes32(0);
    }
}
