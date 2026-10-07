// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SwapReceiptTemplate} from "../templates/SwapReceiptTemplate.sol";
import {ICredential} from "../interfaces/ICredential.sol";

/// @title ClickReservHook
/// @custom:routing AUTOMATIC. One flag, afterSwap. A swap routed without hookData goes through and leaves no
///                 receipt; a receipt needs a caller that sends the hookData.
/// @notice Receipts for registered payees. A swap that carries
///         `abi.encode(bytes32 payee, bytes32 orderRef)` leaves one `Receipt`, with what the swap
///         actually moved, when `payee` is an address that holds this hook's credential in the
///         registry named at deployment. Anyone else named gets no receipt; the swap still goes
///         through.
/// @dev Built on SwapReceiptTemplate and keeps all of it: never reverts a swap, moves no funds,
///      returns no delta, has no owner. The payee is an address written as a bytes32 (left-padded
///      with zeros); a value with anything in its top 12 bytes is not an address and is refused.
///      The registry is asked inside the swap, so the call is wrapped: a registry that reverts
///      means no receipt, never a stopped swap.
contract ClickReservHook is SwapReceiptTemplate {
    /// @notice The registry that says who is a registered payee.
    ICredential public immutable registry;
    /// @notice The kind of credential a payee must hold.
    bytes32 public immutable payeeCredential;

    error RegistryHasNoCode();

    constructor(
        IPoolManager poolManager_,
        address[] memory trustedRouters_,
        ICredential registry_,
        bytes32 payeeCredential_
    ) SwapReceiptTemplate(poolManager_, trustedRouters_) {
        // A try/catch around a call to an address without code still reverts.
        if (address(registry_).code.length == 0) revert RegistryHasNoCode();
        registry = registry_;
        payeeCredential = payeeCredential_;
    }

    function _payeeIsValid(bytes32 payee) internal view override returns (bool) {
        if (uint256(payee) >> 160 != 0 || payee == bytes32(0)) return false;
        try registry.hasValidCredential(address(uint160(uint256(payee))), payeeCredential) returns (bool held) {
            return held;
        } catch {
            return false;
        }
    }
}
