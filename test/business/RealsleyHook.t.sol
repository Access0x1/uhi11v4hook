// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {RealsleyHook} from "../../src/business/RealsleyHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract RealsleyHookTest is BusinessKit {
    /// @dev beforeAddLiquidity (1 << 11) | beforeSwap (1 << 7), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x880;

    RealsleyHook internal hook;
    PoolKey internal key;

    function setUp() public {
        _kit();
        registry.set(alice, KIND, true); // alice has passed the check; bob has not
        hook = RealsleyHook(_placeHook(EXPECTED_MASK, _initcode(address(registry))));
        key = _staticKey(address(hook));
        _open(key);
        _mint(key, alice, alice);
    }

    function _initcode(address registry_) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(RealsleyHook).creationCode, abi.encode(manager, _routers(), address(posm), registry_, KIND)
        );
    }

    function mintFor(address payer, address owner) external {
        _mint(key, payer, owner);
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(address(registry)), EXPECTED_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
    }

    function test_ACheckedAccountSwaps_AndAnyoneElseIsRefused() public {
        assertFalse(_refused(router, key, alice, -1e15), "a checked account was refused");
        assertTrue(_refused(router, key, bob, -1e15), "an unchecked account swapped");
        assertTrue(_refused(otherRouter, key, alice, -1e15), "a swapper nobody vouched for got through");
    }

    function test_ACredentialWithdrawn_StopsTheNextSwap_ButNeverTheWayOut() public {
        uint256 tokenId = _mint(key, alice, alice);
        registry.set(alice, KIND, false);
        assertTrue(_refused(router, key, alice, -1e15), "swapped after the credential was withdrawn");
        try this.mintFor(alice, alice) {
            fail("added liquidity after the credential was withdrawn");
        } catch {}
        _collect(key, alice, tokenId); // taking funds out is never gated
    }

    /// @dev A gate that cannot check refuses: the opposite of the fee and receipt hooks.
    function test_ARegistryThatReverts_RefusesEverySwap() public {
        registry.setBroken(true);
        assertTrue(_refused(router, key, alice, -1e15), "a swap nobody could check went through");
    }

    function test_NobodyCanOpenAPositionForAnUncheckedAccount() public {
        try this.mintFor(alice, bob) {
            fail("a checked account opened a position for an unchecked one");
        } catch {}
        this.mintFor(bob, alice); // who pays does not matter: the position's holder is the one checked
    }

    function test_RevertWhen_TheRegistryHasNoCode() public {
        (bool ok,) = _tryPlace(_initcode(makeAddr("no code here")), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with a registry that is not a contract");
    }

    function testFuzz_SwappingFollowsTheRegistry(bool aliceHolds, bool bobHolds) public {
        registry.set(alice, KIND, aliceHolds);
        registry.set(bob, KIND, bobHolds);
        assertEq(_refused(router, key, alice, -1e15), !aliceHolds, "alice");
        assertEq(_refused(router, key, bob, -1e15), !bobHolds, "bob");
    }
}
