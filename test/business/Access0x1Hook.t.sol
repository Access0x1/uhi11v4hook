// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {Access0x1Hook} from "../../src/business/Access0x1Hook.sol";

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract Access0x1HookTest is BusinessKit {
    /// @dev afterSwap (1 << 6), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x40;
    bytes32 internal constant PAYEE = keccak256("a payee");
    bytes32 internal constant ORDER = keccak256("order 1");

    Access0x1Hook internal hook;
    PoolKey internal key;

    function setUp() public {
        _kit();
        hook = Access0x1Hook(_placeHook(EXPECTED_MASK, _initcode()));
        key = _staticKey(address(hook));
        _open(key);
        _addLiquidity(key);
    }

    function _initcode() internal view returns (bytes memory) {
        return abi.encodePacked(type(Access0x1Hook).creationCode, abi.encode(manager, _routers()));
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(), EXPECTED_MASK, uint160(Hooks.BEFORE_SWAP_FLAG));
    }

    function test_ASwapNamingAnyPayee_LeavesOneReceipt_UnderTheSwapper() public {
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapVia(router, key, alice, abi.encode(PAYEE, ORDER));
        assertEq(_count(logs, address(hook), RECEIPT_TOPIC), 1, "not exactly one receipt");
        assertEq(delta.amount0(), -1e15, "the swap moved another amount");
        assertTrue(hook.receipted(hook.receiptId(key.toId(), PAYEE, ORDER, alice)), "not recorded under alice");
    }

    function test_NoHookData_IsAnOrdinarySwap_AndAnEmptyPayeeGetsNoReceipt() public {
        (, Vm.Log[] memory plain) = _swapVia(router, key, alice, "");
        assertEq(_count(plain, address(hook), RECEIPT_TOPIC) + _count(plain, address(hook), REFUSED_TOPIC), 0);

        (BalanceDelta delta, Vm.Log[] memory logs) = _swapVia(router, key, alice, abi.encode(bytes32(0), ORDER));
        assertEq(delta.amount0(), -1e15, "a refused receipt stopped the swap");
        assertEq(_count(logs, address(hook), RECEIPT_TOPIC), 0, "a receipt naming nobody");
        assertEq(_count(logs, address(hook), REFUSED_TOPIC), 1, "the refusal was not said");
    }

    function testFuzz_AnyHookData_NeverStopsTheSwap(bytes memory hookData) public {
        (BalanceDelta delta,) = _swapVia(router, key, alice, hookData);
        assertEq(delta.amount0(), -1e15, "the swap did not go through");
        assertGt(delta.amount1(), 0, "the swapper received nothing");
    }
}
