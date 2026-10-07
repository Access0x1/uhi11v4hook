// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SwapReceiptTemplate} from "../templates/SwapReceiptTemplate.sol";

/// @title HemiAIHook
/// @custom:routing AUTOMATIC. One flag, afterSwap. A swap routed without hookData goes through and leaves no
///                 receipt; a receipt needs a caller that sends the hookData.
/// @notice Receipts inside a window of time. A swap that carries
///         `abi.encode(bytes32 payee, bytes32 orderRef)` leaves one `Receipt` when its block's
///         time is at or after `opensAt` and before `closesAt`. Before and after the window the
///         swap goes through and leaves no receipt.
/// @dev Built on SwapReceiptTemplate and keeps all of it: never reverts a swap, moves no funds,
///      returns no delta, has no owner. The window is fixed at deployment. A receipt therefore
///      proves a swap happened while the window was open, to the precision of a block's
///      timestamp, which its proposer chooses within a few seconds.
contract HemiAIHook is SwapReceiptTemplate {
    /// @notice The first second a receipt is written.
    uint64 public immutable opensAt;
    /// @notice The first second a receipt is no longer written.
    uint64 public immutable closesAt;

    error WindowIsEmpty(uint64 opensAt, uint64 closesAt);

    constructor(IPoolManager poolManager_, address[] memory trustedRouters_, uint64 opensAt_, uint64 closesAt_)
        SwapReceiptTemplate(poolManager_, trustedRouters_)
    {
        if (closesAt_ <= opensAt_) revert WindowIsEmpty(opensAt_, closesAt_);
        opensAt = opensAt_;
        closesAt = closesAt_;
    }

    /// @notice Whether a receipt would be written in this block.
    function isOpen() public view returns (bool) {
        return block.timestamp >= opensAt && block.timestamp < closesAt;
    }

    function _payeeIsValid(bytes32 payee) internal view override returns (bool) {
        return payee != bytes32(0) && isOpen();
    }
}
