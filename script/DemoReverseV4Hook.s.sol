// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {Testnets} from "./DeployHook.s.sol";
import {ReverseV4Hook} from "../src/ReverseV4Hook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @dev A token for the demo: the whole supply goes to whoever deploys it. Worth nothing.
contract DemoToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_, 18) {
        _mint(msg.sender, 1_000_000e18);
    }
}

interface IPositionManagerDemo {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPermit2Demo {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IUniversalRouterDemo {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev The single-pool exact-input parameters Universal Router 2.1.2 decodes. One field more than
///      the v4-periphery pinned in this repository has: `minHopPriceX36`.
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

/// @notice One real pass through a deployed ReverseV4Hook, on a testnet: a pool that names the hook,
///         a position in it, a swap each way by a credential holder through the hook's trusted
///         router, the fees collected, the bonus claimed, and the treasury's share swept.
/// @dev Everything it needs it brings: two demo tokens. The sender must hold the credential, or the
///      demo would only show the base fee; the script checks before anything is sent. Every number
///      it reports is checked inside the script too, so a run whose simulation disagrees with the
///      hook's rules stops before a single transaction goes out.
///
///   Dry run (signs nothing, sends nothing):
///     HOOK=<hook> SWAP_ROUTER=<its trusted router> forge script \
///       script/DemoReverseV4Hook.s.sol:DemoReverseV4Hook --rpc-url <testnet rpc> --sender <holder>
///   The real run goes through script/handoff/run.sh and is the owner's to start.
contract DemoReverseV4Hook is Testnets {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant LIQUIDITY = 100e18;
    uint128 internal constant SWAP_AMOUNT = 1e17;
    uint256 internal constant PIPS = 1e6;

    error HookHasNoCode(address hook);
    error HookIsForAnotherPoolManager(address hook);
    error RouterIsNotTheHooksTrustedRouter(address router);
    error SenderHoldsNoCredential(address sender);
    error WrongLpFee(uint24 charged, uint24 expected);
    error NoHookFeeReachedThePot();
    error PositionNotOwnedBySender(address owner);
    error WrongBonus(uint256 credited, uint256 expected);
    error ClaimPaidAnotherAmount(uint256 paid, uint256 owed);
    error SweepOverTheTreasuryShare(uint256 swept, uint256 feesTaken);
    error HookHoldsOtherThanItsBooks(uint256 claims, uint256 pot, uint256 owed);

    /// @notice What a run did, for the caller to check against the chain afterwards.
    struct Result {
        address token0;
        address token1;
        bytes32 poolId;
        uint256 tokenId;
        uint24 feeFirstSwap;
        uint24 feeSecondSwap;
        uint256 fees0;
        uint256 fees1;
        uint256 bonus0;
        uint256 bonus1;
        uint256 swept0;
        uint256 swept1;
    }

    function run() external returns (Result memory) {
        return demo(ReverseV4Hook(vm.envAddress("HOOK")), vm.envAddress("SWAP_ROUTER"));
    }

    function demo(ReverseV4Hook hook, address router) public returns (Result memory r) {
        IPoolManager manager = _checkChain();
        if (address(hook).code.length == 0) revert HookHasNoCode(address(hook));
        if (address(hook.poolManager()) != address(manager)) revert HookIsForAnotherPoolManager(address(hook));
        if (!hook.trustedRouter(router)) revert RouterIsNotTheHooksTrustedRouter(router);
        IPositionManagerDemo posm = IPositionManagerDemo(hook.positionManager());

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        if (!hook.credential().hasValidCredential(sender, hook.credentialId())) revert SenderHoldsNoCredential(sender);

        // 1. two tokens, and leave to move them: the PositionManager and the router both pull through Permit2.
        PoolKey memory key = _tokensAndApprovals(address(posm), router, IHooks(address(hook)));
        r.token0 = Currency.unwrap(key.currency0);
        r.token1 = Currency.unwrap(key.currency1);
        PoolId id = key.toId();
        r.poolId = PoolId.unwrap(id);

        // 2. the pool, and a position in it held by the sender.
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        r.tokenId = posm.nextTokenId();
        _mint(posm, key, sender);
        if (posm.ownerOf(r.tokenId) != sender) revert PositionNotOwnedBySender(posm.ownerOf(r.tokenId));

        // 3. a swap each way through the trusted router. The sender holds the credential: member fee.
        r.feeFirstSwap = _swap(manager, router, key, true);
        r.feeSecondSwap = _swap(manager, router, key, false);
        uint24 memberFee = hook.memberFee();
        if (r.feeFirstSwap != memberFee) revert WrongLpFee(r.feeFirstSwap, memberFee);
        if (r.feeSecondSwap != memberFee) revert WrongLpFee(r.feeSecondSwap, memberFee);
        if (hook.pot(id, key.currency0) == 0 || hook.pot(id, key.currency1) == 0) revert NoHookFeeReachedThePot();

        // 4. collect the position's LP fees; the hook credits the bonus on them.
        (r.fees0, r.fees1) = _collect(posm, key, r.tokenId, sender);
        r.bonus0 = hook.owed(sender, key.currency0);
        r.bonus1 = hook.owed(sender, key.currency1);
        uint256 bonusRate = hook.bonusRate();
        if (r.bonus0 != r.fees0 * bonusRate / PIPS) revert WrongBonus(r.bonus0, r.fees0 * bonusRate / PIPS);
        if (r.bonus1 != r.fees1 * bonusRate / PIPS) revert WrongBonus(r.bonus1, r.fees1 * bonusRate / PIPS);

        // 5. claim the bonus, then let the treasury take its share of what is left.
        _claim(hook, key.currency0, sender, r.bonus0);
        _claim(hook, key.currency1, sender, r.bonus1);
        r.swept0 = _sweep(hook, id, key.currency0);
        r.swept1 = _sweep(hook, id, key.currency1);
        vm.stopBroadcast();

        _checkBooks(manager, hook, id, key.currency0, sender);
        _checkBooks(manager, hook, id, key.currency1, sender);
        _report(address(hook), r);
    }

    function _tokensAndApprovals(address posm, address router, IHooks hook) internal returns (PoolKey memory key) {
        DemoToken a = new DemoToken("ReverseV4Hook Demo A", "RVDA");
        DemoToken b = new DemoToken("ReverseV4Hook Demo B", "RVDB");
        (DemoToken t0, DemoToken t1) = address(a) < address(b) ? (a, b) : (b, a);

        uint48 expiry = uint48(block.timestamp + 1 days);
        t0.approve(PERMIT2, type(uint256).max);
        t1.approve(PERMIT2, type(uint256).max);
        IPermit2Demo(PERMIT2).approve(address(t0), posm, type(uint160).max, expiry);
        IPermit2Demo(PERMIT2).approve(address(t1), posm, type(uint160).max, expiry);
        IPermit2Demo(PERMIT2).approve(address(t0), router, type(uint160).max, expiry);
        IPermit2Demo(PERMIT2).approve(address(t1), router, type(uint160).max, expiry);

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
    }

    function _mint(IPositionManagerDemo posm, PoolKey memory key, address owner) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(key, int24(-120), int24(120), LIQUIDITY, type(uint128).max, type(uint128).max, owner, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    /// @return fee the LP fee the PoolManager charged, read from its Swap event.
    function _swap(IPoolManager manager, address router, PoolKey memory key, bool zeroForOne)
        internal
        returns (uint24 fee)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: SWAP_AMOUNT,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(zeroForOne ? key.currency0 : key.currency1, uint256(SWAP_AMOUNT));
        params[2] = abi.encode(zeroForOne ? key.currency1 : key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.recordLogs();
        IUniversalRouterDemo(router).execute(hex"10", inputs, block.timestamp + 1 hours); // 0x10: V4_SWAP
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    /// @dev A change of zero liquidity collects the position's LP fees.
    function _collect(IPositionManagerDemo posm, PoolKey memory key, uint256 tokenId, address to)
        internal
        returns (uint256 fees0, uint256 fees1)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);

        uint256 before0 = key.currency0.balanceOf(to);
        uint256 before1 = key.currency1.balanceOf(to);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
        fees0 = key.currency0.balanceOf(to) - before0;
        fees1 = key.currency1.balanceOf(to) - before1;
    }

    function _claim(ReverseV4Hook hook, Currency currency, address sender, uint256 owed) internal {
        if (owed == 0) return;
        uint256 before = currency.balanceOf(sender);
        hook.claim(currency);
        uint256 paid = currency.balanceOf(sender) - before;
        if (paid != owed) revert ClaimPaidAnotherAmount(paid, owed);
    }

    function _sweep(ReverseV4Hook hook, PoolId id, Currency currency) internal returns (uint256 swept) {
        if (hook.sweepable(id, currency) == 0) return 0;
        swept = hook.sweep(id, currency);
        uint256 taken = hook.feesTaken(id, currency);
        if (swept * PIPS > taken * hook.treasuryShare()) revert SweepOverTheTreasuryShare(swept, taken);
    }

    /// @dev After everything: what the hook holds in claims is its pot plus what it still owes.
    function _checkBooks(IPoolManager manager, ReverseV4Hook hook, PoolId id, Currency currency, address sender)
        internal
        view
    {
        uint256 claims = manager.balanceOf(address(hook), currency.toId());
        uint256 pot = hook.pot(id, currency);
        uint256 owed = hook.owed(sender, currency);
        if (claims != pot + owed) revert HookHoldsOtherThanItsBooks(claims, pot, owed);
    }

    function _report(address hook, Result memory r) internal pure {
        console2.log("hook              ", hook);
        console2.log("token0            ", r.token0);
        console2.log("token1            ", r.token1);
        console2.log("pool id           ");
        console2.logBytes32(r.poolId);
        console2.log("position token id ", r.tokenId);
        console2.log("LP fee, swap 1    ", uint256(r.feeFirstSwap), "pips");
        console2.log("LP fee, swap 2    ", uint256(r.feeSecondSwap), "pips");
        console2.log("fees collected 0  ", r.fees0);
        console2.log("fees collected 1  ", r.fees1);
        console2.log("bonus claimed 0   ", r.bonus0);
        console2.log("bonus claimed 1   ", r.bonus1);
        console2.log("treasury swept 0  ", r.swept0);
        console2.log("treasury swept 1  ", r.swept1);
    }
}
