// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {OverrideFeeTemplate} from "../templates/OverrideFeeTemplate.sol";
import {ICredential} from "../interfaces/ICredential.sol";

/// @title ColmadoHook
/// @custom:routing MANUAL. Dynamic-fee pools only. Uniswap's interface does not route to it until Uniswap Labs
///                 allowlists its address. The PoolManager itself accepts it.
/// @notice A lower LP fee for regulars. A swapper who holds this hook's credential in the registry
///         named at deployment pays `memberFee`; everyone else pays `baseFee`.
/// @dev Built on OverrideFeeTemplate and keeps all of it: a static-fee pool is refused, every swap
///      carries the override flag, and the swapper is whoever a trusted router says called it,
///      never hookData. A swap that does not come through a trusted router has no known swapper
///      and pays `baseFee`. The registry is asked inside the swap, so the call is wrapped: a
///      registry that reverts means `baseFee`, never a stopped swap. Moves no funds.
contract ColmadoHook is OverrideFeeTemplate {
    /// @notice The registry that says who is a regular.
    ICredential public immutable registry;
    /// @notice The kind of credential a regular holds.
    bytes32 public immutable memberCredential;
    /// @notice LP fee for a regular, in pips (1e6 = 100%).
    uint24 public immutable memberFee;

    error RegistryHasNoCode();
    error MemberFeeAboveBaseFee(uint24 memberFee, uint24 baseFee);

    constructor(
        IPoolManager poolManager_,
        uint24 baseFee_,
        address[] memory trustedRouters_,
        ICredential registry_,
        bytes32 memberCredential_,
        uint24 memberFee_
    ) OverrideFeeTemplate(poolManager_, baseFee_, trustedRouters_) {
        // A try/catch around a call to an address without code still reverts.
        if (address(registry_).code.length == 0) revert RegistryHasNoCode();
        if (memberFee_ > baseFee_) revert MemberFeeAboveBaseFee(memberFee_, baseFee_);
        registry = registry_;
        memberCredential = memberCredential_;
        memberFee = memberFee_;
    }

    function _feeFor(address swapper, PoolKey calldata, SwapParams calldata) internal view override returns (uint24) {
        if (swapper == address(0)) return baseFee;
        try registry.hasValidCredential(swapper, memberCredential) returns (bool held) {
            return held ? memberFee : baseFee;
        } catch {
            return baseFee;
        }
    }
}
