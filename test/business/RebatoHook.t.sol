// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {RebatoHook} from "../../src/business/RebatoHook.sol";

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract RebatoHookTest is BusinessKit {
    /// @dev beforeInitialize (1 << 13) | beforeSwap (1 << 7), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x2080;
    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant PROMO_FEE = 100;

    RebatoHook internal hook;
    PoolKey internal key;
    uint64 internal startsAt;
    uint64 internal endsAt;

    function setUp() public {
        _kit();
        startsAt = uint64(block.timestamp + 1 days);
        endsAt = startsAt + 7 days;
        hook = RebatoHook(_placeHook(EXPECTED_MASK, _initcode(PROMO_FEE, startsAt, endsAt)));
        key = _dynamicKey(address(hook));
        _open(key);
        _addLiquidity(key);
    }

    function _initcode(uint24 promoFee, uint64 from, uint64 to) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                type(RebatoHook).creationCode, abi.encode(manager, BASE_FEE, _routers(), promoFee, from, to)
            );
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
        _assertRefusedAt(_initcode(PROMO_FEE, startsAt, endsAt), EXPECTED_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
    }

    function test_ThePromoFee_FromItsFirstSecond_ToItsLast_AndTheBaseFeeOtherwise() public {
        assertEq(_feeAt(startsAt - 1), BASE_FEE, "the second before it starts");
        assertEq(_feeAt(startsAt), PROMO_FEE, "its first second");
        assertEq(_feeAt(endsAt - 1), PROMO_FEE, "its last second");
        assertEq(_feeAt(endsAt), BASE_FEE, "the first second after it");
    }

    /// @dev The saving is inside the swap: the same input buys more during the promotion.
    function test_DuringThePromotion_TheSameSwapBuysMore() public {
        uint256 clean = vm.snapshotState();
        (BalanceDelta before,) = _swapVia(router, key, alice, "");
        vm.revertToState(clean);
        vm.warp(startsAt);
        (BalanceDelta during,) = _swapVia(router, key, alice, "");
        assertGt(during.amount1(), before.amount1(), "the promotion did not reach the swapper");
    }

    function test_RevertWhen_ThePromoFeeIsAboveTheBaseFee_OrTheWindowIsEmpty_OrThePoolIsStaticFee() public {
        (bool ok,) = _tryPlace(_initcode(BASE_FEE + 1, startsAt, endsAt), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with a promotion that costs more");
        (ok,) = _tryPlace(_initcode(PROMO_FEE, endsAt, endsAt), _flagAddress(EXPECTED_MASK | (1 << 21)));
        assertFalse(ok, "deployed with a promotion that never runs");
        vm.expectRevert();
        this.open(_staticKey(address(hook)));
    }

    function open(PoolKey memory k) external {
        _open(k);
    }

    function testFuzz_TheFeeIsThePromoFee_ExactlyWhileItIsOn(uint32 offset) public {
        uint256 time = uint256(startsAt) - 2 days + offset % 12 days;
        uint24 fee = _feeAt(time);
        bool on = time >= startsAt && time < endsAt;
        assertEq(hook.isOn(), on, "isOn");
        assertEq(fee, on ? PROMO_FEE : BASE_FEE, "the fee charged");
    }
}
