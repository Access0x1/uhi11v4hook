// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";

import {Testnets} from "./DeployHook.s.sol";
import {ReverseV4Hook} from "../src/ReverseV4Hook.sol";
import {ICredential} from "../src/interfaces/ICredential.sol";

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @dev The official PositionManager says which PoolManager it was deployed for.
interface IHasPoolManager {
    function poolManager() external view returns (IPoolManager);
}

/// @notice Mines the address for ReverseV4Hook and deploys it there, on a testnet.
/// @dev The five rates are fixed here, in the source, so that what is deployed is what was tested;
///      the five addresses differ per chain and come from the environment:
///
///        CREDENTIAL        the credential registry (must have code)
///        CREDENTIAL_ID     the kind of credential, as a bytes32
///        POSITION_MANAGER  the PositionManager (must have code and be for this chain's PoolManager)
///        SWAP_ROUTER       the one router believed about who is swapping (must have code)
///        TREASURY          the only address `sweep` pays
///
///   Dry run (signs nothing, sends nothing):
///     CREDENTIAL=.. CREDENTIAL_ID=.. POSITION_MANAGER=.. SWAP_ROUTER=.. TREASURY=.. \
///       forge script script/DeployReverseV4Hook.s.sol:DeployReverseV4Hook --rpc-url <testnet rpc>
///   The real run goes through script/handoff/run.sh and is the owner's to start.
contract DeployReverseV4Hook is Testnets {
    /// @dev The low 14 bits ReverseV4Hook's address must carry.
    uint160 internal constant REVERSE_FLAGS = 0x25EC;

    /// @notice LP fee for a swapper without the credential: 0.30%.
    uint24 public constant BASE_FEE = 3000;
    /// @notice LP fee for a credential holder: 0.05%.
    uint24 public constant MEMBER_FEE = 500;
    /// @notice Hook fee on every swap's input: 0.05%.
    uint24 public constant HOOK_FEE = 500;
    /// @notice Bonus on LP fees a holder's position collects: 15%.
    uint24 public constant BONUS_RATE = 150_000;
    /// @notice The treasury's share of the hook fees: 9.9%.
    /// @dev The hook's constructor allows up to 10% at these rates. At exactly 10% a bonus can come up
    ///      a wei or two short per swap, because the hook fee rounds down and the LP fee rounds up.
    ///      The tenth of a percent left here absorbs that. `roundingMargin` below keeps it there.
    uint24 public constant TREASURY_SHARE = 99_000;

    uint256 internal constant PIPS = 1e6;

    error NoCodeAt(string what, address where);
    error TreasuryNotSet();
    error PositionManagerIsForAnotherPoolManager(address positionManager, address itsPoolManager);
    error NoRoundingMarginLeft();
    error Create2DeploymentFailed(bytes reason);
    error NothingDeployedAt(address expected);
    error DeployedHookDiffers(string what);

    /// @notice What the hook is deployed with: the rates above and the addresses in the environment.
    function config() public view returns (ReverseV4Hook.Config memory) {
        return ReverseV4Hook.Config({
            credential: ICredential(vm.envAddress("CREDENTIAL")),
            credentialId: vm.envBytes32("CREDENTIAL_ID"),
            positionManager: vm.envAddress("POSITION_MANAGER"),
            swapRouter: vm.envAddress("SWAP_ROUTER"),
            baseFee: BASE_FEE,
            memberFee: MEMBER_FEE,
            hookFee: HOOK_FEE,
            bonusRate: BONUS_RATE,
            treasury: vm.envAddress("TREASURY"),
            treasuryShare: TREASURY_SHARE
        });
    }

    /// @notice What is left of each hook fee after the treasury's share and the most bonuses can use,
    ///         in pips of the hook fee. The script refuses to run below 1000 (a tenth of a percent).
    function roundingMargin() public pure returns (uint256) {
        uint256 used = uint256(TREASURY_SHARE) * HOOK_FEE + uint256(BONUS_RATE) * BASE_FEE;
        uint256 whole = uint256(HOOK_FEE) * PIPS;
        return used >= whole ? 0 : (whole - used) / HOOK_FEE;
    }

    function initcodeFor(IPoolManager manager, ReverseV4Hook.Config memory c) public pure returns (bytes memory) {
        return abi.encodePacked(type(ReverseV4Hook).creationCode, abi.encode(manager, c));
    }

    /// @notice The first salt whose CREATE2 address, deployed by `deployer`, ends in 0x25EC.
    /// @dev Skips an address that already has code and one whose first byte is 0x91, as `mine` does.
    function mineFor(address deployer, IPoolManager manager, ReverseV4Hook.Config memory c)
        public
        view
        returns (address hook, bytes32 salt)
    {
        bytes memory code = initcodeFor(manager, c);
        for (uint256 s = 0; s < 500_000; s++) {
            hook = HookMiner.computeAddress(deployer, s, code);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK != REVERSE_FLAGS) continue;
            if (uint160(hook) >> 152 == 0x91) continue;
            if (hook.code.length != 0) continue;
            return (hook, bytes32(s));
        }
        revert NoSaltFound();
    }

    /// @notice Everything that must hold before anything is sent.
    function checkBefore(IPoolManager manager, ReverseV4Hook.Config memory c) public view {
        if (roundingMargin() < 1000) revert NoRoundingMarginLeft();
        if (address(c.credential).code.length == 0) revert NoCodeAt("CREDENTIAL", address(c.credential));
        if (c.positionManager.code.length == 0) revert NoCodeAt("POSITION_MANAGER", c.positionManager);
        if (c.swapRouter.code.length == 0) revert NoCodeAt("SWAP_ROUTER", c.swapRouter);
        if (c.treasury == address(0)) revert TreasuryNotSet();

        address its = address(IHasPoolManager(c.positionManager).poolManager());
        if (its != address(manager)) revert PositionManagerIsForAnotherPoolManager(c.positionManager, its);
    }

    /// @notice Everything that must hold of what was deployed, read back from the chain.
    function checkAfter(ReverseV4Hook hook, IPoolManager manager, ReverseV4Hook.Config memory c) public view {
        if (address(hook).code.length == 0) revert NothingDeployedAt(address(hook));
        if (uint160(address(hook)) & Hooks.ALL_HOOK_MASK != REVERSE_FLAGS) revert DeployedHookDiffers("address bits");
        if (address(hook.poolManager()) != address(manager)) revert DeployedHookDiffers("poolManager");
        if (hook.credential() != c.credential) revert DeployedHookDiffers("credential");
        if (hook.credentialId() != c.credentialId) revert DeployedHookDiffers("credentialId");
        if (hook.positionManager() != c.positionManager) revert DeployedHookDiffers("positionManager");
        if (!hook.trustedRouter(c.swapRouter)) revert DeployedHookDiffers("swapRouter");
        if (hook.treasury() != c.treasury) revert DeployedHookDiffers("treasury");
        if (hook.baseFee() != BASE_FEE) revert DeployedHookDiffers("baseFee");
        if (hook.memberFee() != MEMBER_FEE) revert DeployedHookDiffers("memberFee");
        if (hook.hookFee() != HOOK_FEE) revert DeployedHookDiffers("hookFee");
        if (hook.bonusRate() != BONUS_RATE) revert DeployedHookDiffers("bonusRate");
        if (hook.treasuryShare() != TREASURY_SHARE) revert DeployedHookDiffers("treasuryShare");
    }

    function run() external returns (ReverseV4Hook hook) {
        return deploy(config());
    }

    /// @notice The whole deployment for a given configuration: checks, mining, sending, checks.
    function deploy(ReverseV4Hook.Config memory c) public returns (ReverseV4Hook hook) {
        IPoolManager manager = _checkChain();
        checkBefore(manager, c);
        (address expected, bytes32 salt) = mineFor(CREATE2_DEPLOYER, manager, c);

        console2.log("chain id         ", block.chainid);
        console2.log("PoolManager      ", address(manager));
        console2.log("mined hook       ", expected);
        console2.log("salt             ", uint256(salt));
        console2.log("treasury share   ", uint256(TREASURY_SHARE), "pips");

        // The CREATE2 deployer is called by hand, for the reason given in DeployHook.
        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcodeFor(manager, c)));
        vm.stopBroadcast();

        if (!ok) revert Create2DeploymentFailed(ret);
        hook = ReverseV4Hook(expected);
        checkAfter(hook, manager, c);
        console2.log("deployed hook    ", address(hook));
    }
}
