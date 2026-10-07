// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {Testnets} from "./DeployHook.s.sol";
import {DeployReverseV4Hook} from "./DeployReverseV4Hook.s.sol";
import {Counter} from "../src/Counter.sol";
import {ReverseV4Hook} from "../src/ReverseV4Hook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice CreateX, the public deployment factory (github.com/pcaversaccio/createx): the two
///         functions used here.
interface ICreateXFactory {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

/// @title SameAddress
/// @notice A hook at the SAME address on every testnet this repository deploys to.
///
///         DeployHook and DeployReverseV4Hook mine a CREATE2 address. A CREATE2 address is a hash
///         of the code and of the constructor's arguments, and every hook's first argument is the
///         chain's PoolManager, which has a different address on each chain: so those scripts give
///         a hook a different address per chain. This one deploys through CreateX with CREATE3,
///         where the address is a hash of two things only: the account that sends the deployment,
///         and the salt. Nothing about the chain or the hook's settings is in it.
///
/// @dev How the salt is built, and why (CreateX's own rules for a salt):
///        bytes 0..19   the sender. CreateX then lets only that account use the salt, so nobody
///                      can occupy the hook's address on a chain the owner has not deployed to yet.
///        byte 20       0x00. With 0x01 CreateX would mix the chain id in, and the address would
///                      differ per chain again.
///        bytes 21..31  from the hook's name and a counter. The counter runs up from zero until
///                      the address ends in the hook's 14 permission bits.
///
///      The price of an address that does not depend on the code: the address says who deployed,
///      not what. Each script below therefore reads the deployed hook back before it finishes.
abstract contract SameAddress is Testnets {
    error CreateXIsNotOnThisChain();
    error CreateXHasOtherCode(bytes32 codehash);
    error NoSameAddressFound(string name);
    error AlreadyDeployed(address hook);
    error LandedAt(address actual, address expected);

    ICreateXFactory internal constant FACTORY = ICreateXFactory(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /// @dev CreateX's runtime code hash, read with `cast code` on Sepolia, Base Sepolia and
    ///      Unichain Sepolia on 2026-10-07: the same on all three.
    bytes32 internal constant FACTORY_CODEHASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    /// @dev The hash of the small proxy CreateX creates first in a CREATE3 deployment.
    bytes32 internal constant PROXY_CODEHASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    /// @notice The salt for `sender`, the hook called `name`, at counter `attempt`.
    function saltOf(address sender, string memory name, uint256 attempt) public pure returns (bytes32) {
        return _salt(sender, keccak256(bytes(name)), attempt);
    }

    /// @notice The address a CREATE3 deployment sent by `sender` with `salt` lands on, on any chain.
    /// @dev Three hashes, as CreateX does them: the salt bound to its sender; the proxy's CREATE2
    ///      address; the address of the first contract that proxy creates. Written in place in
    ///      scratch memory because `find` runs it thousands of times.
    function landsAt(address sender, bytes32 salt) public pure returns (address hook) {
        address factory = address(FACTORY);
        bytes32 proxyCode = PROXY_CODEHASH;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sender)
            mstore(add(p, 32), salt)
            let tied := keccak256(p, 64)

            mstore(p, or(shl(248, 0xff), shl(88, factory)))
            mstore(add(p, 21), tied)
            mstore(add(p, 53), proxyCode)
            let proxy := shr(96, shl(96, keccak256(p, 85)))

            // RLP of [proxy, 1]: 0xd6, 0x94, the 20 bytes, 0x01.
            mstore(p, or(shl(240, 0xd694), or(shl(80, proxy), shl(72, 0x01))))
            hook := shr(96, shl(96, keccak256(p, 23)))
        }
    }

