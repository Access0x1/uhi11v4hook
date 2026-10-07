// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {OverrideFeeTemplate} from "../templates/OverrideFeeTemplate.sol";

/// @title RebatoHook
/// @custom:routing MANUAL. Dynamic-fee pools only. Uniswap's interface does not route to it until Uniswap Labs
///                 allowlists its address. The PoolManager itself accepts it.
/// @notice A lower LP fee during a promotion. From `startsAt` until `endsAt` every swap pays
///         `promoFee`; before and after, `baseFee`.
/// @dev Built on OverrideFeeTemplate and keeps all of it: a static-fee pool is refused and every
///      swap carries the override flag. The same fee for every swapper; it reads only the block's
///      timestamp. The window is fixed at deployment and cannot be extended. The saving reaches
///      the swapper inside the swap, as more output; nothing is paid back afterwards. Moves no funds.
contract RebatoHook is OverrideFeeTemplate {
    /// @notice LP fee during the promotion, in pips (1e6 = 100%).
    uint24 public immutable promoFee;
    /// @notice The first second of the promotion.
    uint64 public immutable startsAt;
    /// @notice The first second after the promotion.
    uint64 public immutable endsAt;

    error PromoFeeAboveBaseFee(uint24 promoFee, uint24 baseFee);
    error WindowIsEmpty(uint64 startsAt, uint64 endsAt);

    constructor(
        IPoolManager poolManager_,
        uint24 baseFee_,
        address[] memory trustedRouters_,
        uint24 promoFee_,
        uint64 startsAt_,
        uint64 endsAt_
    ) OverrideFeeTemplate(poolManager_, baseFee_, trustedRouters_) {
        if (promoFee_ > baseFee_) revert PromoFeeAboveBaseFee(promoFee_, baseFee_);
        if (endsAt_ <= startsAt_) revert WindowIsEmpty(startsAt_, endsAt_);
        promoFee = promoFee_;
        startsAt = startsAt_;
        endsAt = endsAt_;
    }

    /// @notice Whether the promotion is running in this block.
    function isOn() public view returns (bool) {
        return block.timestamp >= startsAt && block.timestamp < endsAt;
    }

    function _feeFor(address, PoolKey calldata, SwapParams calldata) internal view override returns (uint24) {
        return isOn() ? promoFee : baseFee;
    }
}
