// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BusinessReceiptHook} from "./BusinessReceiptHook.sol";

/// @title ClickReservHook
/// @custom:routing AUTOMATIC. See BusinessReceiptHook.
/// @notice ClickReserv's own hook (reserv.click and clickreserv.com). Bookings, tickets and a page for any local business.
/// @dev Today it is BusinessReceiptHook and nothing more: a swap on a ClickReserv pool that names a
///      payee and an order reference leaves one receipt. What is ClickReserv's alone goes here.
contract ClickReservHook is BusinessReceiptHook {
    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        BusinessReceiptHook(poolManager_, trustedRouters_)
    {}

    function business() public pure override returns (string memory) {
        return "ClickReserv";
    }
}
