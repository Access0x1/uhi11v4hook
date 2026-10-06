// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {HookFeePotTemplate} from "../src/templates/HookFeePotTemplate.sol";

import {Vm} from "forge-std/Vm.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Test-only. The template with nothing added: it takes the fee, holds it, and lets the treasury sweep.
contract PlainHookFee is HookFeePotTemplate {
    constructor(IPoolManager poolManager_, uint24 hookFee_, address treasury_, uint24 treasuryShare_)
        BaseHook(poolManager_)
        HookFeePotTemplate(hookFee_, treasury_, treasuryShare_)
    {}
}

contract HookFeePotTemplateTest is HookTestBase {
    /// @dev The mask every hook on this template carries, as a literal: beforeSwap (1 << 7) | afterSwap
    ///      (1 << 6) | beforeSwapReturnDelta (1 << 3) | afterSwapReturnDelta (1 << 2).
    uint160 internal constant EXPECTED_MASK = 0xCC;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    uint160 internal constant PLACED_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    uint24 internal constant HOOK_FEE = 500; // 0.05% of the input
    uint24 internal constant TREASURY_SHARE = 300_000; // 30% of the hook fees
    uint256 internal constant PIPS = 1e6;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    PlainHookFee internal hook;
    PoolKey internal key;
    PoolId internal id;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        _deployV4();
        address where = _flagAddress(PLACED_FLAGS);
        _place(_initcode(HOOK_FEE, treasury, TREASURY_SHARE), where);
        hook = PlainHookFee(where);

        key = _initPool(IHooks(where)); // a static-fee pool: the template sets no LP fee of its own
        id = key.toId();
        _addLiquidity(key);
    }

    function _initcode(uint24 hookFee, address treasury_, uint24 share) internal view returns (bytes memory) {
        return abi.encodePacked(type(PlainHookFee).creationCode, abi.encode(manager, hookFee, treasury_, share));
    }

    function _swapSpecified(bool zeroForOne, int256 amountSpecified, uint160 priceLimit)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: priceLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _claims(Currency currency) internal view returns (uint256) {
        return manager.balanceOf(address(hook), currency.toId());
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "template declares something other than its four flags");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0xCC in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage. Without the beforeSwapReturnDelta bit the PoolManager
    ///      would ignore the fee an exact-input swap returns, and the claims minted for it would
    ///      leave every such swap unsettled.
    function test_RevertWhen_PlacedAtAddressMissingOneFlag() public {
        address wrong = _flagAddress(PLACED_FLAGS & ~uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
        (bool ok, bytes memory ret) = _tryPlace(_initcode(HOOK_FEE, treasury, TREASURY_SHARE), wrong);

        assertFalse(ok, "constructor accepted an address without the beforeSwapReturnDelta bit");
        assertEq(bytes4(ret), Hooks.HookAddressNotValid.selector, "reverted, but not for the address");
    }

    // ── 2. the fee, in the input currency ────────────────────────────────────────────────────

    function test_ExactInputSwap_PaysTheFeeOutOfItsInput_AndThePoolFeeIsUntouched() public {
        vm.recordLogs();
        BalanceDelta delta = _swapSpecified(true, -1e17, MIN_PRICE_LIMIT);

        assertEq(delta.amount0(), -1e17, "the swapper paid other than what they asked to");
        assertEq(hook.pot(id, currency0), 1e17 * uint256(HOOK_FEE) / PIPS, "hook fee is not 0.05% of the input");
        assertEq(hook.pot(id, currency1), 0, "the output currency's pot moved");
        assertEq(_claims(currency0), hook.pot(id, currency0), "the pot is not backed one for one by claims");

        // No LP fee override: the pool charges its own static fee.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, FEE, "the template changed the pool's LP fee");
            }
        }
    }

    function test_ExactOutputSwap_PaysTheFeeOnTopOfWhatThePoolCharged() public {
        BalanceDelta delta = _swapSpecified(true, 1e17, MIN_PRICE_LIMIT);

        uint256 paid = uint256(uint128(-delta.amount0()));
        uint256 fee = hook.pot(id, currency0);
        assertEq(delta.amount1(), 1e17, "the swapper did not receive the output they named");
        assertGt(fee, 0, "no hook fee was taken");
        assertEq(fee, (paid - fee) * HOOK_FEE / PIPS, "hook fee is not 0.05% of what the pool charged");
        assertEq(hook.pot(id, currency1), 0, "the output currency's pot moved");
    }

    /// @dev What taking the fee before the swap costs: it is charged on the amount requested.
    function test_ExactInputSwap_ThatStopsAtItsPriceLimit_PaidTheFeeOnAllItRequested() public {
        BalanceDelta delta = _swapSpecified(true, -1e18, TickMath.getSqrtPriceAtTick(-1));

        assertLt(uint256(uint128(-delta.amount0())), 1e17, "the swap did not stop early");
        assertEq(hook.pot(id, currency0), 1e18 * uint256(HOOK_FEE) / PIPS, "hook fee is not on the amount requested");
    }

    // ── 3. the treasury ──────────────────────────────────────────────────────────────────────

    function test_Sweep_ByAnyone_PaysOnlyTheTreasury_ItsShare_Once() public {
        _swapSpecified(true, -1e17, MIN_PRICE_LIMIT);
        uint256 taken = hook.feesTaken(id, currency0);

        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        uint256 amount = hook.sweep(id, currency0);

        assertEq(amount, taken * TREASURY_SHARE / PIPS, "the sweep is not the treasury's share");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(treasury), amount, "the treasury was not paid");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(anyone), 0, "the caller was paid");
        assertEq(hook.pot(id, currency0), taken - amount, "the pot did not fall by the sweep");

        vm.expectRevert(HookFeePotTemplate.NothingToSweep.selector);
        hook.sweep(id, currency0);
    }

    /// @dev One pool's pot is not another's: a second pool on the same hook and the same pair.
    function test_Sweep_OfAPoolWithNoFees_HasNothingToTake() public {
        _swapSpecified(true, -1e17, MIN_PRICE_LIMIT);
        PoolKey memory other =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(hook)});
        manager.initialize(other, TickMath.getSqrtPriceAtTick(0));

        vm.expectRevert(HookFeePotTemplate.NothingToSweep.selector);
        hook.sweep(other.toId(), currency0);
    }

    function test_RevertWhen_ConstructorParametersAreOutOfRange() public {
        address other = _flagAddress(PLACED_FLAGS | (uint160(1) << 20));

        (bool ok, bytes memory ret) = _tryPlace(_initcode(1_000_000, treasury, TREASURY_SHARE), other);
        assertFalse(ok, "a 100% hook fee was accepted");
        assertEq(bytes4(ret), HookFeePotTemplate.HookFeeTooLarge.selector, "hook fee: reverted for another reason");

        (ok, ret) = _tryPlace(_initcode(HOOK_FEE, treasury, 1_000_001), other);
        assertFalse(ok, "a treasury share above 100% was accepted");
        assertEq(bytes4(ret), HookFeePotTemplate.ShareTooLarge.selector, "share: reverted for another reason");

        (ok, ret) = _tryPlace(_initcode(HOOK_FEE, address(0), TREASURY_SHARE), other);
        assertFalse(ok, "a share for a treasury of address zero was accepted");
        assertEq(bytes4(ret), HookFeePotTemplate.TreasuryNotSet.selector, "treasury: reverted for another reason");
    }

    // ── 4. access, and the books ─────────────────────────────────────────────────────────────

    function testFuzz_RevertWhen_CallerIsNotPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: 0});

        vm.startPrank(caller);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(caller, key, params, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(caller, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(caller, currency0, uint256(1)));
        vm.stopPrank();
    }

    /// @dev Any mix of exact-input and exact-output swaps in either direction and sweeps. After every
    ///      step, per currency: the claims held equal the pot; the pot plus what was swept equals all
    ///      fees ever taken; and the treasury has never had more than its share.
    function testFuzz_ThePotIsAlwaysBacked_AndTheTreasuryNeverExceedsItsShare(uint256 seed, uint8 steps) public {
        uint256 n = bound(steps, 1, 10);
        Currency[2] memory currencies = [currency0, currency1];
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = (r >> 8) % 2 == 0;
            uint256 amount = bound(r >> 16, 1, 1e17);

            if (r % 3 == 0) {
                _swapSpecified(zeroForOne, -int256(amount), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
            } else if (r % 3 == 1) {
                _swapSpecified(zeroForOne, int256(amount), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
            } else if (hook.sweepable(id, currencies[zeroForOne ? 0 : 1]) > 0) {
                hook.sweep(id, currencies[zeroForOne ? 0 : 1]);
            }

            for (uint256 c = 0; c < 2; c++) {
                uint256 taken = hook.feesTaken(id, currencies[c]);
                uint256 swept = hook.swept(id, currencies[c]);
                assertEq(_claims(currencies[c]), hook.pot(id, currencies[c]), "claims held != pot");
                assertEq(hook.pot(id, currencies[c]) + swept, taken, "pot + swept != fees ever taken");
                assertLe(swept * PIPS, taken * TREASURY_SHARE, "the treasury took more than its share");
                assertEq(
                    MockERC20(Currency.unwrap(currencies[c])).balanceOf(treasury), swept, "treasury balance != swept"
                );
            }
        }
    }
}
