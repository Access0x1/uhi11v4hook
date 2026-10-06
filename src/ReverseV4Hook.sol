// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

import {ICredential} from "./interfaces/ICredential.sol";

/// @dev The one function this hook needs from the PositionManager's ERC-721.
interface IPositionOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title ReverseV4Hook
/// @notice A loyalty hook with its own accounting, for dynamic-fee pools.
///         1. A swapper who holds the credential pays `memberFee` to the pool's LPs; anyone else pays `baseFee`.
///         2. Every swap also pays `hookFee` on its unspecified amount into a per-pool pot the hook holds.
///         3. When a credential holder's position collects LP fees, the hook credits that holder a bonus of
///            `bonusRate` on the fees collected, out of the pot. The holder withdraws it with `claim`.
/// @dev Seven flags, so seven bits in the address:
///      beforeInitialize 0x2000 | afterAddLiquidity 0x400 | afterRemoveLiquidity 0x100 | beforeSwap 0x80
///      | afterSwap 0x40 | beforeDonate 0x20 | afterSwapReturnDelta 0x04 = 0x25E4.
///      No owner, no upgrade path, every parameter immutable.
contract ReverseV4Hook is BaseHook, IUnlockCallback {
    using LPFeeLibrary for uint24;
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /// @dev Fees and rates are in pips: 1e6 = 100%.
    uint256 internal constant PIPS = 1e6;

    /// @notice The registry asked whether an account holds the credential.
    ICredential public immutable credential;
    /// @notice The kind of credential that earns the member fee and the bonus.
    bytes32 public immutable credentialId;
    /// @notice The only liquidity caller whose positions can earn a bonus. Its ERC-721 names the position's owner.
    address public immutable positionManager;
    /// @notice The only swap caller whose `msgSender()` is believed.
    address public immutable swapRouter;

    /// @notice LP fee for a swapper without the credential, or one who came through any other router.
    uint24 public immutable baseFee;
    /// @notice LP fee for a credential holder who came through `swapRouter`.
    uint24 public immutable memberFee;
    /// @notice Taken from every swap's unspecified amount, into the pot.
    uint24 public immutable hookFee;
    /// @notice Bonus on LP fees collected by a credential holder's position, paid out of the pot.
    uint24 public immutable bonusRate;

    /// @notice Hook fees taken on a pool and not yet credited to anyone, per currency.
    mapping(PoolId => mapping(Currency => uint256)) public pot;
    /// @notice Bonus credited to an account and not yet claimed, per currency.
    mapping(address => mapping(Currency => uint256)) public owed;

    event HookFeeTaken(PoolId indexed id, Currency indexed currency, uint256 amount);
    event BonusCredited(PoolId indexed id, address indexed account, Currency indexed currency, uint256 amount);
    event Claimed(address indexed account, Currency indexed currency, uint256 amount);

    error NotAContract(address target);
    error FeeTooLarge(uint24 fee);
    error MemberFeeAboveBaseFee();
    /// @dev bonusRate * baseFee must not exceed hookFee * 1e6. See the constructor.
    error BonusNotCoveredByHookFee();
    error PoolFeeNotDynamic();
    error DonationsNotAccepted();
    error NothingToClaim();

    /// @dev BaseHook's constructor checks this contract's own address against getHookPermissions()
    ///      and reverts with HookAddressNotValid if the low 14 bits disagree.
    ///
    ///      The bound on bonusRate is what makes trading with yourself unprofitable. Someone who is the
    ///      only in-range LP gets the LP fee of their own swap straight back, at most baseFee of the
    ///      volume, and with it a bonus of bonusRate on that fee. The same swap pays hookFee of the volume
    ///      into the pot. While bonusRate * baseFee <= hookFee * 1e6, the swap puts in at least what the
    ///      bonus takes out.
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
    ) BaseHook(poolManager_) {
        // A try/catch around a call to an address without code still reverts, which would stop
        // every swap or every fee collection on the pool.
        if (address(credential_).code.length == 0) revert NotAContract(address(credential_));
        if (positionManager_.code.length == 0) revert NotAContract(positionManager_);
        if (swapRouter_.code.length == 0) revert NotAContract(swapRouter_);

        // At 100% an exact-output swap cannot execute (Pool.sol, InvalidFeeForExactOut).
        if (baseFee_ >= PIPS) revert FeeTooLarge(baseFee_);
        if (hookFee_ >= PIPS) revert FeeTooLarge(hookFee_);
        if (memberFee_ > baseFee_) revert MemberFeeAboveBaseFee();
        if (uint256(bonusRate_) * baseFee_ > uint256(hookFee_) * PIPS) revert BonusNotCoveredByHookFee();

        credential = credential_;
        credentialId = credentialId_;
        positionManager = positionManager_;
        swapRouter = swapRouter_;
        baseFee = baseFee_;
        memberFee = memberFee_;
        hookFee = hookFee_;
        bonusRate = bonusRate_;
    }

    /// @notice The callbacks this hook implements. Every flag set here has a function below.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.afterAddLiquidity = true;
        permissions.afterRemoveLiquidity = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeDonate = true;
        permissions.afterSwapReturnDelta = true;
    }

    // ── the pool ─────────────────────────────────────────────────────────────────────────────

    /// @dev A fee override is honoured only on a dynamic-fee pool (Hooks.sol, beforeSwap). On a
    ///      static-fee pool the member fee would be ignored without any error, so such a pool is refused.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert PoolFeeNotDynamic();
        return this.beforeInitialize.selector;
    }

    /// @dev A donation is paid to in-range LPs as fees. An LP alone in range could donate to
    ///      themselves, get the donation back as fees collected, and take a bonus on it for nothing.
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert DonationsNotAccepted();
    }

    // ── swaps ────────────────────────────────────────────────────────────────────────────────

    /// @dev Returns the LP fee for this swap, always with the override flag: a dynamic-fee pool starts
    ///      at fee 0 (LPFeeLibrary.getInitialLPFee), so a swap without an override would be free.
    ///      `sender` is the router, never the person. Only `swapRouter` is asked who called it.
    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = baseFee;
        if (sender == swapRouter) {
            try IMsgSender(sender).msgSender() returns (address swapper) {
                if (_holdsCredential(swapper)) fee = memberFee;
            } catch {}
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Takes hookFee of the unspecified amount, as ERC-6909 claims on the PoolManager, and adds it
    ///      to this pool's pot. The unspecified currency is the output of an exact-input swap and the
    ///      input of an exact-output swap. The returned amount is what the swapper's side of the swap
    ///      is charged; the claims minted here settle it. Rounds down, in the swapper's favour.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        (Currency unspecified, int128 unspecifiedDelta) = (params.amountSpecified < 0 == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        uint256 unspecifiedAmount =
            unspecifiedDelta < 0 ? uint256(uint128(-unspecifiedDelta)) : uint256(uint128(unspecifiedDelta));
        uint256 feeAmount = FullMath.mulDiv(unspecifiedAmount, hookFee, PIPS);
        if (feeAmount == 0) return (this.afterSwap.selector, 0);

        unspecified.take(poolManager, address(this), feeAmount, true);
        PoolId id = key.toId();
        pot[id][unspecified] += feeAmount;
        emit HookFeeTaken(id, unspecified, feeAmount);

        return (this.afterSwap.selector, feeAmount.toInt128());
    }

    // ── liquidity ────────────────────────────────────────────────────────────────────────────

    /// @dev `feesAccrued` is what the position earned in LP fees since it was last touched.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _creditBonus(sender, key, params.salt, feesAccrued);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Also runs for a change of zero liquidity, which is how fees are collected (Hooks.sol,
    ///      afterModifyLiquidity sends every non-positive change here).
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _creditBonus(sender, key, params.salt, feesAccrued);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Nothing in here may revert: it runs inside every deposit, withdrawal and fee collection.
    ///      The position's owner in the PoolManager is the calling contract, not a person. Only the
    ///      PositionManager is believed: it sets the salt to the position's token id, and its ERC-721
    ///      names the owner. A position whose token is already burned has no owner and earns no bonus.
    function _creditBonus(address sender, PoolKey calldata key, bytes32 salt, BalanceDelta feesAccrued) internal {
        if (sender != positionManager) return;

        int128 fees0 = feesAccrued.amount0();
        int128 fees1 = feesAccrued.amount1();
        if (fees0 <= 0 && fees1 <= 0) return;

        address account;
        try IPositionOwner(positionManager).ownerOf(uint256(salt)) returns (address positionOwner) {
            account = positionOwner;
        } catch {
            return;
        }
        if (!_holdsCredential(account)) return;

        PoolId id = key.toId();
        if (fees0 > 0) _creditFromPot(id, key.currency0, account, uint256(uint128(fees0)));
        if (fees1 > 0) _creditFromPot(id, key.currency1, account, uint256(uint128(fees1)));
    }

    function _creditFromPot(PoolId id, Currency currency, address account, uint256 fees) internal {
        uint256 available = pot[id][currency];
        uint256 amount = _bonus(fees, available);
        if (amount == 0) return;

        pot[id][currency] = available - amount;
        owed[account][currency] += amount;
        emit BonusCredited(id, account, currency, amount);
    }

    /// @notice The bonus to credit for `fees` of LP fees collected, when the pot holds `available`.
    /// @dev bonusRate of the fees, rounded down, and never more than the pot holds: a short pot pays
    ///      what is there. `fees` comes from an int128 and bonusRate is a uint24, so the product fits.
    function _bonus(uint256 fees, uint256 available) internal view returns (uint256) {
        uint256 fullBonus = (fees * bonusRate) / PIPS;
        return fullBonus > available ? available : fullBonus;
    }

    /// @dev A registry that reverts counts as "no credential", so it cannot stop a swap or a withdrawal.
    function _holdsCredential(address account) internal view returns (bool) {
        try credential.hasValidCredential(account, credentialId) returns (bool held) {
            return held;
        } catch {
            return false;
        }
    }

    // ── claiming ─────────────────────────────────────────────────────────────────────────────

    /// @notice Withdraw everything credited to the caller in `currency`.
    /// @dev The caller pulls; the hook never pushes. A recipient that refuses the transfer fails
    ///      only its own claim.
    function claim(Currency currency) external returns (uint256 amount) {
        amount = owed[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        owed[msg.sender][currency] = 0;
        emit Claimed(msg.sender, currency, amount);
        poolManager.unlock(abi.encode(msg.sender, currency, amount));
    }

    /// @dev The PoolManager calls this back only on the contract that called `unlock`, so the data is
    ///      always what `claim` encoded. Burns the hook's claims and takes the same amount of the
    ///      currency to the claimer: the two deltas cancel.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address to, Currency currency, uint256 amount) = abi.decode(data, (address, Currency, uint256));
        currency.settle(poolManager, address(this), amount, true);
        currency.take(poolManager, to, amount, false);
        return "";
    }
}
