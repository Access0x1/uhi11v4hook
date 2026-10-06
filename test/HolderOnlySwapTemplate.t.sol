// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {SettableCredential} from "./ReverseV4Hook.t.sol";
import {HolderOnlySwapTemplate} from "../src/templates/HolderOnlySwapTemplate.sol";
import {ICredential} from "../src/interfaces/ICredential.sol";

import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {DeployHelper} from "hookmate/artifacts/DeployHelper.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Test-only. The smallest hook on the template: the swapper must hold one kind of credential.
contract CredentialHolderGate is HolderOnlySwapTemplate {
    ICredential public immutable registry;
    bytes32 public immutable kind;

    constructor(IPoolManager poolManager_, address[] memory routers_, ICredential registry_, bytes32 kind_)
        HolderOnlySwapTemplate(poolManager_, routers_)
    {
        registry = registry_;
        kind = kind_;
    }

    function _isAllowed(address swapper, PoolKey calldata) internal view override returns (bool) {
        return registry.hasValidCredential(swapper, kind);
    }
}

contract HolderOnlySwapTemplateTest is HookTestBase {
    /// @dev The mask every hook on this template carries, as a literal: beforeSwap (1 << 7).
    uint160 internal constant EXPECTED_MASK = 0x80;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    uint160 internal constant PLACED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG);

    bytes32 internal constant KIND = keccak256("checked");

    CredentialHolderGate internal hook;
    SettableCredential internal registry;
    IUniswapV4Router04 internal router;
    IUniswapV4Router04 internal otherRouter;
    PoolKey internal key;

    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployV4();
        bytes memory routerInit =
            abi.encodePacked(V4RouterDeployer.initcode(), abi.encode(address(manager), Permit2Deployer.deploy()));
        router = IUniswapV4Router04(payable(DeployHelper.deploy(routerInit, hex"00")));
        otherRouter = IUniswapV4Router04(payable(DeployHelper.deploy(routerInit, hex"01")));
        registry = new SettableCredential();
        registry.set(holder, KIND, true);

        address where = _flagAddress(PLACED_FLAGS);
        _place(_initcode(), where);
        hook = CredentialHolderGate(where);

        key = _initPool(IHooks(where));
        _addLiquidity(key);
        _fund(holder);
        _fund(stranger);
    }

    function _initcode() internal view returns (bytes memory) {
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        return abi.encodePacked(type(CredentialHolderGate).creationCode, abi.encode(manager, routers, registry, KIND));
    }

    function _fund(address who) internal {
        Currency[2] memory currencies = [currency0, currency1];
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 token = MockERC20(Currency.unwrap(currencies[i]));
            token.transfer(who, 1e24);
            vm.startPrank(who);
            token.approve(address(router), type(uint256).max);
            token.approve(address(otherRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Called through `this.` so a revert can be caught and read.
    function swapAs(IUniswapV4Router04 through, address who) external returns (BalanceDelta) {
        vm.prank(who);
        return through.swap(-int256(1e15), 0, true, key, "", who, block.timestamp);
    }

    /// @dev Asserts the swap was refused by the gate, naming `expectedSwapper`.
    function _expectRefused(IUniswapV4Router04 through, address who, address expectedSwapper) internal {
        try this.swapAs(through, who) {
            fail("the gate let the swap through");
        } catch (bytes memory reason) {
            _assertNotAllowed(reason, expectedSwapper);
        }
    }

    function _assertNotAllowed(bytes memory reason, address expectedSwapper) internal pure {
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "not the PoolManager's wrapped hook error");
        bytes memory body = new bytes(reason.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = reason[i + 4];
        }
        (,, bytes memory inner,) = abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(
            keccak256(inner),
            keccak256(abi.encodeWithSelector(HolderOnlySwapTemplate.SwapperNotAllowed.selector, expectedSwapper)),
            "refused, but not as this swapper"
        );
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "template declares something other than beforeSwap");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0x80 in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage: the neighbouring bit, afterSwap. At that address the
    ///      gate would never be called and anyone could swap.
    function test_RevertWhen_PlacedAtAddressWithTheWrongFlag() public {
        (bool ok, bytes memory ret) = _tryPlace(_initcode(), _flagAddress(uint160(Hooks.AFTER_SWAP_FLAG)));

        assertFalse(ok, "constructor accepted an address that says afterSwap");
        assertEq(bytes4(ret), Hooks.HookAddressNotValid.selector, "reverted, but not for the address");
    }

    // ── 2. who may swap ──────────────────────────────────────────────────────────────────────

    function test_AHolder_ThroughTheTrustedRouter_Swaps() public {
        BalanceDelta delta = this.swapAs(router, holder);
        assertEq(delta.amount0(), -1e15, "the holder's swap did not execute");
    }

    function test_RevertWhen_TheSwapperHoldsNothing() public {
        _expectRefused(router, stranger, stranger);
    }

    /// @dev The check is made at the swap. Take the credential away and the next swap is refused.
    function test_RevertWhen_TheCredentialWasWithdrawn() public {
        this.swapAs(router, holder);
        registry.set(holder, KIND, false);
        _expectRefused(router, holder, holder);
    }

    /// @dev A holder, through a second copy of the same router that the hook was not deployed to
    ///      trust: the swapper cannot be established, so the swap is refused as nobody's.
    function test_RevertWhen_AHolderComesThroughAnotherRouter() public {
        _expectRefused(otherRouter, holder, address(0));
    }

    /// @dev v4-core's test router cannot say who called it. This contract holds the credential, and
    ///      so does that router; neither helps.
    function test_RevertWhen_TheRouterCannotSayWhoCalled() public {
        registry.set(address(this), KIND, true);
        registry.set(address(swapRouter), KIND, true);
        try this.swapDirect() {
            fail("the gate let the swap through");
        } catch (bytes memory reason) {
            _assertNotAllowed(reason, address(0));
        }
    }

    function swapDirect() external {
        _swap(key, true, 1e15);
    }

    /// @dev A check that cannot be made is a refusal: the registry reverts, and so does the swap.
    function test_RevertWhen_TheRegistryCannotAnswer() public {
        registry.setBroken(true);
        vm.expectRevert();
        this.swapAs(router, holder);
    }

    function testFuzz_OnlyHoldersSwap(address who, bool holds) public {
        vm.assume(who != address(0) && who != holder && who != address(manager) && who != address(router));
        vm.assume(who.code.length == 0 && uint160(who) > 0xffff);
        registry.set(who, KIND, holds);
        _fund(who);

        if (holds) {
            assertEq(this.swapAs(router, who).amount0(), -1e15, "a holder's swap did not execute");
        } else {
            _expectRefused(router, who, who);
        }
    }

    // ── 3. native ETH, and what the gate leaves alone ────────────────────────────────────────

    function test_NativeEth_AHolderSwapsEth_AndAStrangerIsRefusedAndKeepsTheirEth() public {
        PoolKey memory nativeKey = _initNativePool(IHooks(address(hook)));
        _addNativeLiquidity(nativeKey);
        vm.deal(holder, 1 ether);
        vm.deal(stranger, 1 ether);

        vm.prank(holder);
        router.swap{value: 0.01 ether}(-int256(0.01 ether), 0, true, nativeKey, "", holder, block.timestamp);
        assertEq(holder.balance, 0.99 ether, "the holder did not pay the ETH they asked to");

        vm.prank(stranger);
        vm.expectRevert();
        router.swap{value: 0.01 ether}(-int256(0.01 ether), 0, true, nativeKey, "", stranger, block.timestamp);
        assertEq(stranger.balance, 1 ether, "a refused swap kept the stranger's ETH");
    }

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
        hook.beforeSwap(address(router), key, params, "");
    }
}
