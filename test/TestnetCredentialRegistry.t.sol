// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {TestnetCredentialRegistry} from "../src/testnet/TestnetCredentialRegistry.sol";
import {DeployTestnetCredentialRegistry} from "../script/DeployTestnetCredentialRegistry.s.sol";
import {Testnets} from "../script/DeployHook.s.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract TestnetCredentialRegistryTest is HookTestBase {
    bytes32 internal constant KIND = keccak256("member");
    bytes32 internal constant OTHER_KIND = keccak256("something else");

    TestnetCredentialRegistry internal registry;
    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        registry = new TestnetCredentialRegistry(issuer);
    }

    // ── holding a credential ─────────────────────────────────────────────────────────────────

    function test_NobodyHoldsAnything_UntilGranted() public view {
        assertFalse(registry.hasValidCredential(alice, KIND), "alice holds a credential nobody granted");
        assertFalse(registry.hasValidCredential(address(0), KIND), "address zero holds a credential");
    }

    function test_AGrant_IsForOneAccount_AndOneKind() public {
        vm.prank(issuer);
        registry.grant(alice, KIND, uint64(block.timestamp + 1 days));

        assertTrue(registry.hasValidCredential(alice, KIND), "the grant did not take");
        assertFalse(registry.hasValidCredential(alice, OTHER_KIND), "the grant covered another kind");
        assertFalse(registry.hasValidCredential(bob, KIND), "the grant covered another account");
    }

    /// @dev Valid through the second named, and not one second longer.
    function test_AGrant_EndsAfterItsLastSecond() public {
        uint64 until = uint64(block.timestamp + 1 days);
        vm.prank(issuer);
        registry.grant(alice, KIND, until);

        vm.warp(until);
        assertTrue(registry.hasValidCredential(alice, KIND), "not valid in its last second");
        vm.warp(uint256(until) + 1);
        assertFalse(registry.hasValidCredential(alice, KIND), "still valid after its last second");
    }

    function test_Revoke_EndsItAtOnce() public {
        vm.startPrank(issuer);
        registry.grant(alice, KIND, uint64(block.timestamp + 1 days));
        registry.revoke(alice, KIND);
        vm.stopPrank();
        assertFalse(registry.hasValidCredential(alice, KIND), "a revoked credential is still valid");
    }

    function test_GrantingAgain_ReplacesTheExpiry_EvenWithAnEarlierOne() public {
        vm.startPrank(issuer);
        registry.grant(alice, KIND, uint64(block.timestamp + 30 days));
        registry.grant(alice, KIND, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        assertFalse(registry.hasValidCredential(alice, KIND), "the earlier expiry did not replace the later one");
    }

    function testFuzz_ValidExactlyUntilItsExpiry(uint64 until, uint64 at) public {
        until = uint64(bound(until, block.timestamp, type(uint64).max - 1));
        vm.prank(issuer);
        registry.grant(alice, KIND, until);

        vm.warp(at);
        assertEq(registry.hasValidCredential(alice, KIND), at <= until, "validity does not follow the expiry");
    }

    // ── who may grant ────────────────────────────────────────────────────────────────────────

    function testFuzz_RevertWhen_AnyoneButTheIssuerGrantsOrRevokes(address caller) public {
        vm.assume(caller != issuer);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(TestnetCredentialRegistry.NotIssuer.selector, caller));
        registry.grant(caller, KIND, type(uint64).max);
        vm.expectRevert(abi.encodeWithSelector(TestnetCredentialRegistry.NotIssuer.selector, caller));
        registry.revoke(alice, KIND);
        vm.stopPrank();
        assertFalse(registry.hasValidCredential(caller, KIND), "someone granted themselves a credential");
    }

    function test_RevertWhen_GrantingToAddressZero_OrIntoThePast() public {
        vm.startPrank(issuer);
        vm.expectRevert(TestnetCredentialRegistry.AccountNotSet.selector);
        registry.grant(address(0), KIND, type(uint64).max);

        uint64 past = uint64(block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(TestnetCredentialRegistry.AlreadyExpired.selector, past));
        registry.grant(alice, KIND, past);
        vm.stopPrank();
    }

    function test_RevertWhen_DeployedWithoutAnIssuer() public {
        vm.expectRevert(TestnetCredentialRegistry.IssuerNotSet.selector);
        new TestnetCredentialRegistry(address(0));
    }

    // ── the deploy script ────────────────────────────────────────────────────────────────────

    /// @dev The script from start to finish, with the official PoolManager's code stood at Sepolia's
    ///      address so its chain check passes as it would on the testnet.
    function test_Script_DeploysARegistry_WhoseIssuerIsTheOneNamed() public {
        _deployV4();
        DeployTestnetCredentialRegistry script = new DeployTestnetCredentialRegistry();
        IPoolManager sepoliaManager = script.poolManagerFor(block.chainid);
        vm.etch(address(sepoliaManager), address(manager).code);

        TestnetCredentialRegistry deployed = script.deploy(issuer);

        assertGt(address(deployed).code.length, 0, "nothing was deployed");
        assertEq(deployed.issuer(), issuer, "the registry has another issuer");
        assertFalse(deployed.hasValidCredential(issuer, KIND), "the issuer was given a credential at deployment");
    }

    function test_Script_RevertWhen_ChainIsNotATestnet_OrTheIssuerIsNotSet() public {
        _deployV4();
        DeployTestnetCredentialRegistry script = new DeployTestnetCredentialRegistry();
        IPoolManager sepoliaManager = script.poolManagerFor(block.chainid);
        vm.etch(address(sepoliaManager), address(manager).code);

        vm.expectRevert(DeployTestnetCredentialRegistry.IssuerNotSet.selector);
        script.deploy(address(0));

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Testnets.NotATestnetThisRepoDeploysTo.selector, 1));
        script.deploy(issuer);
    }
}
