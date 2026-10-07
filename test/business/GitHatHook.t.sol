// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BusinessKit} from "../utils/BusinessKit.sol";
import {GitHatHook} from "../../src/business/GitHatHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract GitHatHookTest is BusinessKit {
    /// @dev beforeSwap (1 << 7), as a literal.
    uint160 internal constant EXPECTED_MASK = 0x80;
    uint256 internal constant MAX_INPUT = 1e16;

    GitHatHook internal hook;
    PoolKey internal key;

    function setUp() public {
        _kit();
        hook = GitHatHook(_placeHook(EXPECTED_MASK, _initcode(_routers(), MAX_INPUT)));
        key = _staticKey(address(hook));
        _open(key);
        _addLiquidity(key); // anyone may add liquidity: only swaps are gated
    }

    function _initcode(address[] memory executors, uint256 maxInput) internal view returns (bytes memory) {
        return abi.encodePacked(type(GitHatHook).creationCode, abi.encode(manager, executors, maxInput));
    }

    function test_Address_MatchesDeclaredPermissions() public view {
        _assertBits(address(hook), EXPECTED_MASK);
    }

    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        _assertRefusedAt(_initcode(_routers(), MAX_INPUT), EXPECTED_MASK, uint160(Hooks.AFTER_SWAP_FLAG));
    }

    function test_ASwapFromANamedExecutor_UpToTheLimit_GoesThrough() public {
        assertFalse(_refused(router, key, alice, -1e15), "a small swap from the executor");
        assertFalse(_refused(router, key, alice, -int256(MAX_INPUT)), "a swap of exactly the limit");
    }

    function test_RevertWhen_TheSwapIsAboveTheLimit_NotFromAnExecutor_OrExactOutput() public {
        assertTrue(_refused(router, key, alice, -int256(MAX_INPUT + 1)), "one unit above the limit");
        assertTrue(_refused(otherRouter, key, alice, -1e15), "a caller that is not an executor");
        assertTrue(_refused(router, key, alice, 1e15), "an exact-output swap, whose input is not known beforehand");
    }

    /// @dev The limit is per swap. It is not a budget, and the test says so.
    function test_TheLimitIsPerSwap_TheSameExecutorMaySwapItAgain() public {
        assertFalse(_refused(router, key, alice, -int256(MAX_INPUT)), "the first");
        assertFalse(_refused(router, key, alice, -int256(MAX_INPUT)), "the second");
    }

    function test_RevertWhen_NoExecutorIsNamed_OrTheLimitIsZero() public {
        (bool ok,) = _tryPlace(_initcode(new address[](0), MAX_INPUT), _flagAddress(EXPECTED_MASK | (1 << 20)));
        assertFalse(ok, "deployed with nobody able to swap");
        (ok,) = _tryPlace(_initcode(_routers(), 0), _flagAddress(EXPECTED_MASK | (1 << 21)));
        assertFalse(ok, "deployed with a limit of nothing");
    }

    function testFuzz_ASwapGoesThrough_ExactlyWhenItRequestsNoMoreThanTheLimit(uint256 amount) public {
        amount = bound(amount, 1, MAX_INPUT * 3);
        assertEq(_refused(router, key, alice, -int256(amount)), amount > MAX_INPUT, "the limit and the gate disagree");
    }
}
