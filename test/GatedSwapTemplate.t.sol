// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {GatedSwapTemplate} from "../src/templates/GatedSwapTemplate.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Test-only. The smallest hook on the template with a budget: hookData names a session, the
///      limit is what that session has left, and every swap let through is counted against it.
contract BudgetPerSession is GatedSwapTemplate {
    mapping(bytes32 session => uint256) public remaining;
    uint256 public limitReads;

    constructor(IPoolManager poolManager_, address[] memory executors_) GatedSwapTemplate(poolManager_, executors_) {}

    function grant(bytes32 session, uint256 budget) external {
        remaining[session] = budget;
    }

    function _limitFor(address, PoolKey calldata, bytes calldata hookData) internal view override returns (uint256) {
        return hookData.length == 32 ? remaining[bytes32(hookData)] : 0;
    }

    function _consume(address, PoolKey calldata, uint256 requested, bytes calldata hookData) internal override {
        if (hookData.length == 32) remaining[bytes32(hookData)] -= requested;
    }
}

contract GatedSwapTemplateTest is HookTestBase {
    /// @dev The mask every hook on this template carries, as a literal: beforeSwap (1 << 7).
    uint160 internal constant EXPECTED_MASK = 0x80;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    uint160 internal constant PLACED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG);

    bytes32 internal constant SESSION = keccak256("session 1");
    uint256 internal constant BUDGET = 1e17;

    BudgetPerSession internal hook;
    PoolSwapTest internal outsider; // the same router code as swapRouter, not named as an executor
    PoolKey internal key;

    function setUp() public {
        _deployV4();
        outsider = new PoolSwapTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(outsider), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(outsider), type(uint256).max);

        address where = _flagAddress(PLACED_FLAGS);
        _place(_initcode(), where);
        hook = BudgetPerSession(where);
        hook.grant(SESSION, BUDGET);

        key = _initPool(IHooks(where));
        _addLiquidity(key);
    }

    function _initcode() internal view returns (bytes memory) {
        address[] memory executors = new address[](1);
        executors[0] = address(swapRouter);
        return abi.encodePacked(type(BudgetPerSession).creationCode, abi.encode(manager, executors));
    }

    /// @dev Called through `this.` so a revert can be caught and read.
    function swapVia(PoolSwapTest through, int256 amountSpecified, uint160 priceLimit, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return through.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev The hook's own error, out of the PoolManager's wrapper.
    function _hookError(bytes memory reason) internal pure returns (bytes memory inner) {
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "not the PoolManager's wrapped hook error");
        bytes memory body = new bytes(reason.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = reason[i + 4];
        }
        (,, inner,) = abi.decode(body, (address, bytes4, bytes, bytes));
    }

    function _expectRefused(PoolSwapTest through, int256 amountSpecified, bytes memory hookData, bytes4 expected)
        internal
    {
        try this.swapVia(through, amountSpecified, MIN_PRICE_LIMIT, hookData) {
            fail("the gate let the swap through");
        } catch (bytes memory reason) {
            assertEq(bytes4(_hookError(reason)), expected, "refused, but for another reason");
        }
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "template declares something other than beforeSwap");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0x80 in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage: the neighbouring bit, afterSwap, instead of beforeSwap.
    ///      At that address the gate would never be called and every swap would go through.
    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        (bool ok, bytes memory ret) = _tryPlace(_initcode(), _flagAddress(uint160(Hooks.AFTER_SWAP_FLAG)));

        assertFalse(ok, "constructor accepted an address that says afterSwap");
        assertEq(bytes4(ret), Hooks.HookAddressNotValid.selector, "reverted, but not for the address");
    }

    // ── 2. who may swap ──────────────────────────────────────────────────────────────────────

    function test_Swap_ThroughTheExecutor_WithinTheLimit_Executes() public {
        BalanceDelta delta = this.swapVia(swapRouter, -1e15, MIN_PRICE_LIMIT, abi.encode(SESSION));
        assertEq(delta.amount0(), -1e15, "the swap did not execute");
        assertEq(hook.remaining(SESSION), BUDGET - 1e15, "the budget did not fall by the input requested");
    }

    /// @dev The same router code at another address, with the same session: it is not an executor.
    function test_RevertWhen_SwapComesFromAnyoneElse() public {
        _expectRefused(outsider, -1e15, abi.encode(SESSION), GatedSwapTemplate.NotAnExecutor.selector);
        assertEq(hook.remaining(SESSION), BUDGET, "a refused swap was counted against the budget");
    }

    /// @dev A stranger is refused as a stranger even when their request is also over the limit and
    ///      names no session: the executor check runs before anything reads the hookData.
    function test_AStranger_IsRefusedBeforeTheLimitIsRead() public {
        _expectRefused(outsider, -int256(BUDGET + 1), "", GatedSwapTemplate.NotAnExecutor.selector);
        _expectRefused(outsider, 1e15, "", GatedSwapTemplate.NotAnExecutor.selector);
    }

    // ── 3. the limit ─────────────────────────────────────────────────────────────────────────

    function test_RevertWhen_SwapRequestsMoreThanTheLimit() public {
        _expectRefused(swapRouter, -int256(BUDGET + 1), abi.encode(SESSION), GatedSwapTemplate.OverLimit.selector);
        this.swapVia(swapRouter, -int256(BUDGET), MIN_PRICE_LIMIT, abi.encode(SESSION)); // exactly the limit is allowed
        assertEq(hook.remaining(SESSION), 0, "the budget is not used up");
        _expectRefused(swapRouter, -1, abi.encode(SESSION), GatedSwapTemplate.OverLimit.selector);
    }

    /// @dev hookData that names no session has a limit of zero in this hook.
    function test_RevertWhen_TheExecutorNamesNoSession() public {
        _expectRefused(swapRouter, -1e15, "", GatedSwapTemplate.OverLimit.selector);
    }

    /// @dev An exact-output swap does not say how much input it will use, so the gate cannot hold
    ///      it to a limit before it runs.
    function test_RevertWhen_SwapIsExactOutput() public {
        _expectRefused(swapRouter, 1e15, abi.encode(SESSION), GatedSwapTemplate.ExactOutputNotSupported.selector);
    }

    /// @dev A swap that stops at its price limit uses less than it requested and is counted in full.
    function test_PartialFill_IsCountedAtTheAmountRequested() public {
        BalanceDelta delta =
            this.swapVia(swapRouter, -int256(BUDGET), TickMath.getSqrtPriceAtTick(-1), abi.encode(SESSION));
        assertGt(delta.amount0(), -int256(BUDGET), "the swap did not stop early");
        assertEq(hook.remaining(SESSION), 0, "a partial fill was not counted in full");
    }

    /// @dev Any sequence of requests against one budget: a request goes through if and only if it
    ///      fits what is left, and the input actually paid never exceeds the budget.
    function testFuzz_InputPaidUnderOneSession_NeverExceedsItsBudget(uint256 seed, uint8 swaps) public {
        uint256 n = bound(swaps, 1, 8);
        uint256 left = BUDGET;
        uint256 paid;
        for (uint256 i = 0; i < n; i++) {
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 1, BUDGET / 2);
            try this.swapVia(swapRouter, -int256(amount), MIN_PRICE_LIMIT, abi.encode(SESSION)) returns (
                BalanceDelta delta
            ) {
                assertLe(amount, left, "a swap over what was left went through");
                left -= amount;
                paid += uint256(uint128(-delta.amount0()));
            } catch (bytes memory reason) {
                assertGt(amount, left, "a swap that fitted was refused");
                assertEq(bytes4(_hookError(reason)), GatedSwapTemplate.OverLimit.selector, "refused for another reason");
            }
            assertEq(hook.remaining(SESSION), left, "the hook's books differ from the test's");
        }
        assertLe(paid, BUDGET, "more input was paid than the budget");
    }

    // ── 3b. native ETH ───────────────────────────────────────────────────────────────────────

    /// @dev Called through `this.` so a revert can be caught and read. Forwards the ETH it is sent.
    function swapNativeVia(PoolSwapTest through, PoolKey memory nativeKey, uint256 amountIn, bytes memory hookData)
        external
        payable
        returns (BalanceDelta)
    {
        return through.swap{value: msg.value}(
            nativeKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev The budget counts ETH the same way it counts a token: by the input requested. A refused
    ///      swap returns the ETH that was sent with it.
    function test_NativeEth_TheLimitCountsEthRequested_AndARefusedSwapKeepsNoEth() public {
        PoolKey memory nativeKey = _initNativePool(IHooks(address(hook)));
        _addNativeLiquidity(nativeKey);
        vm.deal(address(this), 1 ether);

        BalanceDelta delta =
            this.swapNativeVia{value: 0.04 ether}(swapRouter, nativeKey, 0.04 ether, abi.encode(SESSION));
        assertEq(delta.amount0(), -0.04 ether, "the ETH swap did not execute");
        assertEq(hook.remaining(SESSION), BUDGET - 0.04 ether, "the budget did not fall by the ETH requested");

        // 0.07 more would make 0.11 against a budget of 0.1.
        try this.swapNativeVia{value: 0.07 ether}(swapRouter, nativeKey, 0.07 ether, abi.encode(SESSION)) {
            fail("the gate let an ETH swap over the limit through");
        } catch (bytes memory reason) {
            assertEq(bytes4(_hookError(reason)), GatedSwapTemplate.OverLimit.selector, "refused for another reason");
        }
        try this.swapNativeVia{value: 0.01 ether}(outsider, nativeKey, 0.01 ether, abi.encode(SESSION)) {
            fail("the gate let a stranger's ETH swap through");
        } catch (bytes memory reason) {
            assertEq(bytes4(_hookError(reason)), GatedSwapTemplate.NotAnExecutor.selector, "refused for another reason");
        }

        assertEq(address(this).balance, 0.96 ether, "ETH sent with a refused swap did not come back");
        assertEq(hook.remaining(SESSION), BUDGET - 0.04 ether, "a refused ETH swap was counted");
    }

    // ── 4. what the gate leaves alone ────────────────────────────────────────────────────────

    function test_Liquidity_IsOpenToAnyone() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1e18, salt: "x"});
        liquidityRouter.modifyLiquidity(key, params, "");
        params.liquidityDelta = -1e18;
        liquidityRouter.modifyLiquidity(key, params, "");
    }

    function testFuzz_RevertWhen_CallerIsNotPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: 0});

        vm.prank(caller);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(swapRouter), key, params, abi.encode(SESSION));
        assertEq(hook.remaining(SESSION), BUDGET, "the budget was spent without a swap");
    }
}
