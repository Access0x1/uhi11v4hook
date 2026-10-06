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

/// @dev Test-only. A treasury that refuses ETH.
contract TreasuryThatRefusesEth {
    receive() external payable {
        revert("no ETH here");
    }
}

/// @dev Test-only. A treasury that, on being paid ETH, tries to sweep again before the first sweep
///      has finished.
contract TreasuryThatSweepsAgain {
    HookFeePotTemplate public hook;
    PoolId public id;
    uint256 public attempts;
    bytes4 public refusedWith;

    function aim(HookFeePotTemplate hook_, PoolId id_) external {
        hook = hook_;
        id = id_;
    }

    receive() external payable {
        attempts++;
        try hook.sweep(id, Currency.wrap(address(0))) {}
        catch (bytes memory reason) {
            refusedWith = bytes4(reason);
        }
    }
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

    // ── 3b. native ETH ───────────────────────────────────────────────────────────────────────

    Currency internal constant ETH = Currency.wrap(address(0));

    function _nativePoolOn(PlainHookFee on) internal returns (PoolKey memory nativeKey) {
        nativeKey = _initNativePool(IHooks(address(on)));
        _addNativeLiquidity(nativeKey);
    }

    function _hookWithTreasury(address treasury_, uint160 namespace) internal returns (PlainHookFee other) {
        address where = _flagAddress(PLACED_FLAGS | (namespace << 20));
        _place(_initcode(HOOK_FEE, treasury_, TREASURY_SHARE), where);
        other = PlainHookFee(where);
    }

    function test_NativeEth_ExactInput_PaysTheFeeOutOfTheEthSent() public {
        PoolKey memory nativeKey = _nativePoolOn(hook);
        PoolId nativeId = nativeKey.toId();
        vm.deal(address(this), 1 ether);

        BalanceDelta delta = _swapNative(nativeKey, true, -0.1 ether, 0.1 ether);

        assertEq(address(this).balance, 0.9 ether, "the swapper paid other than the ETH they asked to");
        assertEq(delta.amount0(), -0.1 ether, "the swap's ETH delta is not what was requested");
        assertEq(hook.pot(nativeId, ETH), 0.1 ether * uint256(HOOK_FEE) / PIPS, "hook fee is not 0.05% of the ETH in");
        assertEq(_claims(ETH), hook.pot(nativeId, ETH), "the ETH pot is not backed one for one by claims");
        assertEq(address(hook).balance, 0, "the hook holds ETH itself");
    }

    /// @dev The swapper names the tokens out and sends more ETH than needed. They are charged what
    ///      the pool took plus the hook fee, and the router returns the rest.
    function test_NativeEth_ExactOutput_PaysTheFeeOnTop_AndTheRestOfTheEthComesBack() public {
        PoolKey memory nativeKey = _nativePoolOn(hook);
        PoolId nativeId = nativeKey.toId();
        vm.deal(address(this), 1 ether);
        uint256 tokensBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        BalanceDelta delta = _swapNative(nativeKey, true, 0.1 ether, 1 ether);

        uint256 paid = 1 ether - address(this).balance;
        uint256 fee = hook.pot(nativeId, ETH);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - tokensBefore, 0.1 ether, "tokens out");
        assertEq(paid, uint256(uint128(-delta.amount0())), "ETH kept by the router: the refund is wrong");
        assertGt(fee, 0, "no hook fee was taken");
        assertEq(fee, (paid - fee) * HOOK_FEE / PIPS, "hook fee is not 0.05% of the ETH the pool charged");
        assertEq(address(swapRouter).balance, 0, "the router kept ETH");
        assertEq(address(hook).balance, 0, "the hook holds ETH itself");
    }

    /// @dev ETH as the OUTPUT: the fee is taken in the token paid in, and the ETH pot does not move.
    function test_NativeEth_AsOutput_TheFeeIsTakenInTheTokenPaidIn() public {
        PoolKey memory nativeKey = _nativePoolOn(hook);
        PoolId nativeId = nativeKey.toId();
        uint256 ethBefore = address(this).balance;

        _swapNative(nativeKey, false, -0.1 ether, 0); // exact input of the token
        assertEq(hook.pot(nativeId, currency1), 0.1 ether * uint256(HOOK_FEE) / PIPS, "exact input: fee in the token");

        uint256 potBefore = hook.pot(nativeId, currency1);
        _swapNative(nativeKey, false, 0.05 ether, 0); // exact output of ETH
        assertGt(hook.pot(nativeId, currency1), potBefore, "exact output: no fee in the token");

        assertEq(hook.pot(nativeId, ETH), 0, "the ETH pot moved on swaps that paid in the token");
        assertGt(address(this).balance, ethBefore + 0.05 ether, "the swapper did not receive the ETH");
    }

    function test_NativeEth_Sweep_PaysTheTreasuryInEth() public {
        PoolKey memory nativeKey = _nativePoolOn(hook);
        PoolId nativeId = nativeKey.toId();
        vm.deal(address(this), 1 ether);
        _swapNative(nativeKey, true, -0.1 ether, 0.1 ether);
        uint256 taken = hook.feesTaken(nativeId, ETH);

        uint256 amount = hook.sweep(nativeId, ETH);

        assertEq(amount, taken * TREASURY_SHARE / PIPS, "the sweep is not the treasury's share");
        assertEq(treasury.balance, amount, "the treasury was not paid in ETH");
        assertEq(_claims(ETH), hook.pot(nativeId, ETH), "the ETH pot is not backed one for one by claims");
    }

    /// @dev A treasury that cannot receive ETH fails its own sweep and nothing else: the pot, the
    ///      books and the pool are as they were, and swaps go on.
    function test_NativeEth_ATreasuryThatRefusesEth_FailsOnlyItsOwnSweep() public {
        PlainHookFee other = _hookWithTreasury(address(new TreasuryThatRefusesEth()), 3);
        PoolKey memory nativeKey = _nativePoolOn(other);
        PoolId nativeId = nativeKey.toId();
        vm.deal(address(this), 1 ether);
        _swapNative(nativeKey, true, -0.1 ether, 0.1 ether);
        uint256 potBefore = other.pot(nativeId, ETH);

        vm.expectRevert();
        other.sweep(nativeId, ETH);

        assertEq(other.pot(nativeId, ETH), potBefore, "a failed sweep changed the pot");
        assertEq(other.swept(nativeId, ETH), 0, "a failed sweep was recorded");
        assertEq(manager.balanceOf(address(other), 0), potBefore, "a failed sweep changed the claims held");
        _swapNative(nativeKey, true, -0.1 ether, 0.1 ether); // the pool still trades
        assertGt(other.pot(nativeId, ETH), potBefore, "the pool stopped taking fees");
    }

    /// @dev Paying ETH hands control to the treasury in the middle of a sweep. It tries to sweep
    ///      again. The second sweep is refused, and the treasury ends with its share once.
    function test_NativeEth_ATreasuryThatSweepsAgainWhileBeingPaid_GetsItsShareOnce() public {
        TreasuryThatSweepsAgain greedy = new TreasuryThatSweepsAgain();
        PlainHookFee other = _hookWithTreasury(address(greedy), 4);
        PoolKey memory nativeKey = _nativePoolOn(other);
        PoolId nativeId = nativeKey.toId();
        greedy.aim(other, nativeId);
        vm.deal(address(this), 1 ether);
        _swapNative(nativeKey, true, -0.1 ether, 0.1 ether);
        uint256 share = other.feesTaken(nativeId, ETH) * TREASURY_SHARE / PIPS;

        other.sweep(nativeId, ETH);

        assertEq(greedy.attempts(), 1, "the treasury was not paid in ETH exactly once");
        assertEq(greedy.refusedWith(), HookFeePotTemplate.NothingToSweep.selector, "the second sweep was not refused");
        assertEq(address(greedy).balance, share, "the treasury holds other than its share");
        assertEq(other.swept(nativeId, ETH), share, "more was recorded as swept than the share");
        assertEq(manager.balanceOf(address(other), 0), other.pot(nativeId, ETH), "claims held != pot");
    }

    /// @dev The books fuzz, on a native pool: ETH in and out, exact input and exact output, sweeps.
    function testFuzz_NativeEth_ThePotIsAlwaysBacked_AndTheTreasuryNeverExceedsItsShare(uint256 seed, uint8 steps)
        public
    {
        PoolKey memory nativeKey = _nativePoolOn(hook);
        PoolId nativeId = nativeKey.toId();
        vm.deal(address(this), 100 ether);
        Currency[2] memory currencies = [ETH, currency1];

        uint256 n = bound(steps, 1, 10);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = (r >> 8) % 2 == 0;
            uint256 amount = bound(r >> 16, 1, 0.1 ether);

            if (r % 3 == 0) {
                _swapNative(nativeKey, zeroForOne, -int256(amount), zeroForOne ? amount : 0);
            } else if (r % 3 == 1) {
                _swapNative(nativeKey, zeroForOne, int256(amount), zeroForOne ? 1 ether : 0);
            } else if (hook.sweepable(nativeId, currencies[zeroForOne ? 0 : 1]) > 0) {
                hook.sweep(nativeId, currencies[zeroForOne ? 0 : 1]);
            }

            for (uint256 c = 0; c < 2; c++) {
                uint256 taken = hook.feesTaken(nativeId, currencies[c]);
                uint256 swept = hook.swept(nativeId, currencies[c]);
                assertEq(_claims(currencies[c]), hook.pot(nativeId, currencies[c]), "claims held != pot");
                assertEq(hook.pot(nativeId, currencies[c]) + swept, taken, "pot + swept != fees ever taken");
                assertLe(swept * PIPS, taken * TREASURY_SHARE, "the treasury took more than its share");
            }
            assertEq(treasury.balance, hook.swept(nativeId, ETH), "treasury ETH != swept");
            assertEq(address(hook).balance, 0, "the hook holds ETH itself");
            assertEq(address(swapRouter).balance, 0, "the router kept ETH");
        }
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
