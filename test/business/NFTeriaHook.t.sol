// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {NFTeriaHook} from "../../src/business/NFTeriaHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC721} from "solmate/src/test/utils/mocks/MockERC721.sol";

contract NFTeriaHookTest is BusinessKit {
    /// @dev beforeAddLiquidity (1 << 11) | beforeSwap (1 << 7), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x880;

    NFTeriaHook internal hook;
    MockERC721 internal collection;
    PoolKey internal key;

    function setUp() public {
        _kit();
        collection = new MockERC721("A collection", "COL");
        collection.mint(alice, 1); // alice holds one; bob holds none
        hook = NFTeriaHook(_placeHook(EXPECTED_MASK, _initcode(address(collection))));
        key = _staticKey(address(hook));
        _open(key);
        _mint(key, alice, alice); // the pool's liquidity comes from a holder
    }

    function _initcode(address collection_) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                type(NFTeriaHook).creationCode, abi.encode(manager, _routers(), address(posm), collection_)
            );
    }

    function mintFor(address payer, address owner) external {
        _mint(key, payer, owner);
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(address(collection)), EXPECTED_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
    }

    function test_AHolderSwaps_AndSomeoneWhoHoldsNoneIsRefused() public {
        assertFalse(_refused(router, key, alice, -1e15), "a holder was refused");
        assertTrue(_refused(router, key, bob, -1e15), "someone holding none swapped");
    }

    /// @dev The check is made at the swap: the token moves, and the right to swap moves with it.
    function test_TheRightToSwapFollowsTheToken() public {
        vm.prank(alice);
        collection.transferFrom(alice, bob, 1);
        assertTrue(_refused(router, key, alice, -1e15), "the seller still swapped");
        assertFalse(_refused(router, key, bob, -1e15), "the buyer was refused");
    }

    /// @dev A router the hook was not told to believe says nothing about who is swapping.
    function test_AHolderThroughARouterThatIsNotTrusted_IsRefused() public {
        assertTrue(_refused(otherRouter, key, alice, -1e15), "a swapper nobody vouched for got through");
    }

    function test_LiquidityIsForHoldersToo_AndNobodyCanOpenAPositionForSomeoneWhoHoldsNone() public {
        try this.mintFor(bob, bob) {
            fail("someone holding none added liquidity");
        } catch {}
        try this.mintFor(alice, bob) {
            fail("a holder opened a position for someone holding none");
        } catch {}
        this.mintFor(bob, alice); // who pays does not matter: the position's holder is the one checked
    }

    /// @dev Someone who sells their token can still take their liquidity out.
    function test_RemovingLiquidityIsNeverGated() public {
        uint256 tokenId = _mint(key, alice, alice);
        vm.prank(alice);
        collection.transferFrom(alice, bob, 1);
        _collect(key, alice, tokenId); // a change of liquidity that is not an addition: let through
    }

    function test_RevertWhen_TheCollectionHasNoCode() public {
        (bool ok,) = _tryPlace(_initcode(makeAddr("no code here")), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with a collection that is not a contract");
    }

    function testFuzz_OnlyAnAccountHoldingAtLeastOneTokenSwaps(uint8 held) public {
        held = uint8(bound(held, 0, 5));
        for (uint256 i = 0; i < held; i++) {
            collection.mint(bob, 100 + i);
        }
        assertEq(_refused(router, key, bob, -1e15), held == 0, "holding and swapping disagree");
    }
}
