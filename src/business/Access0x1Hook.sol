// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SwapReceiptTemplate} from "../templates/SwapReceiptTemplate.sol";

/// @title Access0x1Hook
/// @custom:routing AUTOMATIC. One flag, afterSwap. A swap routed without hookData goes through and leaves no
///                 receipt; a receipt needs a caller that sends the hookData.
/// @notice Open receipts. A swap that carries `abi.encode(bytes32 payee, bytes32 orderRef)` leaves
///         one `Receipt` with what the swap actually moved, for any payee but the empty one.
/// @dev Built on SwapReceiptTemplate and keeps all of it: never reverts a swap, moves no funds,
///      returns no delta, has no owner and no list. Which payee ids mean something is for the
///      reader of the receipts to say.
contract Access0x1Hook is SwapReceiptTemplate {
    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        SwapReceiptTemplate(poolManager_, trustedRouters_)
    {}

    function _payeeIsValid(bytes32 payee) internal pure override returns (bool) {
        return payee != bytes32(0);
    }
}
