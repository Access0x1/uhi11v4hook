// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./HookTestBase.sol";
import {SettableCredential} from "../ReverseV4Hook.t.sol";

import {Vm} from "forge-std/Vm.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {DeployHelper} from "hookmate/artifacts/DeployHelper.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev The parts of the official PositionManager and Permit2 these tests call.
interface IPositions {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IDeclaresPermissions {
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
}

/// @notice What the tests of the hooks in src/business/ share: the official PositionManager and
///         two official routers on the PoolManager under test, a credential registry a test can
///         set, two funded accounts, and the few moves every one of those tests makes.
abstract contract BusinessKit is HookTestBase {
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant RECEIPT_TOPIC =
        keccak256("Receipt(bytes32,bytes32,bytes32,bytes32,address,address,int128,int128)");
    bytes32 internal constant REFUSED_TOPIC = keccak256("ReceiptRefused(bytes32,address,uint8)");
    bytes32 internal constant KIND = keccak256("a kind of credential");

    address internal permit2;
    IPositions internal posm;
    /// @dev The router the hook under test is told to believe.
    IUniswapV4Router04 internal router;
    /// @dev The same router's code at another address, which no hook here is told to believe.
    IUniswapV4Router04 internal otherRouter;
    SettableCredential internal registry;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _kit() internal {
        _deployV4();
        vm.warp(1_760_000_000); // 2025-10-09, a Thursday: tests that read the clock start from a real one
        permit2 = Permit2Deployer.deploy();
        posm = IPositions(V4PositionManagerDeployer.deploy(address(manager), permit2, 300_000, address(0), address(0)));
        bytes memory routerInit = abi.encodePacked(V4RouterDeployer.initcode(), abi.encode(address(manager), permit2));
        router = IUniswapV4Router04(payable(DeployHelper.deploy(routerInit, hex"00")));
        otherRouter = IUniswapV4Router04(payable(DeployHelper.deploy(routerInit, hex"01")));
        registry = new SettableCredential();
        _fund(alice);
        _fund(bob);
    }

    function _routers() internal view returns (address[] memory routers) {
        routers = new address[](1);
        routers[0] = address(router);
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
            IPermit2Approve(permit2).approve(address(token), address(posm), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    /// @notice The address a hook with these bits is placed at, and the hook placed there.
    function _placeHook(uint160 flags, bytes memory initcode) internal returns (address where) {
        where = _flagAddress(flags);
        _place(initcode, where);
    }

    function _staticKey(address hook) internal view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
            });
    }

    function _dynamicKey(address hook) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function _open(PoolKey memory key) internal {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    /// @notice `payer` opens a position through the PositionManager; its NFT goes to `owner`.
    function _mint(PoolKey memory key, address payer, address owner) internal returns (uint256 tokenId) {
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(LIQUIDITY), type(uint128).max, type(uint128).max, owner, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.prank(payer);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @notice A change of zero liquidity: the way a position collects its LP fees.
    function _collect(PoolKey memory key, address who, uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, who);
        vm.prank(who);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @notice An exact-input swap of 1e15 of currency0 by `who` through `through`, with `hookData`.
    function _swapVia(IUniswapV4Router04 through, PoolKey memory key, address who, bytes memory hookData)
        internal
        returns (BalanceDelta delta, Vm.Log[] memory logs)
    {
        vm.recordLogs();
        vm.prank(who);
        delta = through.swap(-int256(1e15), 0, true, key, hookData, who, block.timestamp);
        logs = vm.getRecordedLogs();
    }

    /// @dev External so a test can catch a refused swap with try/catch.
    function trySwap(IUniswapV4Router04 through, PoolKey memory key, address who, int256 amountSpecified)
        external
        returns (BalanceDelta)
    {
        vm.prank(who);
        return
            through.swap(
                amountSpecified, amountSpecified < 0 ? 0 : type(uint256).max, true, key, "", who, block.timestamp
            );
    }

    function _refused(IUniswapV4Router04 through, PoolKey memory key, address who, int256 amountSpecified)
        internal
        returns (bool)
    {
        try this.trySwap(through, key, who, amountSpecified) {
            return false;
        } catch {
            return true;
        }
    }

    /// @notice The LP fee the PoolManager charged, read from its own Swap event.
    function _feeOf(Vm.Log[] memory logs) internal view returns (uint24 fee) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "the PoolManager emitted no Swap event");
    }

    function _count(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) n++;
        }
    }

    /// @notice The first test of every hook: what it declares is what its address carries.
    function _assertBits(address hook, uint160 expectedMask) internal pure {
        assertEq(_maskOf(IDeclaresPermissions(hook).getHookPermissions()), expectedMask, "declared permissions");
        assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, expectedMask, "the address's low 14 bits");
    }

    /// @notice Its permanent twin: at an address with one bit flipped, the constructor refuses.
    function _assertRefusedAt(bytes memory initcode, uint160 expectedMask, uint160 flipped) internal {
        (bool ok,) = _tryPlace(initcode, _flagAddress(expectedMask ^ flipped));
        assertFalse(ok, "the constructor accepted an address with other bits");
    }
}
