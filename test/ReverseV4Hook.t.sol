// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {ReverseV4Hook} from "../src/ReverseV4Hook.sol";
import {ICredential} from "../src/interfaces/ICredential.sol";

import {Vm} from "forge-std/Vm.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";
import {DeployHelper} from "hookmate/artifacts/DeployHelper.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Test-only. The parts of the official PositionManager and Permit2 these tests call.
interface IPositionManagerLike {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Test-only. A registry the test can set, and can make revert.
contract SettableCredential is ICredential {
    mapping(address => mapping(bytes32 => bool)) public held;
    bool public broken;

    error RegistryDown();

    function set(address account, bytes32 id, bool value) external {
        held[account][id] = value;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function hasValidCredential(address account, bytes32 id) external view returns (bool) {
        if (broken) revert RegistryDown();
        return held[account][id];
    }
}

/// @dev Test-only. Opens the internal bonus rule so it can be fuzzed on its own.
contract BonusRuleHarness is ReverseV4Hook {
    constructor(
        IPoolManager poolManager_,
        ICredential credential_,
        bytes32 credentialId_,
        address positionManager_,
        address swapRouter_,
        uint24 baseFee_,
        uint24 memberFee_,
        uint24 hookFee_,
        uint24 bonusRate_
    )
        ReverseV4Hook(
            poolManager_,
            credential_,
            credentialId_,
            positionManager_,
            swapRouter_,
            baseFee_,
            memberFee_,
            hookFee_,
            bonusRate_
        )
    {}

    function bonusOf(uint256 fees, uint256 available) external view returns (uint256) {
        return _bonus(fees, available);
    }
}

contract ReverseV4HookTest is HookTestBase {
    /// @dev The mask this hook must carry, as a literal: beforeInitialize (1 << 13) | afterAddLiquidity
    ///      (1 << 10) | afterRemoveLiquidity (1 << 8) | beforeSwap (1 << 7) | afterSwap (1 << 6)
    ///      | beforeDonate (1 << 5) | afterSwapReturnDelta (1 << 2).
    uint160 internal constant EXPECTED_MASK = 0x25E4;

    /// @dev The low 14 bits of the address setUp() places the hook at.
    uint160 internal constant PLACED_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    bytes32 internal constant CREDENTIAL_ID = keccak256("member");
    uint24 internal constant BASE_FEE = 3000; // 0.30%
    uint24 internal constant MEMBER_FEE = 500; // 0.05%
    uint24 internal constant HOOK_FEE = 500; // 0.05% of the unspecified amount
    uint24 internal constant BONUS_RATE = 150_000; // 15% of LP fees collected; the bound allows 16.66%
    uint256 internal constant PIPS = 1e6;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    ReverseV4Hook internal hook;
    SettableCredential internal registry;
    IPositionManagerLike internal posm;
    IUniswapV4Router04 internal router;
    address internal permit2;

    PoolKey internal key;
    PoolId internal id;

    address internal member = makeAddr("member");
    address internal stranger = makeAddr("stranger");
    uint256 internal memberTokenId;
    uint256 internal strangerTokenId;

    function setUp() public {
        _deployV4();

        permit2 = Permit2Deployer.deploy();
        posm = IPositionManagerLike(
            V4PositionManagerDeployer.deploy(address(manager), permit2, 300_000, address(0), address(0))
        );
        router = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(manager), permit2)));
        registry = new SettableCredential();
        registry.set(member, CREDENTIAL_ID, true);

        address where = _flagAddress(PLACED_FLAGS);
        _place(_initcode(type(ReverseV4Hook).creationCode, BASE_FEE, MEMBER_FEE, HOOK_FEE, BONUS_RATE), where);
        hook = ReverseV4Hook(where);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(where)
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        id = key.toId();

        _fund(member);
        _fund(stranger);
        _fund(address(this));

