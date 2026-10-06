// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {SettableCredential} from "./ReverseV4Hook.t.sol";
import {HolderOnlyPoolTemplate} from "../src/templates/HolderOnlyPoolTemplate.sol";
import {ICredential} from "../src/interfaces/ICredential.sol";

import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
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
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Test-only. The parts of the official PositionManager and Permit2 these tests call.
interface IPositionManagerLike {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Test-only. The smallest hook on the template: the swapper must hold one kind of credential.
contract CredentialHolderGate is HolderOnlyPoolTemplate {
    ICredential public immutable registry;
    bytes32 public immutable kind;

    constructor(
        IPoolManager poolManager_,
        address[] memory routers_,
        address positionManager_,
        ICredential registry_,
        bytes32 kind_
    ) HolderOnlyPoolTemplate(poolManager_, routers_, positionManager_) {
        registry = registry_;
        kind = kind_;
    }

    function _isAllowed(address account, PoolKey calldata) internal view override returns (bool) {
        return registry.hasValidCredential(account, kind);
    }
}

contract HolderOnlyPoolTemplateTest is HookTestBase {
    /// @dev The mask every hook on this template carries, as a literal: beforeAddLiquidity (1 << 11) |
    ///      beforeSwap (1 << 7).
    uint160 internal constant EXPECTED_MASK = 0x880;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    uint160 internal constant PLACED_FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);

    bytes32 internal constant KIND = keccak256("checked");

    CredentialHolderGate internal hook;
    SettableCredential internal registry;
    IUniswapV4Router04 internal router;
    IUniswapV4Router04 internal otherRouter;
    IPositionManagerLike internal posm;
    address internal permit2;
    PoolKey internal key;
    uint256 internal holderTokenId;

    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployV4();
        permit2 = Permit2Deployer.deploy();
        posm = IPositionManagerLike(
            V4PositionManagerDeployer.deploy(address(manager), permit2, 300_000, address(0), address(0))
        );
        bytes memory routerInit = abi.encodePacked(V4RouterDeployer.initcode(), abi.encode(address(manager), permit2));
        router = IUniswapV4Router04(payable(DeployHelper.deploy(routerInit, hex"00")));
        otherRouter = IUniswapV4Router04(payable(DeployHelper.deploy(routerInit, hex"01")));
        registry = new SettableCredential();
        registry.set(holder, KIND, true);

        address where = _flagAddress(PLACED_FLAGS);
        _place(_initcode(), where);
        hook = CredentialHolderGate(where);

