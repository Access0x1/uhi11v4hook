// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {PlainHookFee} from "./HookFeePotTemplate.t.sol";
import {ReceiptForListedPayees} from "./SwapReceiptTemplate.t.sol";
import {FeePerAccount} from "./OverrideFeeTemplate.t.sol";
import {BudgetPerSession} from "./GatedSwapTemplate.t.sol";

import {Vm} from "forge-std/Vm.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice One route, two pools, the same hook on both: A -> B -> C through the official router.
///         What each template does when it is called once per hop inside a single unlock.
/// @dev Inside a hop the hook sees the router as `sender` and that hop's own hookData. Between hops
///      nothing is transferred: the B that comes out of the first pool is the input of the second,
///      and only A and C ever move.
contract MultiHopTest is HookTestBase {
    uint256 internal constant PIPS = 1e6;
    uint24 internal constant HOOK_FEE = 500;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant RECEIPT_TOPIC =
        keccak256("Receipt(bytes32,bytes32,bytes32,bytes32,address,address,int128,int128)");
    bytes32 internal constant PAYEE = keccak256("a listed payee");
    bytes32 internal constant ORDER = keccak256("order 1");

    IUniswapV4Router04 internal router;
    Currency internal a;
    Currency internal b;
    Currency internal c;
    address internal trader = makeAddr("trader");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        _deployV4();
        router = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(manager), Permit2Deployer.deploy())));

        // A third token. The route goes A -> B -> C whatever order the three addresses sort in.
        MockERC20 third = new MockERC20("Token C", "C", 18);
        third.mint(address(this), type(uint128).max);
        third.approve(address(liquidityRouter), type(uint256).max);
        a = currency0;
        b = currency1;
        c = Currency.wrap(address(third));

        Currency[3] memory all = [a, b, c];
        for (uint256 i = 0; i < 3; i++) {
            MockERC20 token = MockERC20(Currency.unwrap(all[i]));
            token.transfer(trader, 1e24);
            vm.prank(trader);
            token.approve(address(router), type(uint256).max);
        }
    }

    function _key(Currency x, Currency y, uint24 fee, IHooks hook) internal pure returns (PoolKey memory) {
        (Currency lo, Currency hi) = x < y ? (x, y) : (y, x);
        return PoolKey({currency0: lo, currency1: hi, fee: fee, tickSpacing: TICK_SPACING, hooks: hook});
    }

    /// @dev Opens A/B and B/C on `hook` with the usual position in each.
    function _twoPools(IHooks hook, uint24 fee) internal returns (PoolId ab, PoolId bc) {
        PoolKey memory first = _key(a, b, fee, hook);
        PoolKey memory second = _key(b, c, fee, hook);
        manager.initialize(first, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(second, TickMath.getSqrtPriceAtTick(0));
        _addLiquidity(first);
        _addLiquidity(second);
        return (first.toId(), second.toId());
    }

    function _path(IHooks hook, uint24 fee, bytes memory firstHopData, bytes memory secondHopData)
        internal
        view
        returns (PathKey[] memory path)
    {
        path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: b, fee: fee, tickSpacing: TICK_SPACING, hooks: hook, hookData: firstHopData
        });
        path[1] = PathKey({
            intermediateCurrency: c, fee: fee, tickSpacing: TICK_SPACING, hooks: hook, hookData: secondHopData
        });
    }

    function _bal(Currency currency, address who) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(currency)).balanceOf(who);
    }

    function _claims(address hook, Currency currency) internal view returns (uint256) {
        return manager.balanceOf(hook, currency.toId());
    }

    function _place(bytes memory creationCode, bytes memory args, uint160 flags) internal returns (address where) {
        where = _flagAddress(flags);
        _place(abi.encodePacked(creationCode, args), where);
    }

    function _routers() internal view returns (address[] memory routers) {
        routers = new address[](1);
        routers[0] = address(router);
    }

    // ── the fee pot ──────────────────────────────────────────────────────────────────────────

    uint160 internal constant POT_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function _potHook() internal returns (PlainHookFee hook, PoolId ab, PoolId bc) {
        hook = PlainHookFee(
            _place(type(PlainHookFee).creationCode, abi.encode(manager, HOOK_FEE, treasury, uint24(300_000)), POT_FLAGS)
        );
        (ab, bc) = _twoPools(IHooks(address(hook)), FEE);
    }

    /// @dev Exact input: each hop pays the fee on ITS input. The first on the A sent; the second on
    ///      the B that came out of the first pool, which never left the PoolManager.
    function test_FeePot_ExactInputRoute_EachHopPaysOnItsOwnInput() public {
        (PlainHookFee hook, PoolId ab, PoolId bc) = _potHook();
        uint256 aBefore = _bal(a, trader);
        uint256 bBefore = _bal(b, trader);
        uint256 cBefore = _bal(c, trader);

        vm.prank(trader);
        router.swap(-int256(1e17), 0, a, _path(IHooks(address(hook)), FEE, "", ""), trader, block.timestamp);

        assertEq(aBefore - _bal(a, trader), 1e17, "the trader paid other than the A they asked to");
        assertEq(_bal(b, trader), bBefore, "B moved in or out of the trader's wallet");
        assertGt(_bal(c, trader), cBefore, "the trader received no C");

        assertEq(hook.pot(ab, a), 1e17 * uint256(HOOK_FEE) / PIPS, "first hop: fee is not 0.05% of the A in");
        assertGt(hook.pot(bc, b), 0, "second hop: no fee was taken in B");
        assertEq(
            hook.pot(ab, b) + hook.pot(bc, c) + hook.pot(bc, a) + hook.pot(ab, c), 0, "a fee landed in the wrong pot"
        );

        // Each currency's claims equal the pots that hold it, across both pools.
        assertEq(_claims(address(hook), a), hook.pot(ab, a), "A: claims held != pot");
        assertEq(_claims(address(hook), b), hook.pot(bc, b), "B: claims held != pot");
        assertEq(_claims(address(hook), c), 0, "C: the hook holds claims nobody paid");
        assertEq(_bal(b, address(router)), 0, "the router kept B");
    }

    /// @dev Exact output: the router works backwards from the C wanted. Each hop pays its fee on top,
    ///      in its input, so the second hop's fee raises the B the first hop must deliver.
    function test_FeePot_ExactOutputRoute_EachHopPaysOnTop_AndTheTraderGetsExactlyWhatTheyNamed() public {
        (PlainHookFee hook, PoolId ab, PoolId bc) = _potHook();
        uint256 aBefore = _bal(a, trader);
        uint256 bBefore = _bal(b, trader);
        uint256 cBefore = _bal(c, trader);

        vm.prank(trader);
        router.swap(
            int256(1e17), type(uint256).max, a, _path(IHooks(address(hook)), FEE, "", ""), trader, block.timestamp
        );

        uint256 paid = aBefore - _bal(a, trader);
        assertEq(_bal(c, trader) - cBefore, 1e17, "the trader did not receive the C they named");
        assertEq(_bal(b, trader), bBefore, "B moved in or out of the trader's wallet");

        uint256 feeA = hook.pot(ab, a);
        assertGt(feeA, 0, "first hop: no fee in A");
        assertEq(feeA, (paid - feeA) * HOOK_FEE / PIPS, "first hop: fee is not 0.05% of the A the pool charged");
        assertGt(hook.pot(bc, b), 0, "second hop: no fee in B");

        assertEq(_claims(address(hook), a), hook.pot(ab, a), "A: claims held != pot");
        assertEq(_claims(address(hook), b), hook.pot(bc, b), "B: claims held != pot");
        assertEq(
            _bal(a, address(router)) + _bal(b, address(router)) + _bal(c, address(router)), 0, "the router kept tokens"
        );
    }

    /// @dev Any amount, either kind of swap, then a sweep of everything sweepable: per currency, the
    ///      claims the hook holds equal the two pools' pots, and each pot plus what was swept from it
    ///      equals the fees taken on that pool.
    function testFuzz_FeePot_AcrossTwoPools_EveryPotIsBacked(uint256 amount, bool exactOutput) public {
        (PlainHookFee hook, PoolId ab, PoolId bc) = _potHook();
        amount = bound(amount, 1e6, 1e17);

        vm.prank(trader);
        router.swap(
            exactOutput ? int256(amount) : -int256(amount),
            exactOutput ? type(uint256).max : 0,
            a,
            _path(IHooks(address(hook)), FEE, "", ""),
            trader,
            block.timestamp
        );
        if (hook.sweepable(ab, a) > 0) hook.sweep(ab, a);
        if (hook.sweepable(bc, b) > 0) hook.sweep(bc, b);

        assertEq(_claims(address(hook), a), hook.pot(ab, a) + hook.pot(bc, a), "A: claims held != pots");
        assertEq(_claims(address(hook), b), hook.pot(ab, b) + hook.pot(bc, b), "B: claims held != pots");
        assertEq(_claims(address(hook), c), hook.pot(ab, c) + hook.pot(bc, c), "C: claims held != pots");
        assertEq(hook.pot(ab, a) + hook.swept(ab, a), hook.feesTaken(ab, a), "A/B pool: pot + swept != fees taken");
        assertEq(hook.pot(bc, b) + hook.swept(bc, b), hook.feesTaken(bc, b), "B/C pool: pot + swept != fees taken");
    }

    /// @dev Why the fuzz above starts at 1e6 wei. A route of 1 wei reverts SwapAmountCannotBeZero, and
    ///      it does so on pools with NO hook: 1 wei in rounds to 0 out, and the router then asks the
    ///      second pool to swap 0. The fee pot neither causes this nor changes it.
    function test_ARouteOfOneWei_RevertsOnHooklessPoolsToo() public {
        _twoPools(IHooks(address(0)), FEE);
        PathKey[] memory path = _path(IHooks(address(0)), FEE, "", "");

        vm.prank(trader);
        vm.expectRevert();
        router.swap(-1, 0, a, path, trader, block.timestamp);
    }

    // ── receipts ─────────────────────────────────────────────────────────────────────────────

    function _receiptHook() internal returns (ReceiptForListedPayees hook, PoolId ab, PoolId bc) {
        hook = ReceiptForListedPayees(
            _place(
                type(ReceiptForListedPayees).creationCode,
                abi.encode(manager, _routers()),
                uint160(Hooks.AFTER_SWAP_FLAG)
            )
        );
        hook.list(PAYEE);
        (ab, bc) = _twoPools(IHooks(address(hook)), FEE);
    }

    function _receipts(Vm.Log[] memory logs, address hook) internal pure returns (Vm.Log[] memory found) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == hook && logs[i].topics[0] == RECEIPT_TOPIC) n++;
        }
        found = new Vm.Log[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == hook && logs[i].topics[0] == RECEIPT_TOPIC) found[n++] = logs[i];
        }
    }

    /// @dev The router hands each hop its own hookData. With the payee named on the last hop only,
    ///      there is one receipt, for the pool the payment arrived through. Its amounts are that
    ///      hop's: B in, C out. The A the payer actually spent is not on it.
    function test_Receipt_NamedOnTheLastHopOnly_IsOneReceipt_CarryingThatHopsAmounts() public {
        (ReceiptForListedPayees hook, PoolId ab, PoolId bc) = _receiptHook();
        uint256 cBefore = _bal(c, trader);

        vm.recordLogs();
        vm.prank(trader);
        router.swap(
            -int256(1e17),
            0,
            a,
            _path(IHooks(address(hook)), FEE, "", abi.encode(PAYEE, ORDER)),
            trader,
            block.timestamp
        );
        Vm.Log[] memory receipts = _receipts(vm.getRecordedLogs(), address(hook));

        assertEq(receipts.length, 1, "receipts written");
        assertEq(receipts[0].topics[2], PoolId.unwrap(bc), "the receipt is not for the last pool");
        (, address payer,, int128 amount0, int128 amount1) =
            abi.decode(receipts[0].data, (bytes32, address, address, int128, int128));
        assertEq(payer, trader, "the payer is not the router's caller on the second hop");

        // In the B/C pool, C is one of the two currencies; its amount is what the trader received.
        int128 cAmount = c < b ? amount0 : amount1;
        int128 bAmount = c < b ? amount1 : amount0;
        assertEq(
            uint256(uint128(cAmount)), _bal(c, trader) - cBefore, "the receipt's C is not what the trader received"
        );
        assertLt(bAmount, 0, "the receipt does not show B going in");
        assertFalse(
            hook.receipted(hook.receiptId(ab, PAYEE, ORDER, trader)), "a receipt was written for the first pool"
        );
    }

    /// @dev The same payee and order named on BOTH hops is two receipts: the id includes the pool, and
    ///      the route crossed two. Whoever builds the route must name the order on one hop only.
    function test_Receipt_NamedOnBothHops_IsTwoReceipts_OnePerPool() public {
        (ReceiptForListedPayees hook, PoolId ab, PoolId bc) = _receiptHook();
        bytes memory data = abi.encode(PAYEE, ORDER);

        vm.recordLogs();
        vm.prank(trader);
        router.swap(-int256(1e17), 0, a, _path(IHooks(address(hook)), FEE, data, data), trader, block.timestamp);
        Vm.Log[] memory receipts = _receipts(vm.getRecordedLogs(), address(hook));

        assertEq(receipts.length, 2, "receipts written");
        assertEq(receipts[0].topics[2], PoolId.unwrap(ab), "first receipt's pool");
        assertEq(receipts[1].topics[2], PoolId.unwrap(bc), "second receipt's pool");
        assertTrue(receipts[0].topics[1] != receipts[1].topics[1], "two pools, one receipt id");
    }

    // ── the fee override ─────────────────────────────────────────────────────────────────────

    /// @dev The router answers msgSender() the same on every hop, so a member is a member on both.
    function test_FeeOverride_TheSwapperIsRecognisedOnEveryHop() public {
        FeePerAccount hook = FeePerAccount(
            _place(
                type(FeePerAccount).creationCode,
                abi.encode(manager, uint24(3000), _routers()),
                uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
            )
        );
        hook.set(trader, 500);
        _twoPools(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG);

        vm.recordLogs();
        vm.prank(trader);
        router.swap(
            -int256(1e17),
            0,
            a,
            _path(IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, "", ""),
            trader,
            block.timestamp
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 swaps;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, 500, "a hop charged the trader another fee than theirs");
                swaps++;
            }
        }
        assertEq(swaps, 2, "the route did not make two swaps");
    }

    // ── the gate ─────────────────────────────────────────────────────────────────────────────

    /// @dev The gate counts the input each hop requests. On a two-hop route that is the A sent AND
    ///      the B passed between the pools: one payment is counted twice, in two currencies, against
    ///      one budget. A budget meant for what the payer spends must be given to the first hop only.
    function test_Gate_ARouteThroughTwoGatedPools_IsCountedOncePerHop() public {
        BudgetPerSession hook = BudgetPerSession(
            _place(
                type(BudgetPerSession).creationCode, abi.encode(manager, _routers()), uint160(Hooks.BEFORE_SWAP_FLAG)
            )
        );
        bytes32 session = keccak256("session 1");
        hook.grant(session, 1e18);
        _twoPools(IHooks(address(hook)), FEE);
        uint256 bOutOfFirstPool;

        vm.recordLogs();
        vm.prank(trader);
        router.swap(
            -int256(1e17),
            0,
            a,
            _path(IHooks(address(hook)), FEE, abi.encode(session), abi.encode(session)),
            trader,
            block.timestamp
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                bOutOfFirstPool = uint256(uint128(amount0 > 0 ? amount0 : amount1));
                break;
            }
        }

        assertGt(bOutOfFirstPool, 0, "the first hop's output was not found");
        assertEq(hook.remaining(session), 1e18 - 1e17 - bOutOfFirstPool, "the budget did not fall by both hops' inputs");
    }
}
