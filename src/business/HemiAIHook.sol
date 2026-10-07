// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BusinessReceiptHook} from "./BusinessReceiptHook.sol";

/// @title HemiAIHook
/// @custom:routing AUTOMATIC. See BusinessReceiptHook.
/// @notice HemiAI's own hook (hemiai.click). Brand events, proven on chain.
/// @dev Today it is BusinessReceiptHook and nothing more: a swap on a HemiAI pool that names a
///      payee and an order reference leaves one receipt. What is HemiAI's alone goes here.
contract HemiAIHook is BusinessReceiptHook {
    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        BusinessReceiptHook(poolManager_, trustedRouters_)
    {}

    function business() public pure override returns (string memory) {
        return "HemiAI";
    }
}