    /// @notice The first counter whose address ends in exactly `flags` and does not begin with
    ///         0x91 (which Uniswap's router does not pick up on its own).
    function find(address sender, string memory name, uint160 flags) public pure returns (address hook, bytes32 salt) {
        bytes32 nameHash = keccak256(bytes(name));
        for (uint256 attempt = 0; attempt < 500_000; attempt++) {
            salt = _salt(sender, nameHash, attempt);
            hook = landsAt(sender, salt);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == flags && uint160(hook) >> 152 != 0x91) return (hook, salt);
        }
        revert NoSameAddressFound(name);
    }

    function _salt(address sender, bytes32 nameHash, uint256 attempt) private pure returns (bytes32 salt) {
        assembly ("memory-safe") {
            mstore(0, nameHash)
            mstore(32, attempt)
            // sender ‖ 0x00 ‖ the top 11 bytes of the hash
            salt := or(shl(96, sender), shr(168, keccak256(0, 64)))
        }
    }

    function _checkFactory() internal view {
        if (address(FACTORY).code.length == 0) revert CreateXIsNotOnThisChain();
        if (address(FACTORY).codehash != FACTORY_CODEHASH) revert CreateXHasOtherCode(address(FACTORY).codehash);
    }

    /// @dev One transaction from `sender`. Unlike the CREATE2 scripts this never moves on to a
    ///      next address when the first is taken: a second address would break "the same
    ///      everywhere", so a second run on a chain is refused.
    function _sendTo(address sender, string memory name, uint160 flags, bytes memory code)
        internal
        returns (address hook)
    {
        _checkFactory();
        (address expected, bytes32 salt) = find(sender, name, flags);
        if (expected.code.length != 0) revert AlreadyDeployed(expected);

        vm.startBroadcast(sender);
        hook = FACTORY.deployCreate3(salt, code);
        vm.stopBroadcast();

        if (hook != expected || hook.code.length == 0) revert LandedAt(hook, expected);
    }
}

/// @notice Counter at the same address on Sepolia, Base Sepolia and Unichain Sepolia.
///
///   Dry run (signs nothing, sends nothing). Use the same --sender on every chain: the address
///   belongs to that account.
///     forge script script/SameAddress.s.sol:DeployHookSameAddress --rpc-url <testnet rpc> --sender <signer>
///   The real run is the owner's to start.
contract DeployHookSameAddress is SameAddress {
    string internal constant NAME = "Counter";

    error BoundToAnotherPoolManager(address manager);

    /// @notice Where `sender` gets Counter. Needs no chain.
    function counterAddress(address sender) public pure returns (address hook) {
        (hook,) = find(sender, NAME, FLAGS);
    }

    function deployAs(address sender) public returns (Counter hook) {
        IPoolManager manager = _checkChain();
        hook = Counter(_sendTo(sender, NAME, FLAGS, initcode(manager)));
        if (address(hook.poolManager()) != address(manager)) {
            revert BoundToAnotherPoolManager(address(hook.poolManager()));
        }
    }

    function run() external returns (Counter hook) {
        console2.log("chain id         ", block.chainid);
        console2.log("sender           ", msg.sender);
        console2.log("same address     ", counterAddress(msg.sender));
        hook = deployAs(msg.sender);
        console2.log("deployed hook    ", address(hook));
    }
}

/// @notice ReverseV4Hook at the same address on every testnet, whatever each chain's credential
///         registry, PositionManager, router and treasury are. The rates and every check before
///         and after are DeployReverseV4Hook's own: this script changes only where the hook lands.
///
///   Dry run, with the five values DeployReverseV4Hook reads from the environment:
///     CREDENTIAL=.. CREDENTIAL_ID=.. POSITION_MANAGER=.. SWAP_ROUTER=.. TREASURY=.. \
///       forge script script/SameAddress.s.sol:DeployReverseV4HookSameAddress --rpc-url <testnet rpc> --sender <signer>
contract DeployReverseV4HookSameAddress is SameAddress {
    string internal constant NAME = "ReverseV4Hook";
    /// @dev The low 14 bits ReverseV4Hook's address must carry (DeployReverseV4Hook.REVERSE_FLAGS).
    uint160 internal constant REVERSE_FLAGS = 0x25EC;

    /// @dev The rates, and the checks before and after, live in one place.
    DeployReverseV4Hook public immutable rules = new DeployReverseV4Hook();

    /// @notice Where `sender` gets ReverseV4Hook. Needs no chain and no configuration.
    function reverseAddress(address sender) public pure returns (address hook) {
        (hook,) = find(sender, NAME, REVERSE_FLAGS);
    }

    function deployAs(address sender, ReverseV4Hook.Config memory c) public returns (ReverseV4Hook hook) {
        IPoolManager manager = _checkChain();
        rules.checkBefore(manager, c);
        hook = ReverseV4Hook(_sendTo(sender, NAME, REVERSE_FLAGS, rules.initcodeFor(manager, c)));
        rules.checkAfter(hook, manager, c);
    }

    function run() external returns (ReverseV4Hook hook) {
        console2.log("chain id         ", block.chainid);
        console2.log("sender           ", msg.sender);
        console2.log("same address     ", reverseAddress(msg.sender));
        hook = deployAs(msg.sender, rules.config());
        console2.log("deployed hook    ", address(hook));
    }
}
