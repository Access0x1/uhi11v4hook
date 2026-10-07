// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {ColmadoHook} from "../../src/business/ColmadoHook.sol";

import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract ColmadoHookTest is BusinessKit {
    /// @dev beforeInitialize (1 << 13) | beforeSwap (1 << 7), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x2080;
    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant MEMBER_FEE = 500;

    ColmadoHook internal hook;
    PoolKey internal key;

    function setUp() public {
        _kit();
        registry.set(alice, KIND, true); // alice is a regular; bob is not
        hook = ColmadoHook(_placeHook(EXPECTED_MASK, _initcode(address(registry), MEMBER_FEE)));
        key = _dynamicKey(address(hook));
        _open(key);
        _addLiquidity(key);
    }

    function _initcode(address registry_, uint24 memberFee) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(ColmadoHook).creationCode, abi.encode(manager, BASE_FEE, _routers(), registry_, KIND, memberFee)
        );
    }

    function _fee(address who) internal returns (uint24) {
        (, Vm.Log[] memory logs) = _swapVia(router, key, who, "");
        return _feeOf(logs);
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(address(registry), MEMBER_FEE), EXPECTED_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
    }

    function test_ARegularPaysTheMemberFee_AndEveryoneElseTheBaseFee() public {
        assertEq(_fee(alice), MEMBER_FEE, "a regular");
        assertEq(_fee(bob), BASE_FEE, "someone who is not a regular");
    }

    function test_TheFeeFollowsTheRegistry_FromTheNextSwap() public {
        registry.set(alice, KIND, false);
        assertEq(_fee(alice), BASE_FEE, "after the credential was withdrawn");
        registry.set(bob, KIND, true);
        assertEq(_fee(bob), MEMBER_FEE, "after the credential was granted");
    }

    /// @dev Only the trusted router is believed about who is swapping.
    function test_ARegularThroughARouterThatIsNotTrusted_PaysTheBaseFee() public {
        (, Vm.Log[] memory logs) = _swapVia(otherRouter, key, alice, "");
        assertEq(_feeOf(logs), BASE_FEE, "a swapper nobody vouched for was given the member fee");
    }

    function test_ARegistryThatReverts_MeansTheBaseFee_NeverAStoppedSwap() public {
        registry.setBroken(true);
        assertEq(_fee(alice), BASE_FEE, "a fee nobody could check");
    }

    function test_RevertWhen_ThePoolHasAStaticFee() public {
        vm.expectRevert();
        this.open(_staticKey(address(hook)));
    }

    function open(PoolKey memory k) external {
        _open(k);
    }

    function test_RevertWhen_TheMemberFeeIsAboveTheBaseFee_OrTheRegistryHasNoCode() public {
        (bool ok,) = _tryPlace(_initcode(address(registry), BASE_FEE + 1), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with regulars paying more than strangers");
        (ok,) = _tryPlace(_initcode(makeAddr("no code here"), MEMBER_FEE), _flagAddress(EXPECTED_MASK | (1 << 21)));
        assertFalse(ok, "deployed with a registry that is not a contract");
    }

    function testFuzz_TheFeeIsAlwaysOneOfTheTwo(bool aliceHolds, bool bobHolds, bool broken) public {
        registry.set(alice, KIND, aliceHolds);
        registry.set(bob, KIND, bobHolds);
        registry.setBroken(broken);
        assertEq(_fee(alice), aliceHolds && !broken ? MEMBER_FEE : BASE_FEE, "alice");
        assertEq(_fee(bob), bobHolds && !broken ? MEMBER_FEE : BASE_FEE, "bob");
    }
}
