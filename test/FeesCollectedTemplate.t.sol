// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {FeesCollectedTemplate} from "../src/templates/FeesCollectedTemplate.sol";

import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
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

/// @dev Test-only. The smallest hook on the template: it adds up the fees each account collected.
contract FeesLedger is FeesCollectedTemplate {
    mapping(address => uint256) public collected0;
    mapping(address => uint256) public collected1;
    uint256 public calls;

    constructor(IPoolManager poolManager_, address positionManager_)
        BaseHook(poolManager_)
        FeesCollectedTemplate(positionManager_)
    {}

    function _onFeesCollected(PoolKey calldata, address account, uint256 fees0, uint256 fees1) internal override {
        collected0[account] += fees0;
        collected1[account] += fees1;
        calls++;
    }
}

contract FeesCollectedTemplateTest is HookTestBase {
    /// @dev The mask every hook on this template carries, as a literal: afterAddLiquidity (1 << 10) |
    ///      afterRemoveLiquidity (1 << 8).
    uint160 internal constant EXPECTED_MASK = 0x500;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    uint160 internal constant PLACED_FLAGS =
        uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

    FeesLedger internal hook;
    IPositionManagerLike internal posm;
    address internal permit2;
    PoolKey internal key;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal aliceTokenId;

    function setUp() public {
        _deployV4();
        permit2 = Permit2Deployer.deploy();
        posm = IPositionManagerLike(
            V4PositionManagerDeployer.deploy(address(manager), permit2, 300_000, address(0), address(0))
        );

        address where = _flagAddress(PLACED_FLAGS);
        _place(abi.encodePacked(type(FeesLedger).creationCode, abi.encode(manager, address(posm))), where);
        hook = FeesLedger(where);

        key = _initPool(IHooks(where));
        _fund(alice);
        _fund(bob);
        aliceTokenId = _mint(alice);
    }

    function _token(Currency currency) internal pure returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency));
    }

    function _fund(address who) internal {
        Currency[2] memory currencies = [currency0, currency1];
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 token = _token(currencies[i]);
            token.transfer(who, 1e30);
            vm.startPrank(who);
            token.approve(permit2, type(uint256).max);
            IPermit2Like(permit2).approve(address(token), address(posm), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    function _mint(address who) internal returns (uint256 tokenId) {
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(LIQUIDITY), type(uint128).max, type(uint128).max, who, bytes("")
        );
        params[1] = abi.encode(currency0, currency1);
        vm.prank(who);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev A change of zero liquidity: the way a position collects its LP fees.
    function _collect(address who, uint256 tokenId) internal returns (uint256 fees0, uint256 fees1) {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, who);

        uint256 before0 = _token(currency0).balanceOf(who);
        uint256 before1 = _token(currency1).balanceOf(who);
        vm.prank(who);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        fees0 = _token(currency0).balanceOf(who) - before0;
        fees1 = _token(currency1).balanceOf(who) - before1;
    }

    function _swapBothWays() internal {
        _swap(key, true, 1e18);
        _swap(key, false, 1e18);
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "template declares something other than its two flags");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0x500 in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage. Without the afterRemoveLiquidity bit a fee collection,
    ///      which is a change of zero liquidity, would never reach the hook.
    function test_RevertWhen_PlacedAtAddressMissingOneFlag() public {
        (bool ok, bytes memory ret) = _tryPlace(
            abi.encodePacked(type(FeesLedger).creationCode, abi.encode(manager, address(posm))),
            _flagAddress(uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG))
        );
        assertFalse(ok, "constructor accepted an address without the afterRemoveLiquidity bit");
        assertEq(bytes4(ret), Hooks.HookAddressNotValid.selector, "reverted, but not for the address");
    }

    function test_RevertWhen_ThePositionManagerHasNoCode() public {
        (bool ok, bytes memory ret) = _tryPlace(
            abi.encodePacked(type(FeesLedger).creationCode, abi.encode(manager, makeAddr("not a contract"))),
            _flagAddress(PLACED_FLAGS | (uint160(1) << 20))
        );
        assertFalse(ok, "constructor accepted a PositionManager without code");
        assertEq(bytes4(ret), FeesCollectedTemplate.PositionManagerHasNoCode.selector, "reverted for another reason");
    }

    // ── 2. who collected, and how much ───────────────────────────────────────────────────────

    function test_Collect_TellsTheHookTheOwner_AndExactlyTheFeesTheyReceived() public {
        _swapBothWays();
        (uint256 fees0, uint256 fees1) = _collect(alice, aliceTokenId);

        assertGt(fees0, 0, "no fees were earned in currency0");
        assertGt(fees1, 0, "no fees were earned in currency1");
        assertEq(hook.collected0(alice), fees0, "currency0: the hook was told another amount than the owner received");
        assertEq(hook.collected1(alice), fees1, "currency1: the hook was told another amount than the owner received");
        assertEq(hook.calls(), 1, "minting and collecting told the hook more than once");
    }

    /// @dev The owner is read when the fees are collected, not when the position was opened.
    function test_Collect_AfterTheTokenMoved_NamesTheNewOwner() public {
        _swapBothWays();
        vm.prank(alice);
        posm.transferFrom(alice, bob, aliceTokenId);
        (uint256 fees0,) = _collect(bob, aliceTokenId);

        assertEq(hook.collected0(bob), fees0, "the new owner was not named");
        assertEq(hook.collected0(alice), 0, "the previous owner was named");
    }

    function test_AddingToAPosition_AlsoCollects_AndTellsTheHook() public {
        _swapBothWays();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(aliceTokenId, uint256(1e18), type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(currency0);
        params[2] = abi.encode(currency1);
        vm.prank(alice);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        assertGt(hook.collected0(alice), 0, "fees collected while adding liquidity were not reported");
    }

    // ── 3. what is skipped, without stopping anything ────────────────────────────────────────

    /// @dev A position held through another contract, with alice's token id as its salt: the one
    ///      value that could be mistaken for her position.
    function test_Collect_ThroughAnotherRouter_IsSkipped() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(aliceTokenId)
        });
        liquidityRouter.modifyLiquidity(key, params, "");
        _swapBothWays();
        params.liquidityDelta = 0;
        liquidityRouter.modifyLiquidity(key, params, "");

        assertEq(hook.calls(), 0, "the hook was told about a position it cannot attribute");
    }

    /// @dev The PositionManager burns the token before it removes the liquidity, so there is no owner
    ///      to name. The withdrawal goes through.
    function test_Burn_WithUncollectedFees_GoesThrough_AndIsSkipped() public {
        _swapBothWays();
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(aliceTokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, alice);
        uint256 before = _token(currency0).balanceOf(alice);
        vm.prank(alice);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        assertGt(_token(currency0).balanceOf(alice), before, "the burn returned nothing");
        assertEq(hook.calls(), 0, "the hook was told about a burned position");
    }

    function testFuzz_RevertWhen_CallerIsNotPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 0, salt: bytes32(aliceTokenId)
        });
        // A forged callback that looks like the PositionManager collecting alice's fees.
        BalanceDelta fees = BalanceDelta.wrap(int256(1e18) << 128 | int256(1e18));

        vm.startPrank(caller);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterAddLiquidity(address(posm), key, params, BalanceDelta.wrap(0), fees, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(address(posm), key, params, BalanceDelta.wrap(0), fees, "");
        vm.stopPrank();
        assertEq(hook.calls(), 0, "a forged callback reached the hook");
    }
}
