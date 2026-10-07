// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BusinessReceiptHook} from "./BusinessReceiptHook.sol";

/// @title AllFansHook
/// @custom:routing AUTOMATIC. See BusinessReceiptHook.
/// @notice AllFans's own hook (allfans.click). Creators verified as human, with an 80/20 split.
/// @dev Today it is BusinessReceiptHook and nothing more: a swap on a AllFans pool that names a
///      payee and an order reference leaves one receipt. What is AllFans's alone goes here.
contract AllFansHook is BusinessReceiptHook {
    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        BusinessReceiptHook(poolManager_, trustedRouters_)
    {}

    function business() public pure override returns (string memory) {
        return "AllFans";
    }
}
