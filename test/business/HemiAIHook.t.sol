// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {HemiAIHook} from "../../src/business/HemiAIHook.sol";

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract HemiAIHookTest is BusinessKit {
    /// @dev afterSwap (1 << 6), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x40;
    bytes32 internal constant PAYEE = keccak256("an event");

    HemiAIHook internal hook;
    PoolKey internal key;
    uint64 internal opensAt;
    uint64 internal closesAt;

    function setUp() public {
        _kit();
        opensAt = uint64(block.timestamp + 1 days);
        closesAt = opensAt + 3 hours;
        hook = HemiAIHook(_placeHook(EXPECTED_MASK, _initcode(opensAt, closesAt)));
        key = _staticKey(address(hook));
        _open(key);
        _addLiquidity(key);
    }

    function _initcode(uint64 from, uint64 to) internal view returns (bytes memory) {
        return abi.encodePacked(type(HemiAIHook).creationCode, abi.encode(manager, _routers(), from, to));
    }

    function _receiptsAt(uint256 time, bytes32 order) internal returns (uint256) {
        vm.warp(time);
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapVia(router, key, alice, abi.encode(PAYEE, order));
        assertEq(delta.amount0(), -1e15, "the swap did not go through");
        return _count(logs, address(hook), RECEIPT_TOPIC);
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(opensAt, closesAt), EXPECTED_MASK, uint160(Hooks.BEFORE_SWAP_FLAG));
    }

    function test_AReceiptIsWritten_FromTheFirstSecondOfTheWindow_ToItsLast_AndAtNoOtherTime() public {
        assertEq(_receiptsAt(opensAt - 1, "a"), 0, "a receipt before the window opened");
        assertEq(_receiptsAt(opensAt, "b"), 1, "no receipt in the window's first second");
        assertEq(_receiptsAt(closesAt - 1, "c"), 1, "no receipt in the window's last second");
        assertEq(_receiptsAt(closesAt, "d"), 0, "a receipt in the first second after the window");
    }

    function test_RevertWhen_TheWindowIsEmpty() public {
        (bool ok,) = _tryPlace(_initcode(closesAt, closesAt), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with a window that never opens");
    }

    function testFuzz_AtAnyTime_WithAnyHookData_TheSwapGoesThrough(uint32 time, bytes memory hookData) public {
        vm.warp(uint256(opensAt) - 2 days + time);
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapVia(router, key, alice, hookData);
        assertEq(delta.amount0(), -1e15, "the swap did not go through");
        if (!hook.isOpen()) assertEq(_count(logs, address(hook), RECEIPT_TOPIC), 0, "a receipt outside the window");
    }
}
