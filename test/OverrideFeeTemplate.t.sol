// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {OverrideFeeTemplate} from "../src/templates/OverrideFeeTemplate.sol";
import {FeeOverride} from "../src/templates/FeeOverride.sol";

import {Vm} from "forge-std/Vm.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {DeployHelper} from "hookmate/artifacts/DeployHelper.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Test-only. The smallest hook on the template: a fee per account, set by the test.
contract FeePerAccount is OverrideFeeTemplate {
    mapping(address => uint24) public feeOf;
    mapping(address => bool) public hasFee;

    constructor(IPoolManager poolManager_, uint24 baseFee_, address[] memory routers_)
        OverrideFeeTemplate(poolManager_, baseFee_, routers_)
    {}

    function set(address account, uint24 fee) external {
        feeOf[account] = fee;
        hasFee[account] = true;
    }

    function _feeFor(address swapper, PoolKey calldata, SwapParams calldata) internal view override returns (uint24) {
        return hasFee[swapper] ? feeOf[swapper] : baseFee;
    }
}

/// @dev Test-only. A router the hook trusts whose msgSender() reverts.
contract RouterThatWillNotSay {
    error WillNotSay();

    function msgSender() external pure returns (address) {
        revert WillNotSay();
    }
}

contract OverrideFeeTemplateTest is HookTestBase {
    using StateLibrary for IPoolManager;

    /// @dev The mask every hook on this template carries, as a literal: beforeInitialize (1 << 13) | beforeSwap (1 << 7).
    uint160 internal constant EXPECTED_MASK = 0x2080;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    uint160 internal constant PLACED_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant MEMBER_FEE = 500;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    FeePerAccount internal hook;
    IUniswapV4Router04 internal router;
    IUniswapV4Router04 internal otherRouter;
    RouterThatWillNotSay internal silentRouter;
    PoolKey internal key;

    address internal member = makeAddr("member");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _deployV4();
        address permit2 = Permit2Deployer.deploy();
        bytes memory routerInit = abi.encodePacked(V4RouterDeployer.initcode(), abi.encode(address(manager), permit2));
        router = IUniswapV4Router04(payable(DeployHelper.deploy(routerInit, hex"00")));
        otherRouter = IUniswapV4Router04(payable(DeployHelper.deploy(routerInit, hex"01")));
        silentRouter = new RouterThatWillNotSay();

        address where = _flagAddress(PLACED_FLAGS);
        _place(_initcode(BASE_FEE), where);
        hook = FeePerAccount(where);
        hook.set(member, MEMBER_FEE);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(where)
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        _addLiquidity(key);

        _fund(member);
        _fund(stranger);
    }

    function _initcode(uint24 baseFee) internal view returns (bytes memory) {
        address[] memory routers = new address[](2);
        routers[0] = address(router);
        routers[1] = address(silentRouter);
        return abi.encodePacked(type(FeePerAccount).creationCode, abi.encode(manager, baseFee, routers));
    }

    function _fund(address who) internal {
        Currency[2] memory currencies = [currency0, currency1];
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 token = MockERC20(Currency.unwrap(currencies[i]));
            token.transfer(who, 1e24);
            vm.startPrank(who);
            token.approve(address(router), type(uint256).max);
            token.approve(address(otherRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev The LP fee the PoolManager charged `who` for a swap through `through`, from its Swap event.
    function _feeCharged(IUniswapV4Router04 through, address who) internal returns (uint24 fee) {
        vm.recordLogs();
        vm.prank(who);
        through.swap(-int256(1e15), 0, true, key, "", who, block.timestamp);
        return _lastSwapFee(vm.getRecordedLogs());
    }

    function _lastSwapFee(Vm.Log[] memory logs) internal view returns (uint24 fee) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "the PoolManager emitted no Swap event");
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "template declares something other than its two flags");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0x2080 in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage. One of the two bits is right; that is not enough.
    function test_RevertWhen_PlacedAtAddressMissingOneFlag() public {
        (bool ok, bytes memory ret) = _tryPlace(_initcode(BASE_FEE), _flagAddress(uint160(Hooks.BEFORE_SWAP_FLAG)));

        assertFalse(ok, "constructor accepted an address without the beforeInitialize bit");
        assertEq(bytes4(ret), Hooks.HookAddressNotValid.selector, "reverted, but not for the address");
    }

    // ── 2. what the template guarantees whatever the hook's fee rule is ──────────────────────

    function test_RevertWhen_PoolFeeIsStatic() public {
        PoolKey memory staticKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
        });
        try manager.initialize(staticKey, TickMath.getSqrtPriceAtTick(0)) {
            fail("a static-fee pool was initialised");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "not the PoolManager's wrapped hook error");
        }
    }

    function test_RevertWhen_BaseFeeIsOneHundredPercent() public {
        (bool ok, bytes memory ret) = _tryPlace(_initcode(1_000_000), _flagAddress(PLACED_FLAGS | (uint160(1) << 20)));
        assertFalse(ok, "constructor accepted a 100% base fee");
        assertEq(bytes4(ret), FeeOverride.FeeTooLarge.selector, "reverted for another reason");
    }

    /// @dev Without the override flag a dynamic-fee pool charges its stored fee, which starts at 0.
    function test_Swap_ByAnyone_IsNeverFree() public {
        assertEq(_feeCharged(router, stranger), BASE_FEE, "a stranger's LP fee");
        _swap(key, true, 1e15);
        (,,, uint24 stored) = manager.getSlot0(key.toId());
        assertEq(stored, 0, "the pool's stored fee is no longer 0, so this test proves less than it says");
    }

    /// @dev Whatever fee the hook's rule returns, the swap executes. A fee the PoolManager would
    ///      reject (100% or more) is replaced by the base fee.
    function testFuzz_AnyFeeTheRuleReturns_TheSwapExecutes(uint24 fee) public {
        hook.set(member, fee);
        assertEq(_feeCharged(router, member), fee < 1_000_000 ? fee : BASE_FEE, "LP fee charged");
    }

    // ── 3. who the swapper is ────────────────────────────────────────────────────────────────

    function test_Swap_ThroughATrustedRouter_IsChargedTheSwappersFee() public {
        assertEq(_feeCharged(router, member), MEMBER_FEE, "member's LP fee through the trusted router");
        assertEq(_feeCharged(router, stranger), BASE_FEE, "stranger's LP fee through the trusted router");
    }

    /// @dev The same official router, deployed a second time and not in the hook's list. It reports
    ///      its caller truthfully, but so would a contract written to lie.
    function test_Swap_ThroughAnUntrustedRouter_IsNotChargedTheSwappersFee() public {
        assertEq(_feeCharged(otherRouter, member), BASE_FEE, "member's LP fee through a router the hook does not trust");
    }

    /// @dev The untrusted router itself has a fee set. It is still not treated as the swapper.
    function test_Swap_ThroughAnUntrustedRouter_TheRouterIsNotTheSwapper() public {
        hook.set(address(otherRouter), MEMBER_FEE);
        assertEq(_feeCharged(otherRouter, stranger), BASE_FEE, "an untrusted router's own fee was applied");
    }

    /// @dev v4-core's test router has no msgSender() at all, and this contract (its caller) has a fee set.
    function test_Swap_ThroughARouterWithNoMsgSender_Executes() public {
        hook.set(address(this), MEMBER_FEE);
        vm.recordLogs();
        _swap(key, true, 1e15);
        assertEq(_lastSwapFee(vm.getRecordedLogs()), BASE_FEE, "LP fee through a router that cannot say who called");
    }

    /// @dev Called by the PoolManager for the test below: a swap whose `sender` is this contract.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only the PoolManager");
        // The hook calls beforeSwap with sender = silentRouter only if silentRouter calls swap, so
        // the swap is made from its address.
        vm.prank(address(silentRouter));
        manager.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}), ""
        );
        return "";
    }

    /// @dev A trusted router whose msgSender() reverts must not stop the swap. The swap itself is
    ///      left unsettled on purpose, so the unlock reverts CurrencyNotSettled: reaching that error
    ///      proves beforeSwap returned instead of reverting.
    function test_Swap_WhenATrustedRouterReverts_BeforeSwapStillReturns() public {
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        manager.unlock("");
    }
}
