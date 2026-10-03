// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {Counter} from "../src/Counter.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Test-only. Declares beforeSwap and implements nothing: the mistake the second law names.
contract DeclaresBeforeSwapImplementsNothing is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
    }
}

contract CounterTest is HookTestBase {
    /// @dev The mask this hook must carry, as a literal: beforeAddLiquidity (1 << 11) | beforeSwap
    ///      (1 << 7) | afterSwap (1 << 6). Written out so the test does not take its expectation
    ///      from the code it is checking.
    uint160 internal constant EXPECTED_MASK = 0x8C0;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    ///
    ///      Sabotaged once, 2026-10-01: with BEFORE_ADD_LIQUIDITY_FLAG left out (0xC0) the whole
    ///      suite failed in setUp() with HookAddressNotValid(0x4444...00C0). To repeat the sabotage,
    ///      delete that flag from this line and run `make test`.
    uint160 internal constant PLACED_FLAGS =
        uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    Counter internal hook;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        _deployV4();

        address where = _flagAddress(PLACED_FLAGS);
        _place(abi.encodePacked(type(Counter).creationCode, abi.encode(manager)), where);
        hook = Counter(where);

        key = _initPool(IHooks(where));
        id = key.toId();
        _addLiquidity(key); // the one liquidity addition every test starts with
    }

    function _assertCounts(uint256 beforeSwap, uint256 afterSwap, uint256 beforeAdd, string memory when) internal view {
        assertEq(hook.beforeSwapCount(id), beforeSwap, string.concat("beforeSwapCount ", when));
        assertEq(hook.afterSwapCount(id), afterSwap, string.concat("afterSwapCount ", when));
        assertEq(hook.beforeAddLiquidityCount(id), beforeAdd, string.concat("beforeAddLiquidityCount ", when));
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "hook declares something other than the three callbacks");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0x8C0 in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage. Two of the three bits are right; that is not enough.
    function test_RevertWhen_PlacedAtAddressMissingOneFlag() public {
        address wrong = _flagAddress(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));

        (bool ok, bytes memory ret) =
            _tryPlace(abi.encodePacked(type(Counter).creationCode, abi.encode(manager)), wrong);

        assertFalse(ok, "constructor accepted an address without the beforeAddLiquidity bit");
        assertEq(bytes4(ret), Hooks.HookAddressNotValid.selector, "reverted, but not for the address");
    }

    // ── 2. each callback fires where its flag says ───────────────────────────────────────────

    function test_Swap_FiresBeforeAndAfter_OnceEach() public {
        _assertCounts(0, 0, 1, "after setUp");

        _swap(key, true, 1e15);
        _assertCounts(1, 1, 1, "after one swap");

        _swap(key, false, 1e15);
        _assertCounts(2, 2, 1, "after a swap in the other direction");
    }

    function test_AddLiquidity_IsCounted_RemoveLiquidity_IsNot() public {
        _addLiquidity(key);
        _assertCounts(0, 0, 2, "after a second addition");

        // Removing is beforeRemoveLiquidity, a flag this hook's address does not carry.
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -LIQUIDITY, salt: bytes32(0)
            }),
            ""
        );
        _assertCounts(0, 0, 2, "after a removal");
    }

    // ── 3. what a count does and does not include ────────────────────────────────────────────

    /// @dev Called through `this.` so the revert can be caught and read.
    function swapWithLimit(uint160 sqrtPriceLimitX96) external {
        _swap(key, true, 1e15, sqrtPriceLimitX96);
    }

    /// @dev beforeSwap runs BEFORE the pool looks at the swap. Here the pool then rejects it: a
    ///      zeroForOne swap pushes the price down, and this limit sits above the current price.
    ///      The hook ran and incremented; the revert takes the increment with it.
    function test_SwapThePoolRejects_RanBeforeSwap_ButIsNotCounted() public {
        uint160 limitAbovePrice = TickMath.getSqrtPriceAtTick(1);

        try this.swapWithLimit(limitAbovePrice) {
            fail("the pool was expected to reject this swap");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), Pool.PriceLimitAlreadyExceeded.selector, "rejected, but not for the price limit");
        }
        _assertCounts(0, 0, 1, "after a rejected swap");
    }

    function testFuzz_RevertWhen_CallerIsNotPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1, salt: bytes32(0)});

        vm.startPrank(caller);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(caller, key, swapParams, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(caller, key, swapParams, BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(caller, key, addParams, "");
        vm.stopPrank();

        _assertCounts(0, 0, 1, "after three calls from someone other than the PoolManager");
    }

    // ── 4. the second law: declare only what you implement ───────────────────────────────────

    /// @dev A hook whose address says beforeSwap and whose code has no _beforeSwap. The pool
    ///      initialises and takes liquidity without complaint. Every swap then reverts, and the
    ///      PoolManager wraps the hook's own error so the caller can see who failed and why.
    function test_DeclaredButUnimplementedCallback_RevertsEverySwap() public {
        address where = _flagAddress(uint160(Hooks.BEFORE_SWAP_FLAG) | (uint160(1) << 20));
        _place(abi.encodePacked(type(DeclaresBeforeSwapImplementsNothing).creationCode, abi.encode(manager)), where);

        PoolKey memory broken = _initPool(IHooks(where));
        _addLiquidity(broken);

        try this.swapOn(broken) {
            fail("a swap went through a hook with no beforeSwap");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "not the PoolManager's wrapped hook error");
            (address target, bytes4 called, bytes memory inner, bytes memory context) =
                abi.decode(_withoutSelector(reason), (address, bytes4, bytes, bytes));
            assertEq(target, where, "the wrapped error names another contract");
            assertEq(called, IHooks.beforeSwap.selector, "the wrapped error names another callback");
            assertEq(bytes4(inner), BaseHook.HookNotImplemented.selector, "the hook failed for another reason");
            assertEq(bytes4(context), Hooks.HookCallFailed.selector, "the PoolManager added other context");
        }
    }

    function swapOn(PoolKey memory k) external {
        _swap(k, true, 1e15);
    }

    function _withoutSelector(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    // ── 4b. three properties every v4 hook has, proven once here ──

    /// @dev Why the permissions test comes first. vm.etch copies only the RUNTIME code, so the
    ///      constructor's address check never runs: the same hook now sits at an address whose
    ///      bits say beforeDonate. The pool initialises, the swap succeeds, nothing reverts, and
    ///      nothing is counted. A flag/address mismatch fails silently.
    function test_WrongAddressWithoutConstructorCheck_FailsSilently() public {
        address silent = _flagAddress(uint160(Hooks.BEFORE_DONATE_FLAG) | (uint160(1) << 20));
        vm.etch(silent, address(hook).code);

        PoolKey memory silentKey = _initPool(IHooks(silent));
        _addLiquidity(silentKey);
        _swap(silentKey, true, 1e15);

        assertEq(Counter(silent).beforeSwapCount(silentKey.toId()), 0, "beforeSwap fired; expected silence");
        assertEq(Counter(silent).afterSwapCount(silentKey.toId()), 0, "afterSwap fired; expected silence");
    }

    error RevertedAfterTheSwapCounted();

    /// @dev Called through `this.` so it runs in its own call frame, which then reverts as a whole.
    function swapThenRevert() external {
        _swap(key, true, 1e15);
        if (hook.afterSwapCount(id) == 1) revert RevertedAfterTheSwapCounted();
    }

    /// @dev A swap that completed inside a call frame that later reverts is not counted: the
    ///      increments revert with the frame. Different from a swap the POOL rejects (above).
    function test_SwapInAFrameThatLaterReverts_IsNotCounted() public {
        try this.swapThenRevert() {
            fail("the helper was expected to revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), RevertedAfterTheSwapCounted.selector, "reverted before the swap was counted");
        }
        _assertCounts(0, 0, 1, "after a reverted frame");
    }

    /// @dev The hook binds no pool. A stranger opens a second pool on the same pair; it names
    ///      the same hook and gets counters of its own.
    function test_AnyoneCanAttachAPool_EachPoolCountsAlone() public {
        PoolKey memory other = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        vm.prank(makeAddr("stranger"));
        manager.initialize(other, TickMath.getSqrtPriceAtTick(0));
        _addLiquidity(other);

        _swap(other, true, 1e15);
        assertEq(hook.afterSwapCount(other.toId()), 1, "the second pool's swap was not counted");
        _assertCounts(0, 0, 1, "on the first pool after a swap on the second");
    }

    // ── 5. fuzz ──────────────────────────────────────────────────────────────────────────────

    /// @dev Upper bound: LIQUIDITY of 100e18 across +-120 ticks holds about 6e17 of each token, so
    ///      up to five swaps of at most 1e17, alternating direction, always stay inside the band.
    function testFuzz_EveryCompletedSwapCountsOnceBeforeAndOnceAfter(uint256 amountIn, uint8 swaps, bool firstDirection)
        public
    {
        amountIn = bound(amountIn, 1, 1e17);
        uint256 n = bound(swaps, 1, 5);

        bool zeroForOne = firstDirection;
        for (uint256 i = 0; i < n; i++) {
            _swap(key, zeroForOne, amountIn);
            zeroForOne = !zeroForOne;
        }

        _assertCounts(n, n, 1, "after the fuzzed swaps");
    }
}
