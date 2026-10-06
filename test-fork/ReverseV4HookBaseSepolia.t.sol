// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ReverseV4Hook} from "../src/ReverseV4Hook.sol";
import {ICredential} from "../src/interfaces/ICredential.sol";
import {TestnetCredentialRegistry} from "../src/testnet/TestnetCredentialRegistry.sol";
import {DeployReverseV4Hook} from "../script/DeployReverseV4Hook.s.sol";
import {DemoReverseV4Hook} from "../script/DemoReverseV4Hook.s.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

interface IPositionManagerLike {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function poolManager() external view returns (IPoolManager);
}

interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Universal Router 2.1.2 is built on a newer v4-periphery than the one pinned here. Its
///      single-pool exact-input parameters carry one more field, `minHopPriceX36` (v4-periphery main,
///      read 2026-10-06). Encoding the pinned five-field struct makes the router revert while decoding.
struct ExactInputSingleParams_UR212 {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

interface IUniversalRouterLike {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice A rehearsal of ReverseV4Hook on a fork of Base Sepolia, against what is really there: the
///         official PoolManager and PositionManager, the routers a swapper would use, and the
///         credential registry deployed on 2026-10-06. It is run before the hook is deployed for
///         real, to find out which router can be trusted to say who is swapping.
/// @dev The hook is deployed here by the same script, with the same rates, that the hand-off runs.
contract ReverseV4HookBaseSepoliaTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84532;
    address internal constant POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNIVERSAL_ROUTER_2_1_2 = 0x8702463e73f74d0b6765aBceb314Ef07aCb92650;
    address internal constant HOOKMATE_ROUTER = 0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9;
    TestnetCredentialRegistry internal constant REGISTRY =
        TestnetCredentialRegistry(0xa9C3AaA0bca5f894bD5099Ef0308E28881C21186);

    bytes32 internal constant KIND = keccak256("member");
    bytes32 internal constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    int24 internal constant TICK_SPACING = 60;

    DeployReverseV4Hook internal script;
    IPoolManager internal manager;
    Currency internal currency0;
    Currency internal currency1;
    address internal issuer;
    address internal member = makeAddr("member");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC_URL"));
        assertEq(block.chainid, BASE_SEPOLIA, "the RPC is not Base Sepolia");

        script = new DeployReverseV4Hook();
        manager = script.poolManagerFor(block.chainid);
        issuer = REGISTRY.issuer();
        assertEq(address(IPositionManagerLike(POSITION_MANAGER).poolManager()), address(manager), "PositionManager");

        MockERC20 a = new MockERC20("Rehearsal A", "RA", 18);
        MockERC20 b = new MockERC20("Rehearsal B", "RB", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(t0));
        currency1 = Currency.wrap(address(t1));

        address[2] memory people = [member, stranger];
        for (uint256 i = 0; i < 2; i++) {
            for (uint256 j = 0; j < 2; j++) {
                MockERC20 token = j == 0 ? t0 : t1;
                token.mint(people[i], 1e24);
                vm.startPrank(people[i]);
                token.approve(PERMIT2, type(uint256).max);
                token.approve(HOOKMATE_ROUTER, type(uint256).max);
                IPermit2Like(PERMIT2).approve(address(token), POSITION_MANAGER, type(uint160).max, type(uint48).max);
                IPermit2Like(PERMIT2).approve(address(token), UNIVERSAL_ROUTER_2_1_2, type(uint160).max, type(uint48).max);
                vm.stopPrank();
            }
        }

        // The grant the hand-off will make, made here by the registry's real issuer.
        vm.prank(issuer);
        REGISTRY.grant(member, KIND, uint64(block.timestamp + 30 days));
    }

