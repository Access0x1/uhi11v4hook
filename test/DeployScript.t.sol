// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {Counter} from "../src/Counter.sol";
import {DeployHook, Testnets} from "../script/DeployHook.s.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice The deploy script's two decisions, tested without a chain: which chains it will run on,
///         and which address it mines. The broadcast path itself is rehearsed on a fork
///         (sessions/2026-10-15-thu-w04-testing-deploying/SESSION.md).
contract DeployScriptTest is HookTestBase {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant EXPECTED_MASK = 0x8C0;

    DeployHook internal script;

    function setUp() public {
        _deployV4();
        script = new DeployHook();
    }

    // ── which chains ─────────────────────────────────────────────────────────────────────────

    function test_PoolManager_IsKnownForTheThreeTestnets() public view {
        assertEq(address(script.poolManagerFor(11155111)), 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, "Sepolia");
        assertEq(address(script.poolManagerFor(84532)), 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408, "Base Sepolia");
        assertEq(address(script.poolManagerFor(1301)), 0x00B036B58a818B1BC34d502D3fE730Db729e62AC, "Unichain Sepolia");
    }

    function test_RevertWhen_ChainIsEthereumMainnet() public {
        vm.expectRevert(abi.encodeWithSelector(Testnets.NotATestnetThisRepoDeploysTo.selector, 1));
        script.poolManagerFor(1);
    }

    function testFuzz_RevertWhen_ChainIsNotOneOfTheThree(uint256 chainId) public {
        vm.assume(chainId != 11155111 && chainId != 84532 && chainId != 1301);
        vm.expectRevert(abi.encodeWithSelector(Testnets.NotATestnetThisRepoDeploysTo.selector, chainId));
        script.poolManagerFor(chainId);
    }

    // ── which address ────────────────────────────────────────────────────────────────────────

    function test_MinedAddress_CarriesTheMask_AndIsNot0x91() public view {
        (address hook,) = script.mine(CREATE2_DEPLOYER, manager);

        assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, EXPECTED_MASK, "mined address does not end in 0x8C0");
        assertTrue(uint160(hook) >> 152 != 0x91, "mined address starts with 0x91");
    }

    /// @dev The real thing, minus the chain: send salt ++ initcode to the CREATE2 deployer, as
    ///      `forge script` does for `new Counter{salt: salt}(manager)`. The hook's constructor
    ///      runs at the mined address and accepts it.
    function test_DeployingThroughTheCreate2Deployer_LandsOnTheMinedAddress() public {
        assertGt(CREATE2_DEPLOYER.code.length, 0, "no CREATE2 deployer in this test environment");
        (address expected, bytes32 salt) = script.mine(CREATE2_DEPLOYER, manager);

        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, script.initcode(manager)));

        assertTrue(ok, "the CREATE2 deployment reverted");
        assertGt(expected.code.length, 0, "no code at the mined address");
        assertEq(_maskOf(Counter(expected).getHookPermissions()), EXPECTED_MASK, "something else was deployed");
        assertEq(address(Counter(expected).poolManager()), address(manager), "bound to another PoolManager");
    }

    /// @dev A salt belongs to one deployer. Mined for anyone else, the same salt gives an address
    ///      whose bits are wrong, and the hook's constructor refuses it.
    function test_RevertWhen_TheSaltWasMinedForAnotherDeployer() public {
        (address expected, bytes32 salt) = script.mine(address(this), manager);

        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, script.initcode(manager)));

        assertFalse(ok, "a salt mined for another deployer was accepted");
        assertEq(expected.code.length, 0, "code appeared at the address mined for the other deployer");
    }

    /// @dev The constructor argument is part of the creation code, so a different PoolManager
    ///      means a different address: nothing mined for one chain can be reused on another
    ///      unless the PoolManager address is the same there.
    function test_MinedAddress_DependsOnThePoolManager() public view {
        (address here,) = script.mine(CREATE2_DEPLOYER, manager);
        (address sepolia,) = script.mine(CREATE2_DEPLOYER, script.poolManagerFor(11155111));
        assertTrue(here != sepolia, "two PoolManagers gave one hook address");
    }
}
