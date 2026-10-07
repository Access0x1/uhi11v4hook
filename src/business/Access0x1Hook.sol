// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BusinessReceiptHook} from "./BusinessReceiptHook.sol";

/// @title Access0x1Hook
/// @custom:routing AUTOMATIC. See BusinessReceiptHook.
/// @notice Access0x1's own hook (access0x1.com). The payment rail: prices from Chainlink, receipts on chain.
/// @dev Today it is BusinessReceiptHook and nothing more: a swap on a Access0x1 pool that names a
///      payee and an order reference leaves one receipt. What is Access0x1's alone goes here.
contract Access0x1Hook is BusinessReceiptHook {
    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        BusinessReceiptHook(poolManager_, trustedRouters_)
    {}

    function business() public pure override returns (string memory) {
        return "Access0x1";
    }
}
