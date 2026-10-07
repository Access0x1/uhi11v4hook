// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookFeePotTemplate} from "../templates/HookFeePotTemplate.sol";

/// @title AllFansHook
/// @custom:routing MANUAL. It returns a delta from both swap callbacks. Uniswap's interface does not route to it
///                 until Uniswap Labs allowlists its address. The PoolManager itself accepts it.
/// @notice A fee on every swap, split 80/20. The hook takes `hookFee` of each swap's input. Of
///         everything taken, 80% is the creator's to withdraw and 20% is the treasury's. Both
///         addresses are fixed at deployment and each can only ever be paid its own share.
/// @dev Built on HookFeePotTemplate, which takes the fee and keeps the books per pool and per
///      currency. The treasury's 20% leaves through the template's `sweep`; the creator's 80%
///      through `payCreator`, added here. Anyone may call either: the money can only go to the
///      address it belongs to, so who presses the button does not matter.
///      The two shares are each rounded down, so together they never exceed what was taken; at
///      most one unit per pool and currency is left behind for good.
///      The fee is on top of the pool's own LP fee and is taken whatever the swap's direction.
contract AllFansHook is HookFeePotTemplate {
    /// @dev The treasury's share of every fee taken: 20%, in pips.
    uint24 internal constant TREASURY_SHARE = 200_000;

    /// @notice Who the other 80% belongs to.
    address public immutable creator;
    /// @notice pool => currency => what has been paid to the creator so far.
    mapping(PoolId => mapping(Currency => uint256)) public paidToCreator;

    event CreatorPaid(PoolId indexed id, Currency indexed currency, uint256 amount);

    error CreatorNotSet();
    error NothingToPay();

    constructor(IPoolManager poolManager_, uint24 hookFee_, address treasury_, address creator_)
        BaseHook(poolManager_)
        HookFeePotTemplate(hookFee_, treasury_, TREASURY_SHARE)
    {
        if (creator_ == address(0)) revert CreatorNotSet();
        creator = creator_;
    }

    /// @notice What the creator can be paid now for this pool and currency.
    /// @dev 80% of everything taken, less what the creator was already paid.
    function owedToCreator(PoolId id, Currency currency) public view returns (uint256) {
        uint256 entitled = FullMath.mulDiv(feesTaken[id][currency], PIPS - TREASURY_SHARE, PIPS);
        uint256 already = paidToCreator[id][currency];
        return entitled > already ? entitled - already : 0;
    }

    /// @notice Pay the creator everything owed for this pool and currency. Anyone may call it.
    function payCreator(PoolId id, Currency currency) external returns (uint256 amount) {
        amount = owedToCreator(id, currency);
        if (amount == 0) revert NothingToPay();
        // The books first, the payment last.
        paidToCreator[id][currency] += amount;
        _spendFromPot(id, currency, amount);
        emit CreatorPaid(id, currency, amount);
        _payOut(creator, currency, amount);
    }
}
