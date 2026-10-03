// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {Counter} from "../src/Counter.sol";

import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice What both scripts share: which chains they may run on, and how the hook's address is found.
/// @dev Testnets only. A chain id that is not listed here stops the script before anything is sent.
abstract contract Testnets is Script {
    error NotATestnetThisRepoDeploysTo(uint256 chainId);
    error NoPoolManagerCodeAt(address manager);
    error NoCreate2DeployerOnThisChain();
    error NoSaltFound();

    /// @dev The deterministic CREATE2 deployer present on every chain this repo deploys to.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev The low 14 bits the hook's address must carry: beforeAddLiquidity | beforeSwap | afterSwap.
    uint160 internal constant FLAGS = 0x8C0;

    /// @dev Checked on 2026-10-02 with `cast code`: 24,009 bytes at each address, the official build.
    function poolManagerFor(uint256 chainId) public pure returns (IPoolManager) {
        if (chainId == 11155111) return IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543); // Sepolia
        if (chainId == 84532) return IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408); // Base Sepolia
        if (chainId == 1301) return IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC); // Unichain Sepolia
        revert NotATestnetThisRepoDeploysTo(chainId);
    }

    function initcode(IPoolManager manager) public pure returns (bytes memory) {
        return abi.encodePacked(type(Counter).creationCode, abi.encode(manager));
    }

    /// @notice The first salt whose CREATE2 address, deployed by `deployer`, ends in FLAGS.
    /// @dev Two addresses are skipped: one that already has code, and one whose first byte is
    ///      0x91, which Uniswap's router does not pick up on its own (routing article, 2026).
    function mine(address deployer, IPoolManager manager) public view returns (address hook, bytes32 salt) {
        bytes memory code = initcode(manager);
        for (uint256 s = 0; s < 500_000; s++) {
            hook = HookMiner.computeAddress(deployer, s, code);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK != FLAGS) continue;
            if (uint160(hook) >> 152 == 0x91) continue;
            if (hook.code.length != 0) continue;
            return (hook, bytes32(s));
        }
        revert NoSaltFound();
    }

    function _checkChain() internal view returns (IPoolManager manager) {
        manager = poolManagerFor(block.chainid);
        if (address(manager).code.length == 0) revert NoPoolManagerCodeAt(address(manager));
        if (CREATE2_DEPLOYER.code.length == 0) revert NoCreate2DeployerOnThisChain();
    }
}

/// @notice Step 1: mine the address and deploy the hook to it.
///
///   Dry run (signs nothing, sends nothing):
///     forge script script/DeployHook.s.sol:DeployHook --rpc-url <testnet rpc>
///   The real run adds `--account <keystore name> --broadcast` and is the owner's to start.
contract DeployHook is Testnets {
    error Create2DeploymentFailed(bytes reason);
    error NothingDeployedAt(address expected);

    function run() external returns (Counter hook) {
        IPoolManager manager = _checkChain();
        (address expected, bytes32 salt) = mine(CREATE2_DEPLOYER, manager);

        console2.log("chain id         ", block.chainid);
        console2.log("PoolManager      ", address(manager));
        console2.log("mined hook       ", expected);
        console2.log("salt             ", uint256(salt));

        // The deployer is called by hand: its calldata is salt ++ creation code. Writing
        // `new Counter{salt: salt}(manager)` leaves it to forge to send the creation through
        // the deployer, and on Base Sepolia forge 1.8.3 sent a plain CREATE instead: the hook
        // landed on an address the miner had not predicted and its constructor refused it.
        vm.startBroadcast();
        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcode(manager)));
        vm.stopBroadcast();

        if (!ok) revert Create2DeploymentFailed(ret);
        if (expected.code.length == 0) revert NothingDeployedAt(expected);
        hook = Counter(expected);
        console2.log("deployed hook    ", address(hook));
    }
}

/// @notice Step 2: a pool that names the deployed hook, liquidity in it, and one swap through it.
/// @dev Everything it needs it brings itself: two mock tokens and v4-core's two test routers.
///      Nothing here is worth anything; the point is one real swap that fires the hook.
///
///   Dry run:
///     HOOK=<address from step 1> forge script script/DeployHook.s.sol:DemoHook --rpc-url <testnet rpc>
contract DemoHook is Testnets {
    error HookHasNoCode(address hook);
    error HookIsForAnotherPoolManager(address hook);
    error CountersDidNotMove(uint256 beforeSwap, uint256 afterSwap, uint256 beforeAddLiquidity);

    function run() external {
        IPoolManager manager = _checkChain();
        Counter hook = Counter(vm.envAddress("HOOK"));
        if (address(hook).code.length == 0) revert HookHasNoCode(address(hook));
        if (address(hook.poolManager()) != address(manager)) revert HookIsForAnotherPoolManager(address(hook));

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();

        MockERC20 a = new MockERC20("Demo A", "DEMA", 18);
        MockERC20 b = new MockERC20("Demo B", "DEMB", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);

        t0.mint(sender, 100e18);
        t1.mint(sender, 100e18);
        t0.approve(address(liquidityRouter), type(uint256).max);
        t1.approve(address(liquidityRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        liquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 100e18, salt: bytes32(0)}), ""
        );
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        PoolId id = key.toId();
        uint256 nBefore = hook.beforeSwapCount(id);
        uint256 nAfter = hook.afterSwapCount(id);
        uint256 nAdd = hook.beforeAddLiquidityCount(id);
        console2.log("hook                    ", address(hook));
        console2.log("pool id                 ");
        console2.logBytes32(PoolId.unwrap(id));
        console2.log("beforeSwapCount         ", nBefore);
        console2.log("afterSwapCount          ", nAfter);
        console2.log("beforeAddLiquidityCount ", nAdd);
        if (nBefore != 1 || nAfter != 1 || nAdd != 1) revert CountersDidNotMove(nBefore, nAfter, nAdd);
    }
}
