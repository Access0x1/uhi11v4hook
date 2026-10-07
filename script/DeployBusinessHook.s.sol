// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {SameAddress} from "./SameAddress.s.sol";
import {ICredential} from "../src/interfaces/ICredential.sol";
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

/// @dev What every hook built on BaseHook answers.
interface IDeployedHook {
    function poolManager() external view returns (IPoolManager);
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
}

/// @notice Any hook of src/business/, by name, at the same address on every testnet
///         (SameAddress says how). HOOK names it; the rest of the environment is that hook's
///         own constructor, read in `argsFromEnv`:
///
///   HOOK=Access0x1Hook    SWAP_ROUTER (optional)
///   HOOK=ClickReservHook  SWAP_ROUTER (optional), CREDENTIAL, CREDENTIAL_ID
///   HOOK=HemiAIHook       SWAP_ROUTER (optional), OPENS_AT, CLOSES_AT          (unix seconds)
///   HOOK=ColmadoHook      SWAP_ROUTER (optional), BASE_FEE, MEMBER_FEE, CREDENTIAL, CREDENTIAL_ID
///   HOOK=QuantLHook       SWAP_ROUTER (optional), BASE_FEE, WEEKEND_FEE
///   HOOK=RebatoHook       SWAP_ROUTER (optional), BASE_FEE, PROMO_FEE, STARTS_AT, ENDS_AT
///   HOOK=NFTeriaHook      SWAP_ROUTER, POSITION_MANAGER, COLLECTION
///   HOOK=RealsleyHook     SWAP_ROUTER, POSITION_MANAGER, CREDENTIAL, CREDENTIAL_ID
///   HOOK=GitHatHook       EXECUTORS (comma-separated addresses), MAX_INPUT
///   HOOK=SebasTNHook      POSITION_MANAGER
///   HOOK=AllFansHook      HOOK_FEE, TREASURY, CREATOR
///
///   Fees are in pips (1e6 = 100%). SWAP_ROUTER is the one router believed about who is swapping.
///   Left out, a receipt's payer is empty and a fee hook charges everyone its base fee; the two
///   gated pools need it, because without it nobody can swap.
///
///   Dry run (signs nothing, sends nothing). The same --sender on every chain:
///     HOOK=QuantLHook BASE_FEE=500 WEEKEND_FEE=10000 \
///       forge script script/DeployBusinessHook.s.sol:DeployBusinessHook --rpc-url <testnet rpc> --sender <signer>
///
///   On a local fork of a testnet (anvil --fork-url <testnet rpc>) the same command with
///   --rpc-url http://127.0.0.1:8545 --unlocked --broadcast sends it to the fork and nowhere else.
///   A real testnet run is the owner's to start.
///
/// @dev The settings are NOT part of the address: the same sender gets the same address for a
///      hook whatever it is deployed with. The script reads the PoolManager and the permission
///      bits back; the settings are the deployer's to read back (every one has a public getter).
contract DeployBusinessHook is SameAddress {
    error UnknownHook(string name);
    error DeployedHookDiffers(string what);

    /// @notice The 14 permission bits of the hook called `name`.
    function flagsOf(string memory name) public pure returns (uint160) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("Access0x1Hook") || h == keccak256("ClickReservHook") || h == keccak256("HemiAIHook")) {
            return uint160(Hooks.AFTER_SWAP_FLAG);
        }
        if (h == keccak256("ColmadoHook") || h == keccak256("QuantLHook") || h == keccak256("RebatoHook")) {
            return uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        }
        if (h == keccak256("NFTeriaHook") || h == keccak256("RealsleyHook")) {
            return uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
        }
        if (h == keccak256("GitHatHook")) return uint160(Hooks.BEFORE_SWAP_FLAG);
        if (h == keccak256("SebasTNHook")) {
            return uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        }
        if (h == keccak256("AllFansHook")) {
            return uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            );
        }
        revert UnknownHook(name);
    }

    /// @notice The creation code of the hook called `name`, without its constructor arguments.
    function codeOf(string memory name) public pure returns (bytes memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("Access0x1Hook")) return type(Access0x1Hook).creationCode;
        if (h == keccak256("ClickReservHook")) return type(ClickReservHook).creationCode;
        if (h == keccak256("HemiAIHook")) return type(HemiAIHook).creationCode;
        if (h == keccak256("ColmadoHook")) return type(ColmadoHook).creationCode;
        if (h == keccak256("QuantLHook")) return type(QuantLHook).creationCode;
        if (h == keccak256("RebatoHook")) return type(RebatoHook).creationCode;
        if (h == keccak256("NFTeriaHook")) return type(NFTeriaHook).creationCode;
        if (h == keccak256("RealsleyHook")) return type(RealsleyHook).creationCode;
        if (h == keccak256("GitHatHook")) return type(GitHatHook).creationCode;
        if (h == keccak256("SebasTNHook")) return type(SebasTNHook).creationCode;
        if (h == keccak256("AllFansHook")) return type(AllFansHook).creationCode;
        revert UnknownHook(name);
    }

    function _routersFromEnv() internal view returns (address[] memory routers) {
        address router = vm.envOr("SWAP_ROUTER", address(0));
        routers = new address[](router == address(0) ? 0 : 1);
        if (router != address(0)) routers[0] = router;
    }

    // Each value read below is a fee in pips or a unix time, far below the type it is cast to; a
    // value that is not is refused by the hook's own constructor or simply never matches a clock.
    // forge-lint: disable-start(unsafe-typecast)

    /// @notice The constructor arguments of the hook called `name`, read from the environment.
    function argsFromEnv(string memory name, IPoolManager manager) public view returns (bytes memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("Access0x1Hook")) return abi.encode(manager, _routersFromEnv());
        if (h == keccak256("ClickReservHook")) {
            return abi.encode(
                manager, _routersFromEnv(), ICredential(vm.envAddress("CREDENTIAL")), vm.envBytes32("CREDENTIAL_ID")
            );
        }
        if (h == keccak256("HemiAIHook")) {
            return
                abi.encode(manager, _routersFromEnv(), uint64(vm.envUint("OPENS_AT")), uint64(vm.envUint("CLOSES_AT")));
        }
        if (h == keccak256("ColmadoHook")) {
            return abi.encode(
                manager,
                uint24(vm.envUint("BASE_FEE")),
                _routersFromEnv(),
                ICredential(vm.envAddress("CREDENTIAL")),
                vm.envBytes32("CREDENTIAL_ID"),
                uint24(vm.envUint("MEMBER_FEE"))
            );
        }
        if (h == keccak256("QuantLHook")) {
            return
                abi.encode(
                    manager, uint24(vm.envUint("BASE_FEE")), _routersFromEnv(), uint24(vm.envUint("WEEKEND_FEE"))
                );
        }
        if (h == keccak256("RebatoHook")) {
            return abi.encode(
                manager,
                uint24(vm.envUint("BASE_FEE")),
                _routersFromEnv(),
                uint24(vm.envUint("PROMO_FEE")),
                uint64(vm.envUint("STARTS_AT")),
                uint64(vm.envUint("ENDS_AT"))
            );
        }
        if (h == keccak256("NFTeriaHook")) {
            return
                abi.encode(manager, _routersFromEnv(), vm.envAddress("POSITION_MANAGER"), vm.envAddress("COLLECTION"));
        }
        if (h == keccak256("RealsleyHook")) {
            return abi.encode(
                manager,
                _routersFromEnv(),
                vm.envAddress("POSITION_MANAGER"),
                ICredential(vm.envAddress("CREDENTIAL")),
                vm.envBytes32("CREDENTIAL_ID")
            );
        }
        if (h == keccak256("GitHatHook")) {
            return abi.encode(manager, vm.envAddress("EXECUTORS", ","), vm.envUint("MAX_INPUT"));
        }
        if (h == keccak256("SebasTNHook")) return abi.encode(manager, vm.envAddress("POSITION_MANAGER"));
        if (h == keccak256("AllFansHook")) {
            return
                abi.encode(manager, uint24(vm.envUint("HOOK_FEE")), vm.envAddress("TREASURY"), vm.envAddress("CREATOR"));
        }
        revert UnknownHook(name);
    }

    // forge-lint: disable-end(unsafe-typecast)

    function _mask(Hooks.Permissions memory p) private pure returns (uint160 mask) {
        if (p.beforeInitialize) mask |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) mask |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) mask |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) mask |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) mask |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) mask |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) mask |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) mask |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) mask |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) mask |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) mask |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) mask |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) mask |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) mask |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }

    /// @notice Where `sender` gets the hook called `name`, on every chain. Needs no chain.
    function hookAddress(address sender, string memory name) public pure returns (address hook) {
        (hook,) = find(sender, name, flagsOf(name));
    }

    /// @notice Deploy the hook called `name` as `sender` with these constructor arguments, and
    ///         read back what the address cannot prove: its PoolManager and its permission bits.
    function deployWith(address sender, string memory name, bytes memory args) public returns (address hook) {
        IPoolManager manager = _checkChain();
        uint160 flags = flagsOf(name);
        hook = _sendTo(sender, name, flags, abi.encodePacked(codeOf(name), args));

        if (address(IDeployedHook(hook).poolManager()) != address(manager)) revert DeployedHookDiffers("poolManager");
        if (_mask(IDeployedHook(hook).getHookPermissions()) != flags) revert DeployedHookDiffers("permissions");
    }

    function run() external returns (address hook) {
        string memory name = vm.envString("HOOK");
        IPoolManager manager = _checkChain();
        console2.log("chain id         ", block.chainid);
        console2.log("hook             ", name);
        console2.log("sender           ", msg.sender);
        console2.log("same address     ", hookAddress(msg.sender, name));
        hook = deployWith(msg.sender, name, argsFromEnv(name, manager));
        console2.log("deployed hook    ", hook);
        console2.log("code size        ", hook.code.length);
    }
}
