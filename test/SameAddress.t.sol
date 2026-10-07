// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {SettableCredential} from "./ReverseV4Hook.t.sol";
import {Counter} from "../src/Counter.sol";
import {ReverseV4Hook} from "../src/ReverseV4Hook.sol";
import {ICredential} from "../src/interfaces/ICredential.sol";
import {Testnets} from "../script/DeployHook.s.sol";
import {DeployReverseV4Hook} from "../script/DeployReverseV4Hook.s.sol";
import {
    SameAddress,
    DeployHookSameAddress,
    DeployReverseV4HookSameAddress,
    ICreateXFactory
} from "../script/SameAddress.s.sol";

import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice One address on every testnet (script/SameAddress.s.sol), without a chain. CreateX here
///         is its real runtime code: test/fixtures/createx.hex was read with `cast code` from
///         Sepolia on 2026-10-07, and Base Sepolia and Unichain Sepolia answered the same hash.
/// @dev "Another chain" in one process: roll the state back to before the deployment, change the
///      chain id, and stand the official PoolManager at THAT chain's address. Each chain gets its
///      own PositionManager, router, credential registry and treasury.
contract SameAddressTest is HookTestBase {
    ICreateXFactory internal constant FACTORY = ICreateXFactory(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    bytes32 internal constant FACTORY_CODEHASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint160 internal constant COUNTER_MASK = 0x8C0;
    uint160 internal constant REVERSE_MASK = 0x25EC;
    bytes32 internal constant KIND = keccak256("member");

    address internal owner = makeAddr("the owner's signer");
    address internal stranger = makeAddr("stranger");
    bytes internal managerCode;

    DeployHookSameAddress internal counterScript;
    DeployReverseV4HookSameAddress internal reverseScript;

    function setUp() public {
        _deployV4(); // the chain id is Sepolia's from here
        managerCode = address(manager).code;
        vm.etch(address(FACTORY), vm.parseBytes(vm.readFile("test/fixtures/createx.hex")));
        counterScript = new DeployHookSameAddress();
        reverseScript = new DeployReverseV4HookSameAddress();
    }

    /// @dev Makes this process look like `chainId`: its id, and the official PoolManager's code at
    ///      the address the scripts expect on that chain.
    function _onChain(uint256 chainId) internal returns (IPoolManager there) {
        vm.chainId(chainId);
        there = counterScript.poolManagerFor(chainId);
        vm.etch(address(there), managerCode);
    }

    /// @dev A chain's own parts for ReverseV4Hook, all freshly deployed, so none repeats elsewhere.
    function _config(IPoolManager there, address treasury) internal returns (ReverseV4Hook.Config memory) {
        DeployReverseV4Hook rules = reverseScript.rules();
        address permit2 = Permit2Deployer.deploy();
        return ReverseV4Hook.Config({
            credential: ICredential(address(new SettableCredential())),
            credentialId: KIND,
            positionManager: V4PositionManagerDeployer.deploy(address(there), permit2, 300_000, address(0), address(0)),
            swapRouter: V4RouterDeployer.deploy(address(there), permit2),
            baseFee: rules.BASE_FEE(),
            memberFee: rules.MEMBER_FEE(),
            hookFee: rules.HOOK_FEE(),
            bonusRate: rules.BONUS_RATE(),
            treasury: treasury,
            treasuryShare: rules.TREASURY_SHARE()
        });
    }

    // ── the instrument: this is CreateX, and the arithmetic is CreateX's ─────────────────────

    function test_TheFixtureIsCreateXAsItIsOnTheTestnets() public view {
        assertEq(address(FACTORY).codehash, FACTORY_CODEHASH, "test/fixtures/createx.hex is not CreateX");
    }

    function testFuzz_LandsAt_IsTheAddressCreateXComputes(address sender, uint64 attempt) public view {
        bytes32 salt = counterScript.saltOf(sender, "Counter", attempt);
        // What CreateX hashes for a salt that begins with its sender and has 0x00 next.
        bytes32 tied = keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt));
        assertEq(counterScript.landsAt(sender, salt), FACTORY.computeCreate3Address(tied), "not CreateX's address");
    }

    function test_TheSalt_BeginsWithTheSender_ThenAZeroByte() public view {
        bytes32 salt = counterScript.saltOf(owner, "Counter", 3);
        assertEq(address(bytes20(salt)), owner, "the salt does not begin with the sender");
        assertEq(uint8(salt[20]), 0, "byte 20 is not 0x00, so the chain id would be mixed in");
    }

    // ── Counter ──────────────────────────────────────────────────────────────────────────────

    function test_Counter_SameAddressOnAllThreeTestnets() public {
        address expected = counterScript.counterAddress(owner);
        assertEq(uint160(expected) & Hooks.ALL_HOOK_MASK, COUNTER_MASK, "the address does not end in 0x8C0");
        assertTrue(uint160(expected) >> 152 != 0x91, "the address starts with 0x91");

        uint256[3] memory chains = [SEPOLIA, BASE_SEPOLIA, UNICHAIN_SEPOLIA];
        uint256 clean = vm.snapshotState();
        for (uint256 i = 0; i < chains.length; i++) {
            vm.revertToState(clean);
            clean = vm.snapshotState();
            IPoolManager there = _onChain(chains[i]);
            assertEq(expected.code.length, 0, "the last chain's hook is still here");

            Counter hook = counterScript.deployAs(owner);

            assertEq(address(hook), expected, "another address on this chain");
            assertEq(address(hook.poolManager()), address(there), "bound to another chain's PoolManager");
            assertEq(_maskOf(hook.getHookPermissions()), COUNTER_MASK, "something else was deployed");
        }
    }

    // ── ReverseV4Hook ────────────────────────────────────────────────────────────────────────

    /// @dev Every address the hook is built with differs between the two chains. With CREATE2
    ///      each of them would have moved the hook.
    function test_ReverseV4Hook_SameAddress_WhateverTheChainsOwnParts() public {
        address expected = reverseScript.reverseAddress(owner);
        assertEq(uint160(expected) & Hooks.ALL_HOOK_MASK, REVERSE_MASK, "the address does not end in 0x25EC");
        uint256 clean = vm.snapshotState();

        IPoolManager sepolia = _onChain(SEPOLIA);
        ReverseV4Hook.Config memory a = _config(sepolia, makeAddr("treasury on Sepolia"));
        ReverseV4Hook first = reverseScript.deployAs(owner, a);
        assertEq(address(first), expected, "Sepolia");
        assertEq(first.treasury(), a.treasury, "Sepolia: treasury");

        vm.revertToState(clean);
        IPoolManager base = _onChain(BASE_SEPOLIA);
        // Spend a nonce so nothing this test deploys repeats the first chain's addresses.
        new SettableCredential();
        ReverseV4Hook.Config memory b = _config(base, makeAddr("treasury on Base Sepolia"));
        assertTrue(b.positionManager != a.positionManager, "the two chains share a PositionManager");
        assertTrue(address(b.credential) != address(a.credential), "the two chains share a registry");
        ReverseV4Hook second = reverseScript.deployAs(owner, b);
        assertEq(address(second), expected, "Base Sepolia");
        assertEq(address(second.poolManager()), address(base), "Base Sepolia: PoolManager");
        assertEq(second.positionManager(), b.positionManager, "Base Sepolia: PositionManager");
        assertEq(second.treasury(), b.treasury, "Base Sepolia: treasury");
        assertEq(second.treasuryShare(), 99_000, "Base Sepolia: the rates are the tested ones");
    }

    function test_CounterAndReverseV4Hook_DoNotShareAnAddress_NorDoTwoSenders() public view {
        assertTrue(counterScript.counterAddress(owner) != reverseScript.reverseAddress(owner), "two hooks, one address");
        assertTrue(counterScript.counterAddress(owner) != counterScript.counterAddress(stranger), "two senders");
    }

    // ── what is refused ──────────────────────────────────────────────────────────────────────

    /// @dev The owner has deployed on one chain and not yet on this one. A stranger who copies the
    ///      salt and the code cannot put anything at the owner's address here.
    function test_AStrangerWithTheOwnersSalt_CannotTakeTheAddress() public {
        (address owned, bytes32 salt) = counterScript.find(owner, "Counter", COUNTER_MASK);
        bytes memory code = counterScript.initcode(counterScript.poolManagerFor(SEPOLIA));
        vm.etch(address(counterScript.poolManagerFor(SEPOLIA)), managerCode);

        vm.prank(stranger);
        try FACTORY.deployCreate3(salt, code) returns (address landed) {
            assertTrue(landed != owned, "a stranger landed on the owner's address");
        } catch {}
        assertEq(owned.code.length, 0, "something is at the owner's address");

        assertEq(address(counterScript.deployAs(owner)), owned, "the owner no longer gets the address");
    }

    function test_RevertWhen_RunTwiceOnOneChain() public {
        _onChain(SEPOLIA);
        address hook = address(counterScript.deployAs(owner));
        vm.expectRevert(abi.encodeWithSelector(SameAddress.AlreadyDeployed.selector, hook));
        counterScript.deployAs(owner);
    }

    function test_RevertWhen_TheChainIsAMainnet() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Testnets.NotATestnetThisRepoDeploysTo.selector, 1));
        counterScript.deployAs(owner);
    }

    function test_RevertWhen_CreateXIsMissing_OrIsOtherCode() public {
        _onChain(SEPOLIA);
        vm.etch(address(FACTORY), hex"00");
        vm.expectRevert(abi.encodeWithSelector(SameAddress.CreateXHasOtherCode.selector, keccak256(hex"00")));
        counterScript.deployAs(owner);

        vm.etch(address(FACTORY), "");
        vm.expectRevert(SameAddress.CreateXIsNotOnThisChain.selector);
        counterScript.deployAs(owner);
    }

    /// @dev The checks DeployReverseV4Hook makes before sending still stop this script.
    function test_RevertWhen_ReverseV4HooksOwnChecksFail() public {
        IPoolManager sepolia = _onChain(SEPOLIA);
        ReverseV4Hook.Config memory c = _config(sepolia, address(0));
        vm.expectRevert(DeployReverseV4Hook.TreasuryNotSet.selector);
        reverseScript.deployAs(owner, c);
        assertEq(reverseScript.reverseAddress(owner).code.length, 0, "a refused run deployed something");
    }
}
