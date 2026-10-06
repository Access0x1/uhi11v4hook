// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {SwapReceiptTemplate} from "../src/templates/SwapReceiptTemplate.sol";

import {Vm} from "forge-std/Vm.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

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

/// @dev Test-only. The smallest hook on the template: a list of payees, set by the test.
contract ReceiptForListedPayees is SwapReceiptTemplate {
    mapping(bytes32 => bool) public listed;

    constructor(IPoolManager poolManager_, address[] memory routers_) SwapReceiptTemplate(poolManager_, routers_) {}

    function list(bytes32 payee) external {
        listed[payee] = true;
    }

    function _payeeIsValid(bytes32 payee) internal view override returns (bool) {
        return listed[payee];
    }
}

contract SwapReceiptTemplateTest is HookTestBase {
    /// @dev The mask every hook on this template carries, as a literal: afterSwap (1 << 6).
    uint160 internal constant EXPECTED_MASK = 0x40;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    uint160 internal constant PLACED_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);

    bytes32 internal constant RECEIPT_TOPIC =
        keccak256("Receipt(bytes32,bytes32,bytes32,bytes32,address,address,int128,int128)");
    bytes32 internal constant REFUSED_TOPIC = keccak256("ReceiptRefused(bytes32,address,uint8)");

    bytes32 internal constant PAYEE = keccak256("a listed payee");
    bytes32 internal constant UNLISTED = keccak256("a payee nobody listed");
    bytes32 internal constant ORDER = keccak256("order 1");

    ReceiptForListedPayees internal hook;
    IUniswapV4Router04 internal router;
    PoolKey internal key;
    PoolId internal id;

    address internal buyer = makeAddr("buyer");
    address internal other = makeAddr("other");

    function setUp() public {
        _deployV4();
        router = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(manager), Permit2Deployer.deploy())));

        address where = _flagAddress(PLACED_FLAGS);
        _place(_initcode(), where);
        hook = ReceiptForListedPayees(where);
        hook.list(PAYEE);

        key = _initPool(IHooks(where));
        id = key.toId();
        _addLiquidity(key);
        _fund(buyer);
        _fund(other);
    }

    function _initcode() internal view returns (bytes memory) {
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        return abi.encodePacked(type(ReceiptForListedPayees).creationCode, abi.encode(manager, routers));
    }

    function _fund(address who) internal {
        Currency[2] memory currencies = [currency0, currency1];
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 token = MockERC20(Currency.unwrap(currencies[i]));
            token.transfer(who, 1e24);
            vm.prank(who);
            token.approve(address(router), type(uint256).max);
        }
    }

    /// @dev Exact-input swap of 1e15 through the trusted router, carrying `hookData`.
    function _swapWith(address who, bytes memory hookData) internal returns (BalanceDelta delta, Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(who);
        delta = router.swap(-int256(1e15), 0, true, key, hookData, who, block.timestamp);
        logs = vm.getRecordedLogs();
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) n++;
        }
    }

    function _receipt(Vm.Log[] memory logs) internal view returns (Vm.Log memory found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == RECEIPT_TOPIC) return logs[i];
        }
        revert("no Receipt event");
    }

    function _refusal(Vm.Log[] memory logs) internal view returns (SwapReceiptTemplate.Refusal reason) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == REFUSED_TOPIC) {
                (, reason) = abi.decode(logs[i].data, (address, SwapReceiptTemplate.Refusal));
                return reason;
            }
        }
        revert("no ReceiptRefused event");
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "template declares something other than afterSwap");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0x40 in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage: the neighbouring bit, beforeSwap, instead of afterSwap.
    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        (bool ok, bytes memory ret) = _tryPlace(_initcode(), _flagAddress(uint160(Hooks.BEFORE_SWAP_FLAG)));

        assertFalse(ok, "constructor accepted an address that says beforeSwap");
        assertEq(bytes4(ret), Hooks.HookAddressNotValid.selector, "reverted, but not for the address");
    }

    // ── 2. a receipt ─────────────────────────────────────────────────────────────────────────

    function test_SwapNamingAListedPayee_WritesOneReceipt_WithWhatTheSwapMoved() public {
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapWith(buyer, abi.encode(PAYEE, ORDER));

        assertEq(_count(logs, RECEIPT_TOPIC), 1, "receipts written");
        Vm.Log memory r = _receipt(logs);
        bytes32 expectedId = hook.receiptId(id, PAYEE, ORDER, buyer);
        assertEq(r.topics[1], expectedId, "receipt id is not what receiptId() computes");
        assertEq(r.topics[2], PoolId.unwrap(id), "receipt names another pool");
        assertEq(r.topics[3], PAYEE, "receipt names another payee");

        (bytes32 orderRef, address payer, address sender, int128 amount0, int128 amount1) =
            abi.decode(r.data, (bytes32, address, address, int128, int128));
        assertEq(orderRef, ORDER, "orderRef");
        assertEq(payer, buyer, "payer is not the router's caller");
        assertEq(sender, address(router), "sender is not the router");
        assertEq(amount0, delta.amount0(), "amount0 is not what the swap moved");
        assertEq(amount1, delta.amount1(), "amount1 is not what the swap moved");
        assertEq(amount0, -1e15, "the buyer did not pay what they asked to");
        assertTrue(hook.receipted(expectedId), "the id was not recorded");
    }

    /// @dev A swap that stops at its price limit moves less than it asked for. The receipt carries
    ///      the amount moved. v4-core's test router is not trusted, so the payer is empty.
    function test_PartialFill_ReceiptCarriesTheAmountMoved_NotTheAmountRequested() public {
        vm.recordLogs();
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-1)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(PAYEE, ORDER)
        );
        Vm.Log memory r = _receipt(vm.getRecordedLogs());
        (, address payer,, int128 amount0,) = abi.decode(r.data, (bytes32, address, address, int128, int128));

        assertGt(delta.amount0(), -1e17, "the swap did not stop early");
        assertEq(amount0, delta.amount0(), "the receipt carries the amount requested");
        assertEq(payer, address(0), "a payer was named for a router the hook does not trust");
    }

    // ── 3. no receipt, and the swap still goes through ───────────────────────────────────────

    function test_SwapWithNoHookData_WritesNothing() public {
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapWith(buyer, "");
        assertEq(delta.amount0(), -1e15, "the swap did not execute");
        assertEq(_count(logs, RECEIPT_TOPIC) + _count(logs, REFUSED_TOPIC), 0, "the hook emitted something");
    }

    function test_SwapNamingAnUnlistedPayee_Executes_AndIsRefusedAReceipt() public {
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapWith(buyer, abi.encode(UNLISTED, ORDER));
        assertEq(delta.amount0(), -1e15, "the swap did not execute");
        assertEq(_count(logs, RECEIPT_TOPIC), 0, "a receipt was written for an unlisted payee");
        assertEq(uint8(_refusal(logs)), uint8(SwapReceiptTemplate.Refusal.InvalidPayee), "refusal reason");
    }

    function test_TheSameSwapTwice_WritesOneReceipt_AndBothSwapsExecute() public {
        _swapWith(buyer, abi.encode(PAYEE, ORDER));
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapWith(buyer, abi.encode(PAYEE, ORDER));

        assertEq(delta.amount0(), -1e15, "the second swap did not execute");
        assertEq(_count(logs, RECEIPT_TOPIC), 0, "a second receipt was written");
        assertEq(uint8(_refusal(logs)), uint8(SwapReceiptTemplate.Refusal.Duplicate), "refusal reason");
    }

    /// @dev Any bytes at all as hookData. The swap executes; a receipt is written only for exactly
    ///      64 bytes naming a listed payee.
    function testFuzz_AnyHookData_NeverStopsTheSwap(bytes memory hookData) public {
        (BalanceDelta delta, Vm.Log[] memory logs) = _swapWith(buyer, hookData);
        assertEq(delta.amount0(), -1e15, "the swap did not execute");

        bool wellFormed = hookData.length == 64;
        bool names = wellFormed && bytes32(hookData) == PAYEE;
        assertEq(_count(logs, RECEIPT_TOPIC), names ? 1 : 0, "receipts written");
        if (hookData.length != 0 && !wellFormed) {
            assertEq(uint8(_refusal(logs)), uint8(SwapReceiptTemplate.Refusal.Malformed), "refusal reason");
        }
    }

    // ── 4. the receipt id ────────────────────────────────────────────────────────────────────

    /// @dev Whatever goes into the id, two different references for one payee must not collide, and
    ///      neither must two payees with one reference: each order gets its own receipt.
    function testFuzz_ReceiptId_DiffersWhenPayeeOrReferenceDiffers(bytes32 payee, bytes32 a, bytes32 b, address payer)
        public
        view
    {
        vm.assume(a != b);
        assertTrue(hook.receiptId(id, payee, a, payer) != hook.receiptId(id, payee, b, payer), "two references, one id");
        assertTrue(hook.receiptId(id, a, payee, payer) != hook.receiptId(id, b, payee, payer), "two payees, one id");
    }

    function test_TwoOrdersForOnePayee_GetAReceiptEach() public {
        (, Vm.Log[] memory first) = _swapWith(buyer, abi.encode(PAYEE, ORDER));
        (, Vm.Log[] memory second) = _swapWith(buyer, abi.encode(PAYEE, keccak256("order 2")));
        assertEq(_count(first, RECEIPT_TOPIC) + _count(second, RECEIPT_TOPIC), 2, "receipts written for two orders");
    }

    /// @dev A stranger names the buyer's order first, with a swap of their own. The buyer's swap
    ///      still gets its receipt, under the buyer's address; the stranger's sits under theirs.
    function test_AStrangerNamingYourOrderFirst_DoesNotUseItUp() public {
        (, Vm.Log[] memory strangers) = _swapWith(other, abi.encode(PAYEE, ORDER));
        (, Vm.Log[] memory buyers) = _swapWith(buyer, abi.encode(PAYEE, ORDER));

        assertEq(_count(strangers, RECEIPT_TOPIC), 1, "the stranger's swap wrote no receipt of its own");
        assertEq(_count(buyers, RECEIPT_TOPIC), 1, "the buyer was refused a receipt for their own order");
        (, address payer,,,) = abi.decode(_receipt(buyers).data, (bytes32, address, address, int128, int128));
        assertEq(payer, buyer, "the buyer's receipt names another payer");
        assertTrue(
            hook.receiptId(id, PAYEE, ORDER, buyer) != hook.receiptId(id, PAYEE, ORDER, other), "two payers, one id"
        );
    }

    /// @dev The same order paid through a second pool on the same hook is a different receipt.
    function test_ReceiptId_IsBoundToThePool() public view {
        PoolKey memory otherPool =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(hook)});
        assertTrue(
            hook.receiptId(id, PAYEE, ORDER, buyer) != hook.receiptId(otherPool.toId(), PAYEE, ORDER, buyer),
            "two pools, one id"
        );
    }

    // ── 5. access ────────────────────────────────────────────────────────────────────────────

    function testFuzz_RevertWhen_CallerIsNotPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});

        vm.prank(caller);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(caller, key, params, BalanceDelta.wrap(0), abi.encode(PAYEE, ORDER));
        assertFalse(hook.receipted(hook.receiptId(id, PAYEE, ORDER, address(0))), "a receipt was forged");
    }
}
