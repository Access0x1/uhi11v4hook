// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {AllFansHook} from "../../src/business/AllFansHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract AllFansHookTest is BusinessKit {
    /// @dev beforeSwap (1 << 7) | afterSwap (1 << 6) | beforeSwapReturnDelta (1 << 3) |
    ///      afterSwapReturnDelta (1 << 2), as a literal.
    uint160 internal constant EXPECTED_MASK = 0xCC;
    uint24 internal constant HOOK_FEE = 10_000; // 1%

    AllFansHook internal hook;
    PoolKey internal key;
    PoolId internal id;
    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        _kit();
        hook = AllFansHook(_placeHook(EXPECTED_MASK, _initcode(creator)));
        key = _staticKey(address(hook));
        id = key.toId();
        _open(key);
        _addLiquidity(key);
    }

    function _initcode(address creator_) internal view returns (bytes memory) {
        return abi.encodePacked(type(AllFansHook).creationCode, abi.encode(manager, HOOK_FEE, treasury, creator_));
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(creator), EXPECTED_MASK, uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
    }

    /// @dev 1% of 1e18 is taken: 1e16. The creator's 80% is 8e15 and the treasury's 20% is 2e15.
    function test_OfEveryFeeTaken_TheCreatorGetsEightyPercent_AndTheTreasuryTwenty() public {
        _swap(key, true, 1e18);
        assertEq(hook.feesTaken(id, currency0), 1e16, "the fee taken");
        assertEq(hook.owedToCreator(id, currency0), 8e15, "owed to the creator");
        assertEq(hook.sweepable(id, currency0), 2e15, "owed to the treasury");

        hook.payCreator(id, currency0);
        hook.sweep(id, currency0);
        assertEq(_bal(currency0, creator), 8e15, "the creator's wallet");
        assertEq(_bal(currency0, treasury), 2e15, "the treasury's wallet");
        assertEq(hook.pot(id, currency0), 0, "something was left in the pot");
    }

    /// @dev Anyone may press the button; the money only ever goes to the address it belongs to.
    function test_AStrangerCanPayTheCreator_ButOnlyTheCreator_AndOnlyOnce() public {
        _swap(key, true, 1e18);
        vm.prank(bob);
        hook.payCreator(id, currency0);
        assertEq(_bal(currency0, creator), 8e15, "the creator was not paid");
        assertEq(hook.owedToCreator(id, currency0), 0, "still owed after being paid");

        vm.prank(bob);
        vm.expectRevert(AllFansHook.NothingToPay.selector);
        hook.payCreator(id, currency0);
    }

    /// @dev Whoever is paid first, each gets only their own share.
    function test_TheOrderOfPaymentDoesNotChangeEitherShare() public {
        _swap(key, true, 1e18);
        hook.sweep(id, currency0);
        hook.payCreator(id, currency0);
        assertEq(_bal(currency0, treasury), 2e15, "the treasury, paid first");
        assertEq(_bal(currency0, creator), 8e15, "the creator, paid second");
    }

    function test_AFeeIsTakenInWhicheverCurrencyGoesIn_AndEachIsItsOwnBook() public {
        _swap(key, false, 1e18); // currency1 in
        assertEq(hook.owedToCreator(id, currency1), 8e15, "currency1");
        assertEq(hook.owedToCreator(id, currency0), 0, "currency0 was credited for a currency1 swap");
    }

    function test_RevertWhen_ThereIsNothingToPay_OrTheCreatorIsNotSet() public {
        vm.expectRevert(AllFansHook.NothingToPay.selector);
        hook.payCreator(id, currency0);
        (bool ok,) = _tryPlace(_initcode(address(0)), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with nobody to pay the 80% to");
    }

    /// @dev Whatever is swapped and however often each is paid: the two never get more than was
    ///      taken, the creator gets exactly their 80% rounded down, and what stays behind is dust.
    function testFuzz_TheTwoSharesNeverExceedWhatWasTaken(uint256 a, uint256 b, bool payBetween) public {
        a = bound(a, 1, 1e17);
        b = bound(b, 1, 1e17);
        _swap(key, true, a);
        if (payBetween && hook.owedToCreator(id, currency0) != 0) hook.payCreator(id, currency0);
        if (payBetween && hook.sweepable(id, currency0) != 0) hook.sweep(id, currency0);
        _swap(key, true, b);
        if (hook.owedToCreator(id, currency0) != 0) hook.payCreator(id, currency0);
        if (hook.sweepable(id, currency0) != 0) hook.sweep(id, currency0);

        uint256 taken = hook.feesTaken(id, currency0);
        uint256 toCreator = _bal(currency0, creator);
        uint256 toTreasury = _bal(currency0, treasury);
        assertEq(toCreator, taken * 8 / 10, "the creator's share is not 80%, rounded down");
        assertEq(toTreasury, taken * 2 / 10, "the treasury's share is not 20%, rounded down");
        assertLe(toCreator + toTreasury, taken, "more was paid out than was taken");
        assertLe(taken - toCreator - toTreasury, 1, "more than one unit was left behind");
        assertEq(hook.pot(id, currency0), taken - toCreator - toTreasury, "the pot does not hold the remainder");
    }
}
