// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {Counter} from "../src/Counter.sol";
import {ReverseV4Hook} from "../src/ReverseV4Hook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice The manifests in context/ are what another AI reads instead of the code. This suite
///         fails when a manifest says something about a hook's permissions that the hook does not.
/// @dev The expected mask is never taken from the manifest: the hook is placed at a literal, and
///      the manifest is compared against what the hook itself declares.
contract ContextManifestTest is HookTestBase {
    uint160 internal constant COUNTER_MASK = 0x8C0;
    uint160 internal constant REVERSE_V4_HOOK_MASK = 0x25EC;

    function setUp() public {
        _deployV4();
    }

    function test_Counter_ManifestMatchesHook() public {
        address where = _flagAddress(COUNTER_MASK);
        _place(abi.encodePacked(type(Counter).creationCode, abi.encode(manager)), where);

        _assertManifestMatches("context/Counter.json", Counter(where).getHookPermissions());
    }

    /// @dev The constructor wants three contracts; the PoolManager stands in for each, since
    ///      getHookPermissions() reads none of them.
    function test_ReverseV4Hook_ManifestMatchesHook() public {
        address where = _flagAddress(REVERSE_V4_HOOK_MASK);
        address stand = address(manager);
        _place(
            abi.encodePacked(
                type(ReverseV4Hook).creationCode,
                abi.encode(
                    manager, stand, bytes32(0), stand, stand, uint24(3000), uint24(500), uint24(500), uint24(150_000)
                )
            ),
            where
        );

        _assertManifestMatches("context/ReverseV4Hook.json", ReverseV4Hook(where).getHookPermissions());
    }

    function _assertManifestMatches(string memory path, Hooks.Permissions memory p) internal view {
        string memory json = vm.readFile(path);

        // permissions.mask: the 14 bits, as the hook declares them
        assertEq(vm.parseJsonUint(json, ".permissions.mask"), _maskOf(p), "permissions.mask");

        // permissions.callbacks: the names of the callbacks, returns-delta flags excluded
        string[] memory listed = vm.parseJsonStringArray(json, ".permissions.callbacks");
        string[] memory declared = _callbackNames(p);
        assertEq(listed.length, declared.length, "permissions.callbacks: wrong number of entries");
        for (uint256 i = 0; i < declared.length; i++) {
            assertEq(listed[i], declared[i], "permissions.callbacks: wrong name or order");
        }

        bool anyReturnsDelta = p.beforeSwapReturnDelta || p.afterSwapReturnDelta || p.afterAddLiquidityReturnDelta
            || p.afterRemoveLiquidityReturnDelta;
        assertEq(vm.parseJsonBool(json, ".permissions.returnsDelta"), anyReturnsDelta, "permissions.returnsDelta");

        // hooklist.flags: Uniswap/hooklist's schema, which spells the last four "ReturnsDelta"
        _flag(json, "beforeInitialize", p.beforeInitialize);
        _flag(json, "afterInitialize", p.afterInitialize);
        _flag(json, "beforeAddLiquidity", p.beforeAddLiquidity);
        _flag(json, "afterAddLiquidity", p.afterAddLiquidity);
        _flag(json, "beforeRemoveLiquidity", p.beforeRemoveLiquidity);
        _flag(json, "afterRemoveLiquidity", p.afterRemoveLiquidity);
        _flag(json, "beforeSwap", p.beforeSwap);
        _flag(json, "afterSwap", p.afterSwap);
        _flag(json, "beforeDonate", p.beforeDonate);
        _flag(json, "afterDonate", p.afterDonate);
        _flag(json, "beforeSwapReturnsDelta", p.beforeSwapReturnDelta);
        _flag(json, "afterSwapReturnsDelta", p.afterSwapReturnDelta);
        _flag(json, "afterAddLiquidityReturnsDelta", p.afterAddLiquidityReturnDelta);
        _flag(json, "afterRemoveLiquidityReturnsDelta", p.afterRemoveLiquidityReturnDelta);

        // Claims that follow from other claims must agree with them.
        bool dynamicFee = vm.parseJsonBool(json, ".hooklist.properties.dynamicFee");
        bool needsHookData = vm.parseJsonBool(json, ".hooklist.properties.requiresCustomSwapData");
        bool swapReturnsDelta = p.beforeSwapReturnDelta || p.afterSwapReturnDelta;

        assertEq(vm.parseJsonBool(json, ".routing.needsHookData"), needsHookData, "routing.needsHookData");

        // Uniswap's routing article: a hook is picked up automatically unless it uses dynamic fees
        // or a swap returns-delta flag (or sits at a 0x91 address, which is a deployment matter).
        if (dynamicFee || swapReturnsDelta) {
            assertFalse(vm.parseJsonBool(json, ".routing.autoRoutable"), "routing.autoRoutable must be false");
        }
        // hooklist's classifier: never vanilla with a dynamic fee, required hookData, or swap returns-delta.
        if (dynamicFee || needsHookData || swapReturnsDelta) {
            assertFalse(vm.parseJsonBool(json, ".hooklist.properties.vanillaSwap"), "vanillaSwap must be false");
        }
        // ...and always vanilla with no swap callbacks at all.
        if (!p.beforeSwap && !p.afterSwap) {
            assertTrue(vm.parseJsonBool(json, ".hooklist.properties.vanillaSwap"), "vanillaSwap must be true");
        }
    }

    function _flag(string memory json, string memory name, bool declared) internal pure {
        string memory key = string.concat(".hooklist.flags.", name);
        assertEq(vm.parseJsonBool(json, key), declared, key);
    }

    /// @dev In Hooks.sol bit order, highest bit first.
    function _callbackNames(Hooks.Permissions memory p) internal pure returns (string[] memory names) {
        string[10] memory all = [
            "beforeInitialize",
            "afterInitialize",
            "beforeAddLiquidity",
            "afterAddLiquidity",
            "beforeRemoveLiquidity",
            "afterRemoveLiquidity",
            "beforeSwap",
            "afterSwap",
            "beforeDonate",
            "afterDonate"
        ];
        bool[10] memory on = [
            p.beforeInitialize,
            p.afterInitialize,
            p.beforeAddLiquidity,
            p.afterAddLiquidity,
            p.beforeRemoveLiquidity,
            p.afterRemoveLiquidity,
            p.beforeSwap,
            p.afterSwap,
            p.beforeDonate,
            p.afterDonate
        ];

        uint256 n;
        for (uint256 i = 0; i < 10; i++) {
            if (on[i]) n++;
        }
        names = new string[](n);
        uint256 j;
        for (uint256 i = 0; i < 10; i++) {
            if (on[i]) names[j++] = all[i];
        }
    }
}
