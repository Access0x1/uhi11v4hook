// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {Testnets} from "./DeployHook.s.sol";
import {TestnetCredentialRegistry} from "../src/testnet/TestnetCredentialRegistry.sol";

/// @notice Deploys the testnet credential registry, on a testnet.
/// @dev ISSUER, from the environment, is the one address that will be able to grant and revoke. It
///      cannot be changed afterwards, so the script reads it back from the chain before it reports.
///
///   Dry run (signs nothing, sends nothing):
///     ISSUER=<address> forge script script/DeployTestnetCredentialRegistry.s.sol:DeployTestnetCredentialRegistry --rpc-url <testnet rpc>
///   The real run goes through script/handoff/run.sh and is the owner's to start.
contract DeployTestnetCredentialRegistry is Testnets {
    error IssuerNotSet();
    error NothingDeployed();
    error DeployedRegistryHasAnotherIssuer(address onChain, address wanted);

    function run() external returns (TestnetCredentialRegistry registry) {
        return deploy(vm.envAddress("ISSUER"));
    }

    function deploy(address issuer) public returns (TestnetCredentialRegistry registry) {
        _checkChain();
        if (issuer == address(0)) revert IssuerNotSet();

        console2.log("chain id         ", block.chainid);
        console2.log("issuer           ", issuer);

        vm.startBroadcast();
        registry = new TestnetCredentialRegistry(issuer);
        vm.stopBroadcast();

        if (address(registry).code.length == 0) revert NothingDeployed();
        if (registry.issuer() != issuer) revert DeployedRegistryHasAnotherIssuer(registry.issuer(), issuer);
        console2.log("deployed registry", address(registry));
    }
}
