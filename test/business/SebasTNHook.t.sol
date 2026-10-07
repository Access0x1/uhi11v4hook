// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {SebasTNHook} from "../../src/business/SebasTNHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract SebasTNHookTest is BusinessKit {
    /// @dev afterAddLiquidity (1 << 10) | afterRemoveLiquidity (1 << 8), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x500;

    SebasTNHook internal hook;
    PoolKey internal key;
    PoolId internal id;
    uint256 internal aliceToken;

    function setUp() public {
        _kit();
        hook = SebasTNHook(_placeHook(EXPECTED_MASK, _initcode(address(posm))));
        key = _staticKey(address(hook));
        id = key.toId();
        _open(key);
        aliceToken = _mint(key, alice, alice);
    }

    function _initcode(address positionManager) internal view returns (bytes memory) {
        return abi.encodePacked(type(SebasTNHook).creationCode, abi.encode(manager, positionManager));
    }

    function _balance(Currency c, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _swapBothWays(uint256 amount) internal {
        _swap(key, true, amount);
        _swap(key, false, amount);
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(address(posm)), EXPECTED_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
    }

    function test_FeesAPositionCollects_AreAddedToItsHoldersTotal_ToTheUnit() public {
        _swapBothWays(1e18);
        (uint256 before0, uint256 before1) = (_balance(currency0, alice), _balance(currency1, alice));
        _collect(key, alice, aliceToken);
        uint256 got0 = _balance(currency0, alice) - before0;
        uint256 got1 = _balance(currency1, alice) - before1;

        assertGt(got0 + got1, 0, "no fees were earned");
        assertEq(hook.collected0(id, alice), got0, "currency0: the books and the wallet disagree");
        assertEq(hook.collected1(id, alice), got1, "currency1: the books and the wallet disagree");
    }

    function test_TheTotalRuns_AndEachHolderHasTheirOwn() public {
        uint256 bobToken = _mint(key, bob, bob);
        _swapBothWays(1e18);
        _collect(key, alice, aliceToken);
        uint256 first = hook.collected0(id, alice);
        _swapBothWays(1e18);
        _collect(key, alice, aliceToken);
        assertGt(hook.collected0(id, alice), first, "the second collection was not added");

        assertEq(hook.collected0(id, bob), 0, "bob was credited before collecting");
        _collect(key, bob, bobToken);
        assertGt(hook.collected0(id, bob), 0, "bob's fees were not counted");
    }

    /// @dev Liquidity added by another route is not stopped, and is not counted.
    function test_APositionNotHeldThroughThePositionManager_IsLeftAlone() public {
        _addLiquidity(key);
        _swapBothWays(1e18);
        _addLiquidity(key); // collects that position's fees: no revert, and nobody is credited
        assertEq(hook.collected0(id, address(this)), 0, "a position outside the PositionManager was counted");
    }

    function test_RevertWhen_ThePositionManagerHasNoCode() public {
        (bool ok,) = _tryPlace(_initcode(makeAddr("no code here")), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with a PositionManager that is not a contract");
    }

    function testFuzz_TheBooksEqualWhatTheHolderReceived(uint256 amount, uint8 rounds) public {
        amount = bound(amount, 1e12, 1e18);
        rounds = uint8(bound(rounds, 1, 4));
        uint256 total0;
        uint256 total1;
        for (uint256 i = 0; i < rounds; i++) {
            _swapBothWays(amount);
            (uint256 before0, uint256 before1) = (_balance(currency0, alice), _balance(currency1, alice));
            _collect(key, alice, aliceToken);
            total0 += _balance(currency0, alice) - before0;
            total1 += _balance(currency1, alice) - before1;
        }
        assertEq(hook.collected0(id, alice), total0, "currency0");
        assertEq(hook.collected1(id, alice), total1, "currency1");
    }
}
