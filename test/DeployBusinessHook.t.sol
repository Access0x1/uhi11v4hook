// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {IDeclaresPermissions} from "./utils/BusinessKit.sol";
import {DeployBusinessHook, IDeployedHook} from "../script/DeployBusinessHook.s.sol";
import {SameAddress} from "../script/SameAddress.s.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @dev Anything with code: the constructors here only ask that an address is a contract.
contract Stand {}

/// @notice script/DeployBusinessHook.s.sol without a chain, through CreateX's real code: every
///         hook of src/business/ lands on one address on two testnets, with different settings on
///         each, and carries its own bits. What each hook DOES is in test/business/.
contract DeployBusinessHookTest is HookTestBase {
    uint256 internal constant BASE_SEPOLIA = 84532;

    address internal owner = makeAddr("the owner's signer");
    DeployBusinessHook internal script;
    bytes internal managerCode;

    function _names() internal pure returns (string[11] memory) {
        return [
            "Access0x1Hook",
            "ClickReservHook",
            "HemiAIHook",
            "ColmadoHook",
            "QuantLHook",
            "RebatoHook",
            "NFTeriaHook",
            "RealsleyHook",
            "GitHatHook",
            "SebasTNHook",
            "AllFansHook"
        ];
    }

    /// @dev The masks as literals, in the order of `_names()`, so a wrong row in the script's
    ///      table fails here rather than agreeing with itself.
    function _masks() internal pure returns (uint160[11] memory) {
        return [uint160(0x40), 0x40, 0x40, 0x2080, 0x2080, 0x2080, 0x880, 0x880, 0x80, 0x500, 0xCC];
    }

    function setUp() public {
        _deployV4(); // the chain id is Sepolia's from here
        managerCode = address(manager).code;
        vm.etch(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed, vm.parseBytes(vm.readFile("test/fixtures/createx.hex")));
        script = new DeployBusinessHook();
    }

    function _onChain(uint256 chainId) internal returns (IPoolManager there) {
        vm.chainId(chainId);
        there = script.poolManagerFor(chainId);
        vm.etch(address(there), managerCode);
    }

    /// @dev Constructor arguments for the hook called `name`, with this chain's own stand-ins and
    ///      `n` mixed into every number, so two chains never share a setting.
    function _args(string memory name, IPoolManager m, uint24 n) internal returns (bytes memory) {
        address a = address(new Stand());
        address b = address(new Stand());
        address[] memory routers = new address[](1);
        routers[0] = a;
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("Access0x1Hook")) return abi.encode(m, routers);
        if (h == keccak256("ClickReservHook")) return abi.encode(m, routers, b, bytes32(uint256(n)));
        if (h == keccak256("HemiAIHook")) return abi.encode(m, routers, uint64(n), uint64(n) + 100);
        if (h == keccak256("ColmadoHook")) return abi.encode(m, uint24(3000) + n, routers, b, bytes32(uint256(n)), n);
        if (h == keccak256("QuantLHook")) return abi.encode(m, uint24(500) + n, routers, uint24(10_000) + n);
        if (h == keccak256("RebatoHook")) return abi.encode(m, uint24(3000) + n, routers, n, uint64(n), uint64(n) + 9);
        if (h == keccak256("NFTeriaHook")) return abi.encode(m, routers, b, a);
        if (h == keccak256("RealsleyHook")) return abi.encode(m, routers, b, a, bytes32(uint256(n)));
        if (h == keccak256("GitHatHook")) return abi.encode(m, routers, uint256(n) + 1);
        if (h == keccak256("SebasTNHook")) return abi.encode(m, b);
        return abi.encode(m, uint24(100) + n, a, b); // AllFansHook
    }

    function test_EveryHook_LandsOnOneAddress_OnTwoTestnets_WithItsOwnBits() public {
        string[11] memory names = _names();
        uint160[11] memory masks = _masks();
        address[11] memory onSepolia;
        uint256 clean = vm.snapshotState();

        IPoolManager sepolia = _onChain(SEPOLIA);
        for (uint256 i = 0; i < names.length; i++) {
            address hook = script.deployWith(owner, names[i], _args(names[i], sepolia, 1));
            onSepolia[i] = hook;
            assertEq(hook, script.hookAddress(owner, names[i]), names[i]);
            assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, masks[i], names[i]);
            assertEq(_maskOf(IDeclaresPermissions(hook).getHookPermissions()), masks[i], names[i]);
            assertTrue(uint160(hook) >> 152 != 0x91, names[i]);
            assertEq(address(IDeployedHook(hook).poolManager()), address(sepolia), names[i]);
            for (uint256 j = 0; j < i; j++) {
                assertTrue(hook != onSepolia[j], "two hooks share an address");
            }
        }

        vm.revertToState(clean);
        IPoolManager base = _onChain(BASE_SEPOLIA);
        new Stand(); // spend a nonce, so this chain's stand-ins are not the first chain's
        for (uint256 i = 0; i < names.length; i++) {
            address hook = script.deployWith(owner, names[i], _args(names[i], base, 7));
            assertEq(hook, onSepolia[i], names[i]);
            assertEq(address(IDeployedHook(hook).poolManager()), address(base), names[i]);
        }
    }

    function test_AnotherSender_GetsAnotherAddress_ForEveryHook() public {
        string[11] memory names = _names();
        address other = makeAddr("another signer");
        for (uint256 i = 0; i < names.length; i++) {
            assertTrue(script.hookAddress(owner, names[i]) != script.hookAddress(other, names[i]), names[i]);
        }
    }

    function test_RevertWhen_TheHookIsUnknown_OrDeployedTwice_OrItsOwnConstructorRefuses() public {
        IPoolManager sepolia = _onChain(SEPOLIA);
        vm.expectRevert(abi.encodeWithSelector(DeployBusinessHook.UnknownHook.selector, "NobodyHook"));
        script.flagsOf("NobodyHook");

        bytes memory args = _args("Access0x1Hook", sepolia, 1);
        address first = script.deployWith(owner, "Access0x1Hook", args);
        vm.expectRevert(abi.encodeWithSelector(SameAddress.AlreadyDeployed.selector, first));
        script.deployWith(owner, "Access0x1Hook", args);

        // A promotion that never runs: RebatoHook's constructor refuses, and nothing lands.
        address[] memory none = new address[](0);
        bytes memory bad = abi.encode(sepolia, uint24(3000), none, uint24(100), uint64(50), uint64(50));
        address where = script.hookAddress(owner, "RebatoHook");
        vm.expectRevert();
        script.deployWith(owner, "RebatoHook", bad);
        assertEq(where.code.length, 0, "a refused run deployed something");
    }

    function test_RevertWhen_TheChainIsAMainnet() public {
        vm.chainId(1);
        vm.expectRevert();
        script.deployWith(owner, "Access0x1Hook", "");
    }
}
