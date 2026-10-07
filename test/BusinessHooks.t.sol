// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {BusinessReceiptHook} from "../src/business/BusinessReceiptHook.sol";
import {DeployBusinessHook} from "../script/DeployBusinessHook.s.sol";
import {SameAddress} from "../script/SameAddress.s.sol";

import {Vm} from "forge-std/Vm.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice The eleven business hooks, each deployed the way the owner will deploy it
///         (script/DeployBusinessHook.s.sol, through CreateX's real code) and each given a pool.
///         They are one piece of code under eleven names, so every test here runs over all eleven.
contract BusinessHooksTest is HookTestBase {
    /// @dev The mask every business hook carries, as a literal: afterSwap (1 << 6).
    uint160 internal constant EXPECTED_MASK = 0x40;
    uint256 internal constant BASE_SEPOLIA = 84532;

    bytes32 internal constant RECEIPT_TOPIC =
        keccak256("Receipt(bytes32,bytes32,bytes32,bytes32,address,address,int128,int128)");
    bytes32 internal constant REFUSED_TOPIC = keccak256("ReceiptRefused(bytes32,address,uint8)");
    bytes32 internal constant PAYEE = keccak256("a shop");
    bytes32 internal constant ORDER = keccak256("order 1");

    address internal owner = makeAddr("the owner's signer");
    address internal buyer = makeAddr("buyer");

    DeployBusinessHook internal script;
    IUniswapV4Router04 internal router;
    BusinessReceiptHook[11] internal hooks;
    PoolKey[11] internal keys;
    bytes internal managerCode;

    function _names() internal pure returns (string[11] memory) {
        return [
            "ClickReserv",
            "Colmado",
            "Access0x1",
            "SebasTN",
            "GitHat",
            "QuantL",
            "NFTeria",
            "AllFans",
            "Rebato",
            "HemiAI",
            "Realsley"
        ];
    }

    function setUp() public {
        _deployV4(); // the chain id is Sepolia's from here
        managerCode = address(manager).code;
        vm.etch(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed, vm.parseBytes(vm.readFile("test/fixtures/createx.hex")));
        script = new DeployBusinessHook();
        router = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(manager), Permit2Deployer.deploy())));

        Currency[2] memory currencies = [currency0, currency1];
        for (uint256 c = 0; c < 2; c++) {
            MockERC20 token = MockERC20(Currency.unwrap(currencies[c]));
            token.transfer(buyer, 1e24);
            vm.prank(buyer);
            token.approve(address(router), type(uint256).max);
        }

        // For what a hook DOES, each is placed at an address with its one bit and bound to the
        // PoolManager this test deployed, which can open pools. (A copy of the PoolManager's code
        // at another address cannot: it takes every call for a delegatecall.) Where a hook LANDS
        // is tested further down, through the script.
        string[11] memory names = _names();
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        for (uint256 i = 0; i < names.length; i++) {
            address where = address((uint160(0x5000 + i) << 144) | EXPECTED_MASK);
            _place(abi.encodePacked(script.codeOf(names[i]), abi.encode(manager, routers)), where);
            hooks[i] = BusinessReceiptHook(where);
            keys[i] = PoolKey({
                currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(where)
            });
        }
    }

    /// @dev Makes this process look like `chainId` to the script: its id, and the official
    ///      PoolManager's code at the address the script expects there.
    function _onChain(uint256 chainId) internal returns (IPoolManager there) {
        vm.chainId(chainId);
        there = script.poolManagerFor(chainId);
        vm.etch(address(there), managerCode);
    }

    function _open(uint256 i) internal {
        manager.initialize(keys[i], 2 ** 96);
        _addLiquidity(keys[i]);
    }

    function _swap(uint256 i, bytes memory hookData) internal returns (BalanceDelta delta, Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(buyer);
        delta = router.swap(-int256(1e15), 0, true, keys[i], hookData, buyer, block.timestamp);
        logs = vm.getRecordedLogs();
    }

    function _count(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) n++;
        }
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_EveryBusinessHook_AddressMatchesItsDeclaredPermissions_AndSaysItsName() public view {
        string[11] memory names = _names();
        for (uint256 i = 0; i < names.length; i++) {
            assertEq(_maskOf(hooks[i].getHookPermissions()), EXPECTED_MASK, names[i]);
            assertEq(uint160(address(hooks[i])) & Hooks.ALL_HOOK_MASK, EXPECTED_MASK, names[i]);
            assertEq(hooks[i].business(), names[i], "the hook answers with another business's name");
            assertEq(address(hooks[i].poolManager()), address(manager), names[i]);
            for (uint256 j = 0; j < i; j++) {
                assertTrue(address(hooks[i]) != address(hooks[j]), "two businesses share an address");
            }
        }
    }

    /// @dev The permanent twin of the sabotage: the neighbouring bit, beforeSwap, instead of afterSwap.
    function test_RevertWhen_ABusinessHookIsPlacedAtAnAddressWithTheWrongFlag() public {
        string[11] memory names = _names();
        address[] memory routers = new address[](0);
        for (uint256 i = 0; i < names.length; i++) {
            bytes memory code = abi.encodePacked(script.codeOf(names[i]), abi.encode(manager, routers));
            (bool ok,) = _tryPlace(code, _flagAddress(uint160(Hooks.BEFORE_SWAP_FLAG)));
            assertFalse(ok, names[i]);
        }
    }

    // ── 2. what a business hook does ─────────────────────────────────────────────────────────

    function test_EveryBusinessHook_ASwapNamingAPayee_LeavesOneReceipt_OnThatHookOnly() public {
        for (uint256 i = 0; i < hooks.length; i++) {
            _open(i);
            (BalanceDelta delta, Vm.Log[] memory logs) = _swap(i, abi.encode(PAYEE, ORDER));
            assertEq(_count(logs, address(hooks[i]), RECEIPT_TOPIC), 1, "not exactly one receipt");
            assertEq(delta.amount0(), -1e15, "the swap did not move what was asked");
            bytes32 id = hooks[i].receiptId(keys[i].toId(), PAYEE, ORDER, buyer);
            assertTrue(hooks[i].receipted(id), "the receipt is not recorded under the buyer");
            for (uint256 j = 0; j < hooks.length; j++) {
                if (j != i) assertEq(_count(logs, address(hooks[j]), RECEIPT_TOPIC), 0, "another business wrote it");
            }
        }
    }

    function test_EveryBusinessHook_NoHookData_IsAnOrdinarySwap_AndAnEmptyPayeeIsRefusedAReceipt() public {
        for (uint256 i = 0; i < hooks.length; i++) {
            _open(i);
            (, Vm.Log[] memory plain) = _swap(i, "");
            assertEq(_count(plain, address(hooks[i]), RECEIPT_TOPIC), 0, "a receipt with no data");
            assertEq(_count(plain, address(hooks[i]), REFUSED_TOPIC), 0, "a refusal with no data");

            (BalanceDelta delta, Vm.Log[] memory logs) = _swap(i, abi.encode(bytes32(0), ORDER));
            assertEq(delta.amount0(), -1e15, "a refused receipt stopped the swap");
            assertEq(_count(logs, address(hooks[i]), RECEIPT_TOPIC), 0, "a receipt naming nobody");
            assertEq(_count(logs, address(hooks[i]), REFUSED_TOPIC), 1, "the refusal was not said");
        }
    }

    /// @dev Whatever is sent as hookData, on whichever business's pool, the swap goes through.
    function testFuzz_AnyHookData_OnAnyBusinessHook_NeverStopsTheSwap(uint8 which, bytes memory hookData) public {
        uint256 i = bound(which, 0, hooks.length - 1);
        _open(i);
        (BalanceDelta delta,) = _swap(i, hookData);
        assertEq(delta.amount0(), -1e15, "the swap did not go through");
        assertGt(delta.amount1(), 0, "the swapper received nothing");
    }

    function testFuzz_RevertWhen_AnyoneButThePoolManagerCallsAfterSwap(uint8 which, address caller) public {
        vm.assume(caller != address(manager));
        uint256 i = bound(which, 0, hooks.length - 1);
        vm.prank(caller);
        (bool ok,) = address(hooks[i])
            .call(abi.encodeWithSelector(IHooks.afterSwap.selector, caller, keys[i], "", BalanceDelta.wrap(0), ""));
        assertFalse(ok, "a stranger's afterSwap was accepted");
    }

    // ── 3. where it lands, deployed the way the owner will deploy it ─────────────────────────

    function test_EveryBusinessHook_LandsOnOneAddress_OnTwoTestnets_AndSaysItsName() public {
        string[11] memory names = _names();
        address[11] memory onSepolia;
        uint256 clean = vm.snapshotState();

        IPoolManager sepolia = _onChain(SEPOLIA);
        for (uint256 i = 0; i < names.length; i++) {
            BusinessReceiptHook hook = script.deployAs(owner, names[i], address(router));
            onSepolia[i] = address(hook);
            assertEq(onSepolia[i], script.businessAddress(owner, names[i]), names[i]);
            assertEq(uint160(onSepolia[i]) & Hooks.ALL_HOOK_MASK, EXPECTED_MASK, names[i]);
            assertTrue(uint160(onSepolia[i]) >> 152 != 0x91, names[i]);
            assertEq(hook.business(), names[i], names[i]);
            assertEq(address(hook.poolManager()), address(sepolia), names[i]);
            assertTrue(hook.trustedRouter(address(router)), names[i]);
            for (uint256 j = 0; j < i; j++) {
                assertTrue(onSepolia[i] != onSepolia[j], "two businesses share an address");
            }
        }

        vm.revertToState(clean);
        IPoolManager base = _onChain(BASE_SEPOLIA);
        for (uint256 i = 0; i < names.length; i++) {
            BusinessReceiptHook hook = script.deployAs(owner, names[i], address(0));
            assertEq(address(hook), onSepolia[i], names[i]);
            assertEq(address(hook.poolManager()), address(base), "bound to the first chain's PoolManager");
            assertFalse(hook.trustedRouter(address(router)), "the first chain's router came along");
        }
    }

    function test_RevertWhen_TheBusinessIsUnknown_OrDeployedTwice_OrTheRouterHasNoCode() public {
        _onChain(SEPOLIA);
        vm.expectRevert(abi.encodeWithSelector(DeployBusinessHook.UnknownBusiness.selector, "Nobody"));
        script.deployAs(owner, "Nobody", address(0));

        address first = address(script.deployAs(owner, "ClickReserv", address(0)));
        vm.expectRevert(abi.encodeWithSelector(SameAddress.AlreadyDeployed.selector, first));
        script.deployAs(owner, "ClickReserv", address(0));

        address where = script.businessAddress(owner, "Colmado");
        address empty = makeAddr("a router with no code");
        vm.expectRevert();
        script.deployAs(owner, "Colmado", empty);
        assertEq(where.code.length, 0, "a refused run deployed something");
    }
}
