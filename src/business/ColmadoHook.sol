// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BusinessReceiptHook} from "./BusinessReceiptHook.sol";

/// @title ColmadoHook
/// @custom:routing AUTOMATIC. See BusinessReceiptHook.
/// @notice Colmado's own hook (colmado.click). Local shops selling to the people near them.
/// @dev Today it is BusinessReceiptHook and nothing more: a swap on a Colmado pool that names a
///      payee and an order reference leaves one receipt. What is Colmado's alone goes here.
contract ColmadoHook is BusinessReceiptHook {
    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        BusinessReceiptHook(poolManager_, trustedRouters_)
    {}

    function business() public pure override returns (string memory) {
        return "Colmado";
    }
}
