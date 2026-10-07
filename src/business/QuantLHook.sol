// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {OverrideFeeTemplate} from "../templates/OverrideFeeTemplate.sol";

/// @title QuantLHook
/// @custom:routing MANUAL. Dynamic-fee pools only. Uniswap's interface does not route to it until Uniswap Labs
///                 allowlists its address. The PoolManager itself accepts it.
/// @notice An LP fee by the day of the week. Monday to Friday (UTC) a swap pays `baseFee`; on
///         Saturday and Sunday it pays `weekendFee`. For a pool of assets whose reference market
///         is closed at the weekend, when liquidity providers carry more risk.
/// @dev Built on OverrideFeeTemplate and keeps all of it: a static-fee pool is refused and every
///      swap carries the override flag. The same fee for every swapper; it reads only the block's
///      timestamp. Day boundaries are midnight UTC and holidays are not known to it. Moves no funds.
contract QuantLHook is OverrideFeeTemplate {
    /// @notice LP fee on Saturday and Sunday (UTC), in pips (1e6 = 100%).
    uint24 public immutable weekendFee;

    constructor(IPoolManager poolManager_, uint24 baseFee_, address[] memory trustedRouters_, uint24 weekendFee_)
        OverrideFeeTemplate(poolManager_, baseFee_, trustedRouters_)
    {
        if (weekendFee_ >= FEE_CEILING) revert FeeTooLarge(weekendFee_);
        weekendFee = weekendFee_;
    }

    /// @notice Whether `timestamp` falls on a Saturday or a Sunday, UTC.
    /// @dev 1 January 1970 was a Thursday, so day 0 is a Thursday: (day + 4) % 7 is 0 on a Sunday
    ///      and 6 on a Saturday.
    function isWeekend(uint256 timestamp) public pure returns (bool) {
        uint256 weekday = (timestamp / 1 days + 4) % 7;
        return weekday == 0 || weekday == 6;
    }

    function _feeFor(address, PoolKey calldata, SwapParams calldata) internal view override returns (uint24) {
        return isWeekend(block.timestamp) ? weekendFee : baseFee;
    }
}