        key = _initPool(IHooks(where));
        _fund(holder);
        _fund(stranger);
        holderTokenId = _mint(key, holder, holder, 0); // the pool's liquidity comes from a holder
    }

    function _initcode() internal view returns (bytes memory) {
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        return abi.encodePacked(
            type(CredentialHolderGate).creationCode, abi.encode(manager, routers, address(posm), registry, KIND)
        );
    }

    function _fund(address who) internal {
        Currency[2] memory currencies = [currency0, currency1];
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 token = MockERC20(Currency.unwrap(currencies[i]));
            token.transfer(who, 1e24);
            vm.startPrank(who);
            token.approve(address(router), type(uint256).max);
            token.approve(address(otherRouter), type(uint256).max);
            token.approve(permit2, type(uint256).max);
            IPermit2Like(permit2).approve(address(token), address(posm), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    /// @dev `payer` opens a position whose NFT goes to `owner`. With `value` it is a native pool's
    ///      position: the ETH is sent along and what is not needed is swept back to the payer.
    function _mintCall(PoolKey memory poolKey, address payer, address owner, uint256 value)
        internal
        view
        returns (bytes memory)
    {
        payer;
        bool native = value != 0;
        bytes memory actions = native
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](native ? 3 : 2);
        params[0] = abi.encode(
            poolKey, TICK_LOWER, TICK_UPPER, uint256(LIQUIDITY), type(uint128).max, type(uint128).max, owner, bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        if (native) params[2] = abi.encode(poolKey.currency0, payer);
        return abi.encode(actions, params);
    }

    function _mint(PoolKey memory poolKey, address payer, address owner, uint256 value)
        internal
        returns (uint256 tokenId)
    {
        tokenId = posm.nextTokenId();
        bytes memory call = _mintCall(poolKey, payer, owner, value);
        vm.prank(payer);
        posm.modifyLiquidities{value: value}(call, block.timestamp);
    }

    /// @dev Called through `this.` so a revert can be caught and read.
    function mintAs(address payer, address owner) external {
        _mint(key, payer, owner, 0);
    }

    function _expectDepositRefused(address payer, address owner, address expectedProvider) internal {
        try this.mintAs(payer, owner) {
            fail("the gate accepted the liquidity");
        } catch (bytes memory reason) {
            _assertHookError(
                reason,
                abi.encodeWithSelector(HolderOnlyPoolTemplate.LiquidityProviderNotAllowed.selector, expectedProvider)
            );
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
        _assertHookError(
            reason, abi.encodeWithSelector(HolderOnlyPoolTemplate.SwapperNotAllowed.selector, expectedSwapper)
        );
    }

    /// @dev `reason` is the PoolManager's wrapper around the hook's own error, which must be `expected`.
    function _assertHookError(bytes memory reason, bytes memory expected) internal pure {
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "not the PoolManager's wrapped hook error");
        bytes memory body = new bytes(reason.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = reason[i + 4];
        }
        (,, bytes memory inner,) = abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(keccak256(inner), keccak256(expected), "refused, but not for this reason or this account");
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "template declares something other than its two flags");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0x880 in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage. With only the beforeSwap bit, swaps would be gated and
    ///      anyone at all could add liquidity, without any error.
    function test_RevertWhen_PlacedAtAddressMissingOneFlag() public {
        (bool ok, bytes memory ret) = _tryPlace(_initcode(), _flagAddress(uint160(Hooks.BEFORE_SWAP_FLAG)));

        assertFalse(ok, "constructor accepted an address without the beforeAddLiquidity bit");
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

    // ── 3. who may add liquidity ─────────────────────────────────────────────────────────────

    function test_AHolder_ThroughThePositionManager_AddsLiquidity() public {
        _mint(key, holder, holder, 0);
    }

    function test_RevertWhen_TheLiquidityProviderHoldsNothing() public {
        _expectDepositRefused(stranger, stranger, stranger);
    }

    /// @dev The position's holder is the one checked, not whoever pays for it. A holder cannot open a
    ///      position for someone who is not allowed, and someone not allowed can pay for a holder's.
    function test_TheOneChecked_IsWhoHoldsThePosition_NotWhoPays() public {
        _expectDepositRefused(holder, stranger, stranger);
        _mint(key, stranger, holder, 0);
    }

    /// @dev Any other route into the pool, whoever uses it. This contract holds the credential, and
    ///      so does v4-core's test router; neither can be shown to be the position's holder.
    function test_RevertWhen_LiquidityComesFromAnywhereButThePositionManager() public {
        registry.set(address(this), KIND, true);
        registry.set(address(liquidityRouter), KIND, true);
        try this.addDirect() {
            fail("the gate accepted the liquidity");
        } catch (bytes memory reason) {
            _assertHookError(
                reason, abi.encodeWithSelector(HolderOnlyPoolTemplate.LiquidityProviderNotAllowed.selector, address(0))
            );
        }
    }

    function addDirect() external {
        _addLiquidity(key);
    }

    function _changeLiquidity(address who, uint256 tokenId, bool add, uint256 liquidity) internal {
        bytes memory actions = add
            ? abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR))
            : abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = add
            ? abi.encode(tokenId, liquidity, type(uint128).max, type(uint128).max, bytes(""))
            : abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = add ? abi.encode(currency0, currency1) : abi.encode(currency0, currency1, who);
        vm.prank(who);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function increaseAs(address who, uint256 tokenId) external {
        _changeLiquidity(who, tokenId, true, 1e18);
    }

    /// @dev Someone whose credential is withdrawn can add nothing more, and can still take
    ///      everything out: removing liquidity is never gated.
    function test_ACredentialWithdrawn_StopsDeposits_AndNeverWithdrawals() public {
        registry.set(holder, KIND, false);

        try this.increaseAs(holder, holderTokenId) {
            fail("a former holder added liquidity");
        } catch (bytes memory reason) {
            _assertHookError(
                reason, abi.encodeWithSelector(HolderOnlyPoolTemplate.LiquidityProviderNotAllowed.selector, holder)
            );
        }

        uint256 before = MockERC20(Currency.unwrap(currency0)).balanceOf(holder);
        _changeLiquidity(holder, holderTokenId, false, uint256(LIQUIDITY));
        assertGt(MockERC20(Currency.unwrap(currency0)).balanceOf(holder), before, "the former holder got nothing back");
    }

    /// @dev What the gate does not stop: the position's NFT moving to someone not allowed. They hold
    ///      it, can withdraw it, and cannot add to it.
    function test_APositionMovedToSomeoneNotAllowed_CanBeWithdrawn_ButNotAddedTo() public {
        vm.prank(holder);
        posm.transferFrom(holder, stranger, holderTokenId);

        try this.increaseAs(stranger, holderTokenId) {
            fail("someone not allowed added liquidity to a position they were given");
        } catch (bytes memory reason) {
            _assertHookError(
                reason, abi.encodeWithSelector(HolderOnlyPoolTemplate.LiquidityProviderNotAllowed.selector, stranger)
            );
        }
        _changeLiquidity(stranger, holderTokenId, false, uint256(LIQUIDITY));
    }

    function test_RevertWhen_TheRegistryCannotAnswer_ForLiquidity() public {
        registry.setBroken(true);
        vm.expectRevert();
        this.mintAs(holder, holder);
    }

    function test_RevertWhen_ThePositionManagerHasNoCode() public {
        address[] memory routers = new address[](1);
        routers[0] = address(router);
        (bool ok, bytes memory ret) = _tryPlace(
            abi.encodePacked(
                type(CredentialHolderGate).creationCode,
                abi.encode(manager, routers, makeAddr("not a contract"), registry, KIND)
            ),
            _flagAddress(PLACED_FLAGS | (uint160(1) << 20))
        );
        assertFalse(ok, "constructor accepted a PositionManager without code");
        assertEq(bytes4(ret), HolderOnlyPoolTemplate.PositionManagerHasNoCode.selector, "reverted for another reason");
    }

    // ── 4. native ETH ────────────────────────────────────────────────────────────────────────

    function test_NativeEth_HoldersProvideAndSwapEth_AndAStrangerIsRefusedAndKeepsTheirEth() public {
        PoolKey memory nativeKey = _initNativePool(IHooks(address(hook)));
        vm.deal(holder, 2 ether);
        vm.deal(stranger, 2 ether);

        // A stranger cannot open the ETH position; the ETH they sent comes back with the revert.
        bytes memory strangersMint = _mintCall(nativeKey, stranger, stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        posm.modifyLiquidities{value: 1 ether}(strangersMint, block.timestamp);
        assertEq(stranger.balance, 2 ether, "a refused deposit kept the stranger's ETH");

        _mint(nativeKey, holder, holder, 1 ether);
        uint256 afterMint = holder.balance;
        assertGt(afterMint, 1 ether, "the holder's unused ETH did not come back");

        vm.prank(holder);
        router.swap{value: 0.01 ether}(-int256(0.01 ether), 0, true, nativeKey, "", holder, block.timestamp);
        assertEq(afterMint - holder.balance, 0.01 ether, "the holder did not pay the ETH they asked to");

        vm.prank(stranger);
        vm.expectRevert();
        router.swap{value: 0.01 ether}(-int256(0.01 ether), 0, true, nativeKey, "", stranger, block.timestamp);
        assertEq(stranger.balance, 2 ether, "a refused swap kept the stranger's ETH");
    }

    // ── 5. access ────────────────────────────────────────────────────────────────────────────

    function testFuzz_RevertWhen_CallerIsNotPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: 0});

        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1, salt: bytes32(holderTokenId)
        });

        vm.startPrank(caller);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(router), key, params, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(posm), key, liqParams, "");
        vm.stopPrank();
    }
}
