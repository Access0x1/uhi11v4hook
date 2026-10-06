// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice What every hook test in this workspace starts from: the official PoolManager bytecode,
///         two ERC-20s, the two v4-core test routers, and helpers to place a hook at a flag address.
/// @dev Nothing here compiles v4-core's PoolManager.sol (exact pragma 0.8.26). The bytes come from
///      hookmate's artifact, so the PoolManager under test is the one deployed on the testnets.
abstract contract HookTestBase is Test {
    uint256 internal constant SEPOLIA = 11155111;

    /// @dev Runtime size of the official PoolManager, measured on four testnets (toolkit, 2026-08-23).
    uint256 internal constant POOL_MANAGER_RUNTIME_SIZE = 24009;

    uint24 internal constant FEE = 3000; // 0.30%, in pips (1e6 = 100%)
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -120;
    int24 internal constant TICK_UPPER = 120;
    int256 internal constant LIQUIDITY = 100e18;

    /// @dev "No price limit" for each direction: one inside the protocol's own bounds, because
    ///      Pool.swap reverts PriceLimitOutOfBounds at MIN_SQRT_PRICE or MAX_SQRT_PRICE exactly.
    ///      zeroForOne pushes the price DOWN, so its limit is the minimum; oneForZero the maximum.
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /// @dev Keeps test hook addresses away from precompiles and each other. Only the low 14 bits
    ///      carry permissions; these high bits mean nothing to the PoolManager.
    uint160 internal constant ADDRESS_NAMESPACE = uint160(0x4444) << 144;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    Currency internal currency0;
    Currency internal currency1;

    function _deployV4() internal {
        vm.chainId(SEPOLIA);

        manager = IPoolManager(V4PoolManagerDeployer.deploy(address(this)));
        assertEq(address(manager).code.length, POOL_MANAGER_RUNTIME_SIZE, "not the official PoolManager bytecode");

        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("Token A", "A", 18);
        MockERC20 b = new MockERC20("Token B", "B", 18);
        // A PoolKey requires currency0 < currency1 by address.
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(t0));
        currency1 = Currency.wrap(address(t1));

        t0.mint(address(this), type(uint128).max);
        t1.mint(address(this), type(uint128).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(liquidityRouter), type(uint256).max);
        t1.approve(address(liquidityRouter), type(uint256).max);
    }

    /// @notice An address whose low 14 bits are exactly `flags`.
    function _flagAddress(uint160 flags) internal pure returns (address) {
        return address(ADDRESS_NAMESPACE | flags);
    }

    /// @notice Run `initcode` (creation code + constructor args) AT `where`, so the constructor sees
    ///         `where` as its own address, exactly as a mined CREATE2 deployment would.
    /// @return ok false if the constructor reverted; `ret` is then its revert data.
    function _tryPlace(bytes memory initcode, address where) internal returns (bool ok, bytes memory ret) {
        vm.etch(where, initcode);
        (ok, ret) = where.call("");
        if (ok) vm.etch(where, ret);
        else vm.etch(where, "");
    }

    /// @notice Same, but a reverting constructor fails the test with the constructor's own error.
    function _place(bytes memory initcode, address where) internal {
        (bool ok, bytes memory ret) = _tryPlace(initcode, where);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice A pool for (currency0, currency1) naming `hook`, opened at tick 0.
    /// @dev sqrtPriceX96 at tick 0 is sqrt(1.0001^0) * 2^96 = 2^96: price 1, on the tick grid.
    function _initPool(IHooks hook) internal returns (PoolKey memory key) {
        key = PoolKey({currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: hook});
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    // ── native ETH ───────────────────────────────────────────────────────────────────────────
    //
    // Native ETH is Currency.wrap(address(0)). It sorts below every token, so in a native pool it is
    // always currency0: zeroForOne spends ETH, oneForZero receives it.

    /// @dev v4-core's test routers send back any ETH they were given and did not use.
    receive() external payable {}

    /// @notice A pool for (native ETH, currency1) naming `hook`, opened at tick 0.
    function _initNativePool(IHooks hook) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)), currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: hook
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    /// @notice The same position as _addLiquidity, on a native pool. Sends more ETH than the position
    ///         needs (about 0.6 ether); the router returns the rest.
    function _addNativeLiquidity(PoolKey memory key) internal {
        vm.deal(address(this), address(this).balance + 1 ether);
        liquidityRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @notice A swap on a native pool, sending `value` wei with it; the router returns what it did not use.
    /// @param amountSpecified negative for exact input, positive for exact output.
    function _swapNative(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _addLiquidity(PoolKey memory key) internal {
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @notice Exact-input swap of `amountIn`, no hook data, no price limit beyond the protocol's own.
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(key, zeroForOne, amountIn, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    /// @notice Exact-input swap that stops when the pool's price reaches `sqrtPriceLimitX96`.
    /// @dev Reaching the limit ENDS the swap with a partial fill; it does not revert it
    ///      (Pool.swap's loop condition). The returned delta shows how much was actually used.
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // negative = exact input
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice The Permissions struct a 14-bit mask stands for: the inverse of _maskOf.
    function _permissionsOf(uint160 mask) internal pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = mask & Hooks.BEFORE_INITIALIZE_FLAG != 0;
        p.afterInitialize = mask & Hooks.AFTER_INITIALIZE_FLAG != 0;
        p.beforeAddLiquidity = mask & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0;
        p.afterAddLiquidity = mask & Hooks.AFTER_ADD_LIQUIDITY_FLAG != 0;
        p.beforeRemoveLiquidity = mask & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0;
        p.afterRemoveLiquidity = mask & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG != 0;
        p.beforeSwap = mask & Hooks.BEFORE_SWAP_FLAG != 0;
        p.afterSwap = mask & Hooks.AFTER_SWAP_FLAG != 0;
        p.beforeDonate = mask & Hooks.BEFORE_DONATE_FLAG != 0;
        p.afterDonate = mask & Hooks.AFTER_DONATE_FLAG != 0;
        p.beforeSwapReturnDelta = mask & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0;
        p.afterSwapReturnDelta = mask & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0;
        p.afterAddLiquidityReturnDelta = mask & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0;
        p.afterRemoveLiquidityReturnDelta = mask & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0;
    }

    /// @notice The 14-bit mask a Permissions struct declares, computed without touching any address.
    function _maskOf(Hooks.Permissions memory p) internal pure returns (uint160 mask) {
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
}
