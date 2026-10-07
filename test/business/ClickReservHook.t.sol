// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {ClickReservHook} from "../../src/business/ClickReservHook.sol";

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract ClickReservHookTest is BusinessKit {
    /// @dev afterSwap (1 << 6), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x40;
    bytes32 internal constant ORDER = keccak256("order 1");

    ClickReservHook internal hook;
    PoolKey internal key;
    address internal shop = makeAddr("a registered payee");
    address internal unknown = makeAddr("an address nobody registered");

    function setUp() public {
        _kit();
        registry.set(shop, KIND, true);
        hook = ClickReservHook(_placeHook(EXPECTED_MASK, _initcode(address(registry))));
        key = _staticKey(address(hook));
        _open(key);
        _addLiquidity(key);
    }

    function _initcode(address registry_) internal view returns (bytes memory) {
        return abi.encodePacked(type(ClickReservHook).creationCode, abi.encode(manager, _routers(), registry_, KIND));
    }

    function _payee(address who) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(who)));
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(address(registry)), EXPECTED_MASK, uint160(Hooks.BEFORE_SWAP_FLAG));
    }

    function test_ASwapNamingARegisteredPayee_LeavesOneReceipt() public {
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapVia(router, key, alice, abi.encode(_payee(shop), ORDER));
        assertEq(_count(logs, address(hook), RECEIPT_TOPIC), 1, "not exactly one receipt");
        assertEq(delta.amount0(), -1e15, "the swap moved another amount");
        assertTrue(hook.receipted(hook.receiptId(key.toId(), _payee(shop), ORDER, alice)), "not recorded");
    }

    function test_AnUnregisteredPayee_OrOneWhoseRegistrationWasWithdrawn_GetsNoReceipt_AndTheSwapGoesThrough() public {
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapVia(router, key, alice, abi.encode(_payee(unknown), ORDER));
        assertEq(delta.amount0(), -1e15, "the swap was stopped");
        assertEq(_count(logs, address(hook), RECEIPT_TOPIC), 0, "a receipt for an unregistered payee");
        assertEq(_count(logs, address(hook), REFUSED_TOPIC), 1, "the refusal was not said");

        registry.set(shop, KIND, false);
        (, logs) = _swapVia(router, key, alice, abi.encode(_payee(shop), ORDER));
        assertEq(_count(logs, address(hook), RECEIPT_TOPIC), 0, "a receipt after the registration was withdrawn");
    }

    /// @dev 32 bytes that are not an address: something in the top 12 bytes.
    function test_APayeeThatIsNotAnAddress_GetsNoReceipt() public {
        bytes32 notAnAddress = bytes32(uint256(uint160(shop)) | (uint256(1) << 200));
        (, Vm.Log[] memory logs) = _swapVia(router, key, alice, abi.encode(notAnAddress, ORDER));
        assertEq(_count(logs, address(hook), RECEIPT_TOPIC), 0, "a receipt for 32 bytes that are not an address");
    }

    function test_ARegistryThatReverts_MeansNoReceipt_NeverAStoppedSwap() public {
        registry.setBroken(true);
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapVia(router, key, alice, abi.encode(_payee(shop), ORDER));
        assertEq(delta.amount0(), -1e15, "a broken registry stopped the swap");
        assertEq(_count(logs, address(hook), RECEIPT_TOPIC), 0, "a receipt nobody could check");
    }

    function test_RevertWhen_TheRegistryHasNoCode() public {
        (bool ok,) = _tryPlace(_initcode(makeAddr("no code here")), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with a registry that is not a contract");
    }

    function testFuzz_AnyHookData_NeverStopsTheSwap(bytes memory hookData) public {
        (BalanceDelta delta,) = _swapVia(router, key, alice, hookData);
        assertEq(delta.amount0(), -1e15, "the swap did not go through");
    }
}
