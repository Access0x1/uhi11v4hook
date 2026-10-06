// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {SettableCredential} from "./ReverseV4Hook.t.sol";
import {ReverseV4Hook} from "../src/ReverseV4Hook.sol";
import {ICredential} from "../src/interfaces/ICredential.sol";
import {DeployReverseV4Hook} from "../script/DeployReverseV4Hook.s.sol";
import {Testnets} from "../script/DeployHook.s.sol";

import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice The deploy script for ReverseV4Hook, run from start to finish without a chain: the test
///         stands the official PoolManager's code at Sepolia's address, so `run()` takes the same
///         path it takes on the testnet, including its checks before and after.
contract DeployReverseV4HookScriptTest is HookTestBase {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant EXPECTED_MASK = 0x25EC;
    bytes32 internal constant KIND = keccak256("member");

    DeployReverseV4Hook internal script;
    IPoolManager internal sepoliaManager;
    address internal credential;
    address internal positionManager;
    address internal router;
    address internal permit2;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        _deployV4(); // also sets the chain id to Sepolia's
        script = new DeployReverseV4Hook();

        sepoliaManager = script.poolManagerFor(block.chainid);
        vm.etch(address(sepoliaManager), address(manager).code);

        permit2 = Permit2Deployer.deploy();
        credential = address(new SettableCredential());
        positionManager =
            V4PositionManagerDeployer.deploy(address(sepoliaManager), permit2, 300_000, address(0), address(0));
        router = V4RouterDeployer.deploy(address(sepoliaManager), permit2);
    }

    /// @dev The configuration `run()` would read from the environment, built directly. Tests run side
    ///      by side in one process and the environment is shared, so only one test below sets it.
    function _config(address credential_, address positionManager_, address router_, address treasury_)
        internal
        view
        returns (ReverseV4Hook.Config memory)
    {
        return ReverseV4Hook.Config({
            credential: ICredential(credential_),
            credentialId: KIND,
            positionManager: positionManager_,
            swapRouter: router_,
            baseFee: script.BASE_FEE(),
            memberFee: script.MEMBER_FEE(),
            hookFee: script.HOOK_FEE(),
            bonusRate: script.BONUS_RATE(),
            treasury: treasury_,
            treasuryShare: script.TREASURY_SHARE()
        });
    }

    function _good() internal view returns (ReverseV4Hook.Config memory) {
        return _config(credential, positionManager, router, treasury);
    }

    // ── the rates ────────────────────────────────────────────────────────────────────────────

    /// @dev The numbers the hook was tested with, as literals, so a change to the script fails here.
    function test_TheScriptDeploysTheRatesTheHookWasTestedWith() public view {
        assertEq(script.BASE_FEE(), 3000, "base fee");
        assertEq(script.MEMBER_FEE(), 500, "member fee");
        assertEq(script.HOOK_FEE(), 500, "hook fee");
        assertEq(script.BONUS_RATE(), 150_000, "bonus rate");
        assertEq(script.TREASURY_SHARE(), 99_000, "treasury share is not 9.9%");
    }

    /// @dev 9.9% + 90% = 99.9% of each hook fee is spoken for; a tenth of a percent is left for rounding.
    function test_TheTreasuryShare_LeavesATenthOfAPercentForRounding() public view {
        assertEq(script.roundingMargin(), 1000, "rounding margin, in pips of the hook fee");
    }

    // ── the whole run ────────────────────────────────────────────────────────────────────────

    /// @dev The only test that touches the environment: `run()` reads the five addresses from it,
    ///      takes the five rates from the script, and deploys.
    function test_Run_ReadsTheAddressesFromTheEnvironment_AndTheRatesFromTheScript() public {
        vm.setEnv("CREDENTIAL", vm.toString(credential));
        vm.setEnv("CREDENTIAL_ID", vm.toString(KIND));
        vm.setEnv("POSITION_MANAGER", vm.toString(positionManager));
        vm.setEnv("SWAP_ROUTER", vm.toString(router));
        vm.setEnv("TREASURY", vm.toString(treasury));

        assertEq(keccak256(abi.encode(script.config())), keccak256(abi.encode(_good())), "config() differs");
        ReverseV4Hook hook = script.run();
        assertEq(hook.treasuryShare(), 99_000, "treasury share on chain");
    }

    function test_Deploy_LandsOnTheMinedAddress_WithTheConfiguredValues() public {
        (address expected,) = script.mineFor(CREATE2_DEPLOYER, sepoliaManager, _good());
        assertEq(uint160(expected) & Hooks.ALL_HOOK_MASK, EXPECTED_MASK, "mined address does not end in 0x25EC");
        assertTrue(uint160(expected) >> 152 != 0x91, "mined address starts with 0x91");

        ReverseV4Hook hook = script.deploy(_good());

        assertEq(address(hook), expected, "deployed somewhere other than the mined address");
        assertEq(_maskOf(hook.getHookPermissions()), EXPECTED_MASK, "something else was deployed");
        assertEq(address(hook.poolManager()), address(sepoliaManager), "bound to another PoolManager");
        assertEq(hook.treasuryShare(), 99_000, "treasury share on chain");
        assertEq(hook.treasury(), treasury, "treasury on chain");
        assertEq(hook.positionManager(), positionManager, "PositionManager on chain");
        assertTrue(hook.trustedRouter(router), "the router is not trusted on chain");
        assertEq(address(hook.credential()), credential, "credential registry on chain");
        assertEq(hook.credentialId(), KIND, "credential kind on chain");
    }

    /// @dev A second run finds code at the first address, mines the next one, and deploys there:
    ///      it never overwrites and never reports the old hook as new.
    function test_Deploy_Twice_PutsASecondHookAtAnotherAddress() public {
        ReverseV4Hook first = script.deploy(_good());
        ReverseV4Hook second = script.deploy(_good());
        assertTrue(address(first) != address(second), "the second run returned the first hook");
        assertGt(address(second).code.length, 0, "the second run deployed nothing");
    }

    // ── what stops it before anything is sent ────────────────────────────────────────────────

    function test_RevertWhen_TheCredentialRegistryHasNoCode() public {
        address nothing = makeAddr("no code here");
        ReverseV4Hook.Config memory c = _config(nothing, positionManager, router, treasury);
        vm.expectRevert(abi.encodeWithSelector(DeployReverseV4Hook.NoCodeAt.selector, "CREDENTIAL", nothing));
        script.deploy(c);
    }

    function test_RevertWhen_TheRouterHasNoCode() public {
        address nothing = makeAddr("no code here");
        ReverseV4Hook.Config memory c = _config(credential, positionManager, nothing, treasury);
        vm.expectRevert(abi.encodeWithSelector(DeployReverseV4Hook.NoCodeAt.selector, "SWAP_ROUTER", nothing));
        script.deploy(c);
    }

    function test_RevertWhen_TheTreasuryIsNotSet() public {
        ReverseV4Hook.Config memory c = _config(credential, positionManager, router, address(0));
        vm.expectRevert(DeployReverseV4Hook.TreasuryNotSet.selector);
        script.deploy(c);
    }

    /// @dev A real PositionManager, for the PoolManager this test deployed rather than Sepolia's: the
    ///      mistake of taking an address from another chain.
    function test_RevertWhen_ThePositionManagerIsForAnotherPoolManager() public {
        address other = V4PositionManagerDeployer.deploy(address(manager), permit2, 300_000, address(0), address(0));
        ReverseV4Hook.Config memory c = _config(credential, other, router, treasury);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployReverseV4Hook.PositionManagerIsForAnotherPoolManager.selector, other, address(manager)
            )
        );
        script.deploy(c);
    }

    function test_RevertWhen_ChainIsNotATestnet() public {
        ReverseV4Hook.Config memory c = _good();
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Testnets.NotATestnetThisRepoDeploysTo.selector, 1));
        script.deploy(c);
    }

    // ── what catches a wrong deployment afterwards ───────────────────────────────────────────

    /// @dev The check after deployment, given a hook deployed with another treasury share.
    function test_CheckAfter_RejectsAHookDeployedWithAnotherShare() public {
        ReverseV4Hook.Config memory c = _good();
        ReverseV4Hook.Config memory wrong = _good();
        wrong.treasuryShare = 50_000;

        (address where, bytes32 salt) = script.mineFor(CREATE2_DEPLOYER, sepoliaManager, wrong);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, script.initcodeFor(sepoliaManager, wrong)));
        assertTrue(ok, "the stand-in deployment reverted");

        vm.expectRevert(abi.encodeWithSelector(DeployReverseV4Hook.DeployedHookDiffers.selector, "treasuryShare"));
        script.checkAfter(ReverseV4Hook(where), sepoliaManager, c);
    }
}