    function _deployAndOpenPool(address router) internal returns (ReverseV4Hook hook, PoolKey memory key) {
        hook = script.deploy(
            ReverseV4Hook.Config({
                credential: ICredential(address(REGISTRY)),
                credentialId: KIND,
                positionManager: POSITION_MANAGER,
                swapRouter: router,
                baseFee: script.BASE_FEE(),
                memberFee: script.MEMBER_FEE(),
                hookFee: script.HOOK_FEE(),
                bonusRate: script.BONUS_RATE(),
                treasury: issuer,
                treasuryShare: script.TREASURY_SHARE()
            })
        );
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, int24(-120), int24(120), uint256(100e18), type(uint128).max, type(uint128).max, member, bytes("")
        );
        params[1] = abi.encode(currency0, currency1);
        vm.prank(member);
        IPositionManagerLike(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _lastSwapFee(Vm.Log[] memory logs) internal view returns (uint24 fee) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "the PoolManager emitted no Swap event");
    }

    function _swapThroughUniversalRouter(PoolKey memory key, address who) internal returns (uint24 fee) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams_UR212({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e15,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, uint256(1e15));
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.recordLogs();
        vm.prank(who);
        IUniversalRouterLike(UNIVERSAL_ROUTER_2_1_2).execute(hex"10", inputs, block.timestamp); // 0x10: V4_SWAP
        return _lastSwapFee(vm.getRecordedLogs());
    }

    function _swapThroughHookmateRouter(PoolKey memory key, address who) internal returns (uint24 fee) {
        vm.recordLogs();
        vm.prank(who);
        IUniswapV4Router04(payable(HOOKMATE_ROUTER)).swap(-int256(1e15), 0, true, key, "", who, block.timestamp);
        return _lastSwapFee(vm.getRecordedLogs());
    }

    /// @dev The whole intended deployment, with Uniswap's own Universal Router as the trusted router.
    function test_WithUniversalRouter_2_1_2_AHolderPaysTheMemberFee_AndAStrangerTheBaseFee() public {
        (ReverseV4Hook hook, PoolKey memory key) = _deployAndOpenPool(UNIVERSAL_ROUTER_2_1_2);

        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x25EC, "the hook's address bits");
        assertEq(_swapThroughUniversalRouter(key, member), script.MEMBER_FEE(), "member's LP fee through the Universal Router");
        assertEq(_swapThroughUniversalRouter(key, stranger), script.BASE_FEE(), "stranger's LP fee through the Universal Router");

        // A holder who comes through any other router is not recognised.
        assertEq(_swapThroughHookmateRouter(key, member), script.BASE_FEE(), "member's LP fee through an untrusted router");
        assertGt(hook.pot(key.toId(), key.currency0), 0, "no hook fee reached the pot");
    }

    /// @dev The same, with the router this repository's tests use as the trusted one.
    function test_WithTheHookmateRouter_AHolderPaysTheMemberFee_AndAStrangerTheBaseFee() public {
        (, PoolKey memory key) = _deployAndOpenPool(HOOKMATE_ROUTER);

        assertEq(_swapThroughHookmateRouter(key, member), script.MEMBER_FEE(), "member's LP fee through the hookmate router");
        assertEq(_swapThroughHookmateRouter(key, stranger), script.BASE_FEE(), "stranger's LP fee through the hookmate router");
        assertEq(_swapThroughUniversalRouter(key, member), script.BASE_FEE(), "member's LP fee through an untrusted router");
    }

    /// @dev The money path on the fork: fees collected through the official PositionManager are
    ///      credited, claimed, and the treasury's share swept, all against the real PoolManager.
    function test_OnTheFork_TheBonusIsCreditedClaimed_AndTheTreasurySwept() public {
        (ReverseV4Hook hook, PoolKey memory key) = _deployAndOpenPool(UNIVERSAL_ROUTER_2_1_2);
        PoolId id = key.toId();
        uint256 tokenId = IPositionManagerLike(POSITION_MANAGER).nextTokenId() - 1;
        for (uint256 i = 0; i < 5; i++) {
            _swapThroughUniversalRouter(key, stranger);
        }

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, member);
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        uint256 before = token0.balanceOf(member);
        vm.prank(member);
        IPositionManagerLike(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp);
        uint256 fees = token0.balanceOf(member) - before;

        uint256 owed = hook.owed(member, currency0);
        assertGt(fees, 0, "the position earned no fees");
        assertEq(owed, fees * script.BONUS_RATE() / 1e6, "the bonus is not bonusRate of the fees collected");

        before = token0.balanceOf(member);
        vm.prank(member);
        hook.claim(currency0);
        assertEq(token0.balanceOf(member) - before, owed, "the claim did not pay what was owed");

        uint256 treasuryBefore = token0.balanceOf(issuer);
        uint256 swept = hook.sweep(id, currency0);
        assertEq(token0.balanceOf(issuer) - treasuryBefore, swept, "the sweep did not reach the treasury");
        assertLe(swept * 1e6, hook.feesTaken(id, currency0) * script.TREASURY_SHARE(), "the treasury took more than its share");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), hook.pot(id, currency0), "claims held != pot");
    }

    // ── the live-fire demo script, against the hook that is really deployed ─────────────────────

    ReverseV4Hook internal constant DEPLOYED_HOOK = ReverseV4Hook(0x03C77a74F3ecBc519F3590F5aff405a57401e5ec);

    /// @dev The demo script from start to finish, on the hook deployed on 2026-10-06. Inside a test the
    ///      script's sender is forge's default sender, so that address is granted the credential here
    ///      by the registry's real issuer; on the testnet the sender is the issuer, who already holds it.
    function test_TheDemoScript_RunsEndToEnd_AgainstTheDeployedHook() public {
        assertGt(address(DEPLOYED_HOOK).code.length, 0, "the hook is not deployed on this chain");
        (, address sender,) = vm.readCallers();
        vm.prank(issuer);
        REGISTRY.grant(sender, KIND, uint64(block.timestamp + 1 days));

        DemoReverseV4Hook demo = new DemoReverseV4Hook();
        DemoReverseV4Hook.Result memory r = demo.demo(DEPLOYED_HOOK, UNIVERSAL_ROUTER_2_1_2);

        assertEq(r.feeFirstSwap, 500, "LP fee of the first swap");
        assertEq(r.feeSecondSwap, 500, "LP fee of the second swap");
        assertGt(r.fees0, 0, "no LP fees in token0");
        assertGt(r.fees1, 0, "no LP fees in token1");
        assertEq(r.bonus0, r.fees0 * 150_000 / 1e6, "bonus in token0");
        assertEq(r.bonus1, r.fees1 * 150_000 / 1e6, "bonus in token1");
        assertGt(r.swept0, 0, "nothing was swept in token0");
        assertEq(DEPLOYED_HOOK.owed(sender, Currency.wrap(r.token0)), 0, "the bonus was not claimed");
    }

    /// @dev The script refuses a sender without the credential before it sends anything.
    function test_TheDemoScript_RevertWhen_TheSenderHoldsNoCredential() public {
        (, address sender,) = vm.readCallers();
        DemoReverseV4Hook demo = new DemoReverseV4Hook();
        vm.expectRevert(abi.encodeWithSelector(DemoReverseV4Hook.SenderHoldsNoCredential.selector, sender));
        demo.demo(DEPLOYED_HOOK, UNIVERSAL_ROUTER_2_1_2);
    }

    function test_TheDemoScript_RevertWhen_TheRouterIsNotTheHooksTrustedOne() public {
        DemoReverseV4Hook demo = new DemoReverseV4Hook();
        vm.expectRevert(
            abi.encodeWithSelector(DemoReverseV4Hook.RouterIsNotTheHooksTrustedRouter.selector, HOOKMATE_ROUTER)
        );
        demo.demo(DEPLOYED_HOOK, HOOKMATE_ROUTER);
    }
}
