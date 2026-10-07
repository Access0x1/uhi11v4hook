// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {QuantLHook} from "../../src/business/QuantLHook.sol";

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract QuantLHookTest is BusinessKit {
    /// @dev beforeInitialize (1 << 13) | beforeSwap (1 << 7), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x2080;
    uint24 internal constant BASE_FEE = 500;
    uint24 internal constant WEEKEND_FEE = 10_000;

    /// @dev Real dates, from a calendar: 2025-10-10 was a Friday.
    uint256 internal constant FRIDAY_LAST_SECOND = 1760140799; // 2025-10-10 23:59:59 UTC
    uint256 internal constant SATURDAY_FIRST_SECOND = 1760140800; // 2025-10-11 00:00:00 UTC
    uint256 internal constant SUNDAY_LAST_SECOND = 1760313599; // 2025-10-12 23:59:59 UTC
    uint256 internal constant MONDAY_FIRST_SECOND = 1760313600; // 2025-10-13 00:00:00 UTC

    QuantLHook internal hook;
    PoolKey internal key;

    function setUp() public {
        _kit();
        hook = QuantLHook(_placeHook(EXPECTED_MASK, _initcode(WEEKEND_FEE)));
        key = _dynamicKey(address(hook));
        _open(key);
        _addLiquidity(key);
    }

    function _initcode(uint24 weekendFee) internal view returns (bytes memory) {
        return abi.encodePacked(type(QuantLHook).creationCode, abi.encode(manager, BASE_FEE, _routers(), weekendFee));
    }

    function _feeAt(uint256 time) internal returns (uint24) {
        vm.warp(time);
        (, Vm.Log[] memory logs) = _swapVia(router, key, alice, "");
        return _feeOf(logs);
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(WEEKEND_FEE), EXPECTED_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
    }

    function test_TheWeekendFee_FromSaturdaysFirstSecond_ToSundaysLast_UTC() public {
        assertEq(_feeAt(FRIDAY_LAST_SECOND), BASE_FEE, "Friday 23:59:59");
        assertEq(_feeAt(SATURDAY_FIRST_SECOND), WEEKEND_FEE, "Saturday 00:00:00");
        assertEq(_feeAt(SUNDAY_LAST_SECOND), WEEKEND_FEE, "Sunday 23:59:59");
        assertEq(_feeAt(MONDAY_FIRST_SECOND), BASE_FEE, "Monday 00:00:00");
    }

    function test_TheSameFeeForEveryone_ThroughAnyRouter() public {
        vm.warp(SATURDAY_FIRST_SECOND);
        (, Vm.Log[] memory logs) = _swapVia(otherRouter, key, bob, "");
        assertEq(_feeOf(logs), WEEKEND_FEE, "another swapper through another router");
    }

    function test_RevertWhen_ThePoolHasAStaticFee_OrTheWeekendFeeIsAHundredPercent() public {
        vm.expectRevert();
        this.open(_staticKey(address(hook)));
        (bool ok,) = _tryPlace(_initcode(1_000_000), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with a fee no swap can pay");
    }

    function open(PoolKey memory k) external {
        _open(k);
    }

    /// @dev Two of every seven days are the weekend, whichever week it is: checked against the
    ///      four boundaries above, shifted by whole weeks.
    function testFuzz_IsWeekend_RepeatsEverySevenDays(uint16 weeks_, uint32 intoTheWeekend) public view {
        uint256 shift = uint256(weeks_) * 7 days;
        assertFalse(hook.isWeekend(FRIDAY_LAST_SECOND + shift), "a Friday");
        assertTrue(hook.isWeekend(SATURDAY_FIRST_SECOND + shift + (intoTheWeekend % 2 days)), "inside a weekend");
        assertFalse(hook.isWeekend(MONDAY_FIRST_SECOND + shift + (intoTheWeekend % 5 days)), "inside a working week");
    }
}