        // Two positions of the same size and range, so both earn the same LP fees.
        memberTokenId = _mint(member);
        strangerTokenId = _mint(stranger);
    }

    // ── helpers ──────────────────────────────────────────────────────────────────────────────

    function _initcode(bytes memory creationCode, uint24 baseFee, uint24 memberFee, uint24 hookFee, uint24 bonusRate)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            creationCode,
            abi.encode(
                manager, registry, CREDENTIAL_ID, address(posm), address(router), baseFee, memberFee, hookFee, bonusRate
            )
        );
    }

    function _token(Currency currency) internal pure returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency));
    }

    /// @dev Tokens, and the approvals the official router and PositionManager pull through.
    function _fund(address who) internal {
        Currency[2] memory currencies = [currency0, currency1];
        for (uint256 i = 0; i < 2; i++) {
            MockERC20 token = _token(currencies[i]);
            if (who != address(this)) token.transfer(who, 1e30);
            vm.startPrank(who);
            token.approve(permit2, type(uint256).max);
            token.approve(address(router), type(uint256).max);
            IPermit2Like(permit2).approve(address(token), address(posm), type(uint160).max, type(uint48).max);
            IPermit2Like(permit2).approve(address(token), address(router), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    function _mint(address who) internal returns (uint256 tokenId) {
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(LIQUIDITY), type(uint128).max, type(uint128).max, who, bytes("")
        );
        params[1] = abi.encode(currency0, currency1);
        vm.prank(who);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev A change of zero liquidity: the way a position collects its LP fees.
    /// @return fees0 and fees1, the LP fees the position's owner received.
    function _collect(address who, uint256 tokenId) internal returns (uint256 fees0, uint256 fees1) {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, who);

        uint256 before0 = _token(currency0).balanceOf(who);
        uint256 before1 = _token(currency1).balanceOf(who);
        vm.prank(who);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        fees0 = _token(currency0).balanceOf(who) - before0;
        fees1 = _token(currency1).balanceOf(who) - before1;
    }

    function _burn(address who, uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, who);
        vm.prank(who);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev Exact-input swap through the official router, which tells the hook who called it.
    function _routerSwap(address who, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(who);
        router.swap(-int256(amountIn), 0, zeroForOne, key, "", who, block.timestamp);
    }

    /// @dev The `fee` field of the last Swap event the PoolManager emitted: the LP fee charged, in pips.
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

    function _claims(Currency currency) internal view returns (uint256) {
        return manager.balanceOf(address(hook), currency.toId());
    }

    function _fullBonus(uint256 fees) internal pure returns (uint256) {
        return fees * BONUS_RATE / PIPS;
    }

    // ── 1. permissions <-> address: the first test of every hook ─────────────────────────────

    function test_Address_MatchesDeclaredPermissions() public view {
        uint160 addressBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        uint160 declared = _maskOf(hook.getHookPermissions());

        assertEq(declared, EXPECTED_MASK, "hook declares something other than its seven flags");
        assertEq(addressBits, EXPECTED_MASK, "address does not carry 0x25E4 in its low 14 bits");
    }

    /// @dev The permanent twin of the sabotage. Six of the seven bits are right; that is not enough.
    function test_RevertWhen_PlacedAtAddressMissingOneFlag() public {
        address wrong = _flagAddress(PLACED_FLAGS & ~uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));

        (bool ok, bytes memory ret) =
            _tryPlace(_initcode(type(ReverseV4Hook).creationCode, BASE_FEE, MEMBER_FEE, HOOK_FEE, BONUS_RATE), wrong);

        assertFalse(ok, "constructor accepted an address without the afterSwapReturnDelta bit");
        assertEq(bytes4(ret), Hooks.HookAddressNotValid.selector, "reverted, but not for the address");
    }

    // ── 2. the constructor's bounds ──────────────────────────────────────────────────────────

    /// @dev 16.67% of a 0.30% LP fee is more than the 0.05% hook fee: trading with yourself would pay.
    function test_RevertWhen_BonusIsNotCoveredByTheHookFee() public {
        address other = _flagAddress(PLACED_FLAGS | (uint160(1) << 20));

        (bool ok, bytes memory ret) =
            _tryPlace(_initcode(type(ReverseV4Hook).creationCode, BASE_FEE, MEMBER_FEE, HOOK_FEE, 166_667), other);
        assertFalse(ok, "constructor accepted a bonus the hook fee does not cover");
        assertEq(bytes4(ret), ReverseV4Hook.BonusNotCoveredByHookFee.selector, "reverted for another reason");

        // 166_666 * 3000 = 499_998_000 <= 500 * 1e6: the largest rate the bound allows.
        (ok,) = _tryPlace(_initcode(type(ReverseV4Hook).creationCode, BASE_FEE, MEMBER_FEE, HOOK_FEE, 166_666), other);
        assertTrue(ok, "constructor refused the largest bonus the hook fee covers");
    }

    function test_RevertWhen_MemberFeeIsAboveBaseFee() public {
        address other = _flagAddress(PLACED_FLAGS | (uint160(1) << 20));
        (bool ok, bytes memory ret) =
            _tryPlace(_initcode(type(ReverseV4Hook).creationCode, BASE_FEE, BASE_FEE + 1, HOOK_FEE, BONUS_RATE), other);
        assertFalse(ok, "constructor accepted a member fee above the base fee");
        assertEq(bytes4(ret), ReverseV4Hook.MemberFeeAboveBaseFee.selector, "reverted for another reason");
    }

    function test_RevertWhen_PoolFeeIsStatic() public {
        PoolKey memory staticKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: TICK_SPACING, hooks: IHooks(hook)
        });
        try manager.initialize(staticKey, TickMath.getSqrtPriceAtTick(0)) {
            fail("a static-fee pool was initialised");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "not the PoolManager's wrapped hook error");
            (,, bytes memory inner,) = abi.decode(_withoutSelector(reason), (address, bytes4, bytes, bytes));
            assertEq(bytes4(inner), ReverseV4Hook.PoolFeeNotDynamic.selector, "the hook failed for another reason");
        }
    }

    // ── 3. the fee a swap is charged, read from the PoolManager's own event ──────────────────

    function test_Swap_StrangerPaysBaseFee_MemberPaysMemberFee() public {
        vm.recordLogs();
        _routerSwap(stranger, true, 1e15);
        assertEq(_lastSwapFee(vm.getRecordedLogs()), BASE_FEE, "stranger's LP fee");

        vm.recordLogs();
        _routerSwap(member, true, 1e15);
        assertEq(_lastSwapFee(vm.getRecordedLogs()), MEMBER_FEE, "member's LP fee");

        // The credential is checked in the block of the swap: take it away and the fee goes back.
        registry.set(member, CREDENTIAL_ID, false);
        vm.recordLogs();
        _routerSwap(member, true, 1e15);
        assertEq(_lastSwapFee(vm.getRecordedLogs()), BASE_FEE, "former member's LP fee");
    }

    /// @dev v4-core's test router does not say who called it, and is not the router the hook believes.
    function test_Swap_ThroughAnotherRouter_PaysBaseFee() public {
        registry.set(address(this), CREDENTIAL_ID, true);
        registry.set(address(swapRouter), CREDENTIAL_ID, true);

        vm.recordLogs();
        _swap(key, true, 1e15);
        assertEq(_lastSwapFee(vm.getRecordedLogs()), BASE_FEE, "LP fee through a router the hook does not know");
    }

    /// @dev A second copy of the same official router. It reports its caller truthfully, and the
    ///      caller holds the credential, but it is not the router the hook was deployed to believe.
    ///      If any router were believed, a contract could simply claim a holder called it.
    function test_Swap_ThroughASecondCopyOfTheRouter_MemberPaysBaseFee() public {
        IUniswapV4Router04 other = IUniswapV4Router04(
            payable(DeployHelper.deploy(
                    abi.encodePacked(V4RouterDeployer.initcode(), abi.encode(address(manager), permit2)), hex"01"
                ))
        );
        assertTrue(address(other) != address(router), "the second router is the first");
        vm.startPrank(member);
        _token(currency0).approve(address(other), type(uint256).max);
        vm.recordLogs();
        other.swap(-int256(1e15), 0, true, key, "", member, block.timestamp);
        vm.stopPrank();

        assertEq(
            _lastSwapFee(vm.getRecordedLogs()), BASE_FEE, "member's LP fee through a router the hook does not know"
        );
    }

    function test_Swap_WhenTheRegistryReverts_ExecutesAtBaseFee() public {
        registry.setBroken(true);

        vm.recordLogs();
        _routerSwap(member, true, 1e15);
        assertEq(_lastSwapFee(vm.getRecordedLogs()), BASE_FEE, "LP fee while the registry reverts");
    }

    // ── 4. the hook fee and the pot ──────────────────────────────────────────────────────────

    function test_Swap_PutsTheHookFeeInThePot_AsClaims() public {
        uint256 before = _token(currency1).balanceOf(stranger);
        _routerSwap(stranger, true, 1e18);
        uint256 received = _token(currency1).balanceOf(stranger) - before;

        // The swapper received the pool's output less the hook fee: fee = output * 500 / 1e6, rounded down.
        uint256 fee = hook.pot(id, currency1);
        assertGt(fee, 0, "no hook fee was taken");
        assertEq(fee, (received + fee) * HOOK_FEE / PIPS, "hook fee is not 0.05% of the pool's output");
        assertEq(_claims(currency1), fee, "the pot is not backed one for one by claims");
        assertEq(hook.pot(id, currency0), 0, "the input currency's pot moved");
    }

    // ── 5. the bonus ─────────────────────────────────────────────────────────────────────────

    /// @dev Both positions earn the same LP fees. Only the credential holder's collection is credited.
    function test_Collect_CreditsTheMemberTheBonus_AndTheStrangerNothing() public {
        // Swaps in both directions, so both pots hold more than any bonus below.
        _routerSwap(stranger, true, 1e18);
        _routerSwap(stranger, false, 1e18);

        (uint256 strangerFees0, uint256 strangerFees1) = _collect(stranger, strangerTokenId);
        assertGt(strangerFees0, 0, "the stranger's position earned no fees in currency0");
        assertEq(hook.owed(stranger, currency0), 0, "a stranger was credited in currency0");
        assertEq(hook.owed(stranger, currency1), 0, "a stranger was credited in currency1");

        (uint256 fees0, uint256 fees1) = _collect(member, memberTokenId);
        assertEq(fees0, strangerFees0, "equal positions earned different fees in currency0");
        assertEq(fees1, strangerFees1, "equal positions earned different fees in currency1");

        assertEq(hook.owed(member, currency0), _fullBonus(fees0), "member's bonus in currency0");
        assertEq(hook.owed(member, currency1), _fullBonus(fees1), "member's bonus in currency1");
    }

    function test_Claim_PaysWhatIsOwed_Once() public {
        _routerSwap(stranger, true, 1e18);
        _routerSwap(stranger, false, 1e18);
        _collect(member, memberTokenId);

        uint256 owed0 = hook.owed(member, currency0);
        assertGt(owed0, 0, "nothing was credited, so there is nothing to test");
        uint256 claimsBefore = _claims(currency0);
        uint256 walletBefore = _token(currency0).balanceOf(member);

        vm.prank(member);
        assertEq(hook.claim(currency0), owed0, "claim returned another amount");

        assertEq(_token(currency0).balanceOf(member) - walletBefore, owed0, "member did not receive what was owed");
        assertEq(claimsBefore - _claims(currency0), owed0, "the hook's claims did not fall by what was paid");
        assertEq(hook.owed(member, currency0), 0, "the debt was not cleared");

        vm.prank(member);
        vm.expectRevert(ReverseV4Hook.NothingToClaim.selector);
        hook.claim(currency0);
    }

    /// @dev A large swap one way, a small one back: currency0's pot holds something, but less than
    ///      the bonus on the currency0 fees. The member is credited all of it and no more, and the
    ///      collection goes through.
    function test_Collect_WhenThePotIsShort_CreditsWhatIsThere() public {
        _routerSwap(stranger, true, 1e18); // fees accrue in currency0; the hook fee lands in currency1
        _routerSwap(stranger, false, 1e15); // a little hook fee lands in currency0

        uint256 potBefore = hook.pot(id, currency0);
        assertGt(potBefore, 0, "currency0's pot is empty");
        (uint256 fees0,) = _collect(member, memberTokenId);
        assertLt(potBefore, _fullBonus(fees0), "the pot covers the full bonus, so it is not short");

        assertEq(hook.owed(member, currency0), potBefore, "member was not credited what the pot held");
        assertEq(hook.pot(id, currency0), 0, "the pot was not emptied");
    }

    function test_Collect_WhenThePotIsEmpty_GoesThrough_AndCreditsNothing() public {
        _routerSwap(stranger, true, 1e18);

        assertEq(hook.pot(id, currency0), 0, "currency0's pot is not empty");
        (uint256 fees0,) = _collect(member, memberTokenId);
        assertGt(fees0, 0, "no fees accrued in currency0");
        assertEq(hook.owed(member, currency0), 0, "a bonus was credited out of an empty pot");
    }

    /// @dev The PositionManager burns the token before it removes the liquidity, so the position has
    ///      no owner to credit. The withdrawal goes through; the uncollected fees earn no bonus.
    function test_Burn_WithUncollectedFees_GoesThrough_AndEarnsNoBonus() public {
        _routerSwap(stranger, true, 1e18);
        _routerSwap(stranger, false, 1e18);

        _burn(member, memberTokenId);
        assertEq(hook.owed(member, currency0), 0, "a burned position was credited in currency0");
        assertEq(hook.owed(member, currency1), 0, "a burned position was credited in currency1");
    }

    /// @dev A position held through any other contract belongs to that contract in the PoolManager.
    ///      Here its salt is the member's token id, the one value that could be mistaken for the
    ///      member's own position. Only the PositionManager's salts are read as token ids.
    function test_Collect_ThroughAnotherLiquidityRouter_EarnsNoBonus() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(memberTokenId)
        });
        liquidityRouter.modifyLiquidity(key, params, "");
        _routerSwap(stranger, true, 1e18);
        _routerSwap(stranger, false, 1e18);

        params.liquidityDelta = 0;
        liquidityRouter.modifyLiquidity(key, params, "");
        assertEq(hook.owed(member, currency0), 0, "the member was credited for someone else's position");
        assertEq(hook.owed(member, currency1), 0, "the member was credited for someone else's position");
    }

    // ── 6. the two ways to take the pot for nothing ──────────────────────────────────────────

    function test_RevertWhen_AnyoneDonates() public {
        // The PoolManager is locked outside a router, so the donation goes through v4-core's router
        // pattern: this contract unlocks and donates in the callback.
        try manager.unlock(abi.encode(uint256(1e15))) {
            fail("a donation was accepted");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), CustomRevert.WrappedError.selector, "not the PoolManager's wrapped hook error");
            (,, bytes memory inner,) = abi.decode(_withoutSelector(reason), (address, bytes4, bytes, bytes));
            assertEq(bytes4(inner), ReverseV4Hook.DonationsNotAccepted.selector, "the hook failed for another reason");
        }
    }

    /// @dev Called by the PoolManager for the donation test above.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only the PoolManager");
        manager.donate(key, abi.decode(data, (uint256)), 0, "");
        return "";
    }

    /// @dev A credential holder who is the only LP trades with themselves, as a non-holder so the LP
    ///      fee that comes back is the largest possible, then collects and takes the bonus. The swaps
    ///      must have put into the pot at least what the bonus took out. The two currencies are summed
    ///      as equals: the pool stays within 120 ticks of price 1 (1.2%), and the bound leaves 10%.
    function testFuzz_TradingWithYourself_LeavesThePotNoSmaller(uint256 amount) public {
        amount = bound(amount, 1e12, 1e17);

        // Others' swaps fill the pot first, or there would be nothing to take.
        _routerSwap(stranger, true, 1e17);
        _routerSwap(stranger, false, 1e17);
        _burn(stranger, strangerTokenId); // the member is now the only LP
        _collect(member, memberTokenId);
        uint256 potBefore = hook.pot(id, currency0) + hook.pot(id, currency1);
        uint256 owedBefore = hook.owed(member, currency0) + hook.owed(member, currency1);

        address alias_ = makeAddr("member's second wallet");
        _fund(alias_);
        _routerSwap(alias_, true, amount);
        _routerSwap(alias_, false, amount);
        _collect(member, memberTokenId);

        uint256 potAfter = hook.pot(id, currency0) + hook.pot(id, currency1);
        uint256 taken = hook.owed(member, currency0) + hook.owed(member, currency1) - owedBefore;
        assertGt(taken, 0, "no bonus was credited, so the test proves nothing");
        // potAfter = potBefore + what the swaps paid in - taken, so this says: paid in >= taken.
        assertGe(potAfter, potBefore, "trading with yourself shrank the pot");
    }

    // ── 7. the bonus rule on its own ─────────────────────────────────────────────────────────

    function testFuzz_BonusRule_NeverExceedsThePot_AndIsFullWhenThePotAllows(uint128 fees, uint128 available) public {
        address where = _flagAddress(PLACED_FLAGS | (uint160(2) << 20));
        _place(_initcode(type(BonusRuleHarness).creationCode, BASE_FEE, MEMBER_FEE, HOOK_FEE, BONUS_RATE), where);

        uint256 bonus = BonusRuleHarness(where).bonusOf(fees, available);
        uint256 full = uint256(fees) * BONUS_RATE / PIPS;

        assertLe(bonus, available, "bonus is more than the pot holds");
        assertLe(bonus, full, "bonus is more than bonusRate of the fees");
        if (available >= full) assertEq(bonus, full, "the pot could pay the full bonus and did not");
    }

    // ── 8. access ────────────────────────────────────────────────────────────────────────────

    function testFuzz_RevertWhen_CallerIsNotPoolManager(address caller) public {
        vm.assume(caller != address(manager));
        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        ModifyLiquidityParams memory liqParams =
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 0, salt: bytes32(0)});
        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.startPrank(caller);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(caller, key, 0);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(caller, key, swapParams, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(caller, key, swapParams, zero, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterAddLiquidity(caller, key, liqParams, zero, zero, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(caller, key, liqParams, zero, zero, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeDonate(caller, key, 0, 0, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(caller, currency0, uint256(1)));
        vm.stopPrank();
    }

    // ── 9. fuzz: the hook never owes more than it holds ──────────────────────────────────────

    /// @dev Any mix of swaps by either wallet in either direction, fee collections by either LP, and
    ///      claims. After every step, for each currency: the claims the hook holds equal the pot plus
    ///      everything owed. So what has been credited can always be paid.
    function testFuzz_ClaimsHeld_AlwaysEqualPotPlusOwed(uint256 seed, uint8 steps) public {
        uint256 n = bound(steps, 1, 8);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 4;
            address who = (r >> 8) % 2 == 0 ? member : stranger;

            if (action < 2) {
                _routerSwap(who, action == 0, bound(r >> 16, 1, 1e17));
            } else if (action == 2) {
                _collect(who, who == member ? memberTokenId : strangerTokenId);
            } else {
                Currency currency = (r >> 16) % 2 == 0 ? currency0 : currency1;
                if (hook.owed(who, currency) > 0) {
                    vm.prank(who);
                    hook.claim(currency);
                }
            }

            assertEq(hook.owed(stranger, currency0) + hook.owed(stranger, currency1), 0, "a stranger is owed a bonus");
            assertEq(
                _claims(currency0), hook.pot(id, currency0) + hook.owed(member, currency0), "currency0: held != books"
            );
            assertEq(
                _claims(currency1), hook.pot(id, currency1) + hook.owed(member, currency1), "currency1: held != books"
            );
        }
    }

    function _withoutSelector(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }
}
