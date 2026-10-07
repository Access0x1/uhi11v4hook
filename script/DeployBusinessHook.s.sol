// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {SameAddress} from "./SameAddress.s.sol";
import {BusinessReceiptHook} from "../src/business/BusinessReceiptHook.sol";
import {ClickReservHook} from "../src/business/ClickReservHook.sol";
import {ColmadoHook} from "../src/business/ColmadoHook.sol";
import {Access0x1Hook} from "../src/business/Access0x1Hook.sol";
import {SebasTNHook} from "../src/business/SebasTNHook.sol";
import {GitHatHook} from "../src/business/GitHatHook.sol";
import {QuantLHook} from "../src/business/QuantLHook.sol";
import {NFTeriaHook} from "../src/business/NFTeriaHook.sol";
import {AllFansHook} from "../src/business/AllFansHook.sol";
import {RebatoHook} from "../src/business/RebatoHook.sol";
import {HemiAIHook} from "../src/business/HemiAIHook.sol";
import {RealsleyHook} from "../src/business/RealsleyHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice One business's hook, at the same address on every testnet (SameAddress says how).
///
///     BUSINESS      which one: ClickReserv, Colmado, Access0x1, SebasTN, GitHat, QuantL, NFTeria,
///                   AllFans, Rebato, HemiAI or Realsley.
///     SWAP_ROUTER   optional. The one router believed about who is swapping; it must have code
///                   on this chain. Left out, every receipt's payer is empty.
///
///   Dry run (signs nothing, sends nothing). The same --sender on every chain:
///     BUSINESS=ClickReserv forge script script/DeployBusinessHook.s.sol:DeployBusinessHook \
///       --rpc-url <testnet rpc> --sender <signer>
///
///   On a local fork of a testnet (anvil --fork-url <testnet rpc>) the same command with
///   --rpc-url http://127.0.0.1:8545 --unlocked --broadcast sends it to the fork and nowhere else.
///   A real testnet run is the owner's to start.
contract DeployBusinessHook is SameAddress {
    /// @dev afterSwap, the one bit every business hook carries today.
    uint160 internal constant BUSINESS_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG);

    error UnknownBusiness(string name);
    error DeployedHookDiffers(string what);

    /// @notice The creation code of the hook called `name`. Reverts for a name with no hook.
    function codeOf(string memory name) public pure returns (bytes memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("ClickReserv")) return type(ClickReservHook).creationCode;
        if (h == keccak256("Colmado")) return type(ColmadoHook).creationCode;
        if (h == keccak256("Access0x1")) return type(Access0x1Hook).creationCode;
        if (h == keccak256("SebasTN")) return type(SebasTNHook).creationCode;
        if (h == keccak256("GitHat")) return type(GitHatHook).creationCode;
        if (h == keccak256("QuantL")) return type(QuantLHook).creationCode;
        if (h == keccak256("NFTeria")) return type(NFTeriaHook).creationCode;
        if (h == keccak256("AllFans")) return type(AllFansHook).creationCode;
        if (h == keccak256("Rebato")) return type(RebatoHook).creationCode;
        if (h == keccak256("HemiAI")) return type(HemiAIHook).creationCode;
        if (h == keccak256("Realsley")) return type(RealsleyHook).creationCode;
        revert UnknownBusiness(name);
    }

    /// @notice Where `sender` gets the hook called `name`, on every chain. Needs no chain.
    function businessAddress(address sender, string memory name) public pure returns (address hook) {
        codeOf(name); // an unknown name has no address
        (hook,) = find(sender, string.concat(name, "Hook"), BUSINESS_FLAGS);
    }

    /// @notice Deploy `name`'s hook as `sender`, trusting `router` (or none, for the zero address),
    ///         and read it back.
    function deployAs(address sender, string memory name, address router) public returns (BusinessReceiptHook hook) {
        IPoolManager manager = _checkChain();
        address[] memory routers = new address[](router == address(0) ? 0 : 1);
        if (router != address(0)) routers[0] = router;

        bytes memory code = abi.encodePacked(codeOf(name), abi.encode(manager, routers));
        hook = BusinessReceiptHook(_sendTo(sender, string.concat(name, "Hook"), BUSINESS_FLAGS, code));

        if (address(hook.poolManager()) != address(manager)) revert DeployedHookDiffers("poolManager");
        if (keccak256(bytes(hook.business())) != keccak256(bytes(name))) revert DeployedHookDiffers("business");
        if (router != address(0) && !hook.trustedRouter(router)) revert DeployedHookDiffers("swapRouter");
    }

    function run() external returns (BusinessReceiptHook hook) {
        string memory name = vm.envString("BUSINESS");
        address router = vm.envOr("SWAP_ROUTER", address(0));
        console2.log("chain id         ", block.chainid);
        console2.log("business         ", name);
        console2.log("sender           ", msg.sender);
        console2.log("same address     ", businessAddress(msg.sender, name));
        hook = deployAs(msg.sender, name, router);
        console2.log("deployed hook    ", address(hook));
        console2.log("it says it is    ", hook.business());
    }
}
