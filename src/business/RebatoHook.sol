// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BusinessReceiptHook} from "./BusinessReceiptHook.sol";

/// @title RebatoHook
/// @custom:routing AUTOMATIC. See BusinessReceiptHook.
/// @notice Rebato's own hook (rebato.click). Pay during a promotion's window and get the rebate at once.
/// @dev Today it is BusinessReceiptHook and nothing more: a swap on a Rebato pool that names a
///      payee and an order reference leaves one receipt. What is Rebato's alone goes here.
contract RebatoHook is BusinessReceiptHook {
    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        BusinessReceiptHook(poolManager_, trustedRouters_)
    {}

    function business() public pure override returns (string memory) {
        return "Rebato";
    }
}
