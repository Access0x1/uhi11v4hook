// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title HookFeePotTemplate
/// @notice Template for a hook that takes a fee on every swap's input into a per-pool pot it holds,
///         and lets a fixed treasury take a fixed share of it. A hook built on it decides what the
///         rest of the pot is spent on, through `_spendFromPot` and `_payOut`.
/// @dev Four flags, so four bits in the address:
///      beforeSwap 0x80 | afterSwap 0x40 | beforeSwapReturnDelta 0x08 | afterSwapReturnDelta 0x04 = 0xCC.
///      The fee is taken in the swap's INPUT currency, the one LP fees accrue in. That needs both
///      callbacks: an exact-input swap pays in beforeSwap, on the amount it REQUESTS (so a swap that
///      stops at its price limit has paid on all of it); an exact-output swap pays in afterSwap, on
///      what the pool charged, on top.
///      The pot is held as ERC-6909 claims on the PoolManager, one ledger per pool and currency, so
///      one pool's pot cannot pay for another's.
///      No owner. `sweep` can be called by anyone and pays only the treasury set at deployment.
abstract contract HookFeePotTemplate is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /// @dev Fees, rates and shares are in pips: 1e6 = 100%.
    uint256 internal constant PIPS = 1e6;

    /// @notice Taken from every swap's input, into the pot.
    uint24 public immutable hookFee;
    /// @notice The only address `sweep` pays.
    address public immutable treasury;
    /// @notice The most the treasury may ever have swept, as a share of all hook fees taken.
    uint24 public immutable treasuryShare;

    /// @notice Hook fees held for a pool and not yet spent or swept, per currency.
    mapping(PoolId => mapping(Currency => uint256)) public pot;
    /// @notice All hook fees ever taken on a pool, per currency. Only grows.
    mapping(PoolId => mapping(Currency => uint256)) public feesTaken;
    /// @notice All the treasury has swept from a pool, per currency. Only grows.
    mapping(PoolId => mapping(Currency => uint256)) public swept;

    event HookFeeTaken(PoolId indexed id, Currency indexed currency, uint256 amount);
    event Swept(PoolId indexed id, Currency indexed currency, uint256 amount);

    error HookFeeTooLarge(uint24 fee);
    error ShareTooLarge(uint24 share);
    error TreasuryNotSet();
    error NothingToSweep();

    constructor(uint24 hookFee_, address treasury_, uint24 treasuryShare_) {
        if (hookFee_ >= PIPS) revert HookFeeTooLarge(hookFee_);
        if (treasuryShare_ > PIPS) revert ShareTooLarge(treasuryShare_);
        if (treasuryShare_ != 0 && treasury_ == address(0)) revert TreasuryNotSet();
        hookFee = hookFee_;
        treasury = treasury_;
        treasuryShare = treasuryShare_;
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    // ── taking the fee ───────────────────────────────────────────────────────────────────────

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int128 taken;
        if (params.amountSpecified < 0) {
            uint256 feeAmount = FullMath.mulDiv(uint256(-params.amountSpecified), hookFee, PIPS);
            taken = _toPot(key, params.zeroForOne ? key.currency0 : key.currency1, feeAmount);
        }
        return (this.beforeSwap.selector, toBeforeSwapDelta(taken, 0), _lpFeeOverride(sender, key, params));
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        if (params.amountSpecified < 0) return (this.afterSwap.selector, 0);

        (Currency input, int128 inputDelta) =
            params.zeroForOne ? (key.currency0, delta.amount0()) : (key.currency1, delta.amount1());
        // The swapper owes the input, so its delta is negative.
        uint256 paid = inputDelta < 0 ? uint256(uint128(-inputDelta)) : 0;
        return (this.afterSwap.selector, _toPot(key, input, FullMath.mulDiv(paid, hookFee, PIPS)));
    }

    /// @notice beforeSwap's third return value: an LP fee override, or 0 for none.
    /// @dev This template owns beforeSwap, so a hook that also sets the LP fee does it here. Must not
    ///      revert. An override is honoured only on a dynamic-fee pool and needs the override flag.
    function _lpFeeOverride(address, PoolKey calldata, SwapParams calldata) internal view virtual returns (uint24) {
        return 0;
    }

    /// @dev Takes `feeAmount` of `currency` as claims and adds it to the pool's pot. The value
    ///      returned goes back to the PoolManager as the hook's delta, which charges the swapper and
    ///      cancels the claims minted here. Fees round down, in the swapper's favour.
    function _toPot(PoolKey calldata key, Currency currency, uint256 feeAmount) internal returns (int128) {
        if (feeAmount == 0) return 0;

        currency.take(poolManager, address(this), feeAmount, true);
        PoolId id = key.toId();
        pot[id][currency] += feeAmount;
        feesTaken[id][currency] += feeAmount;
        emit HookFeeTaken(id, currency, feeAmount);
        return feeAmount.toInt128();
    }

    // ── spending the pot ─────────────────────────────────────────────────────────────────────

    /// @dev For the hook built on this template: takes `amount` out of a pool's pot. The hook then
    ///      owes it to someone and pays it with `_payOut`. Reverts if the pot holds less.
    function _spendFromPot(PoolId id, Currency currency, uint256 amount) internal {
        pot[id][currency] -= amount;
    }

    /// @notice What `sweep` would pay the treasury now for this pool and currency.
    /// @dev The treasury's lifetime total is capped at treasuryShare of all fees ever taken, so at
    ///      least the rest has always been available to whatever else the pot is for. Never more
    ///      than the pot holds.
    function sweepable(PoolId id, Currency currency) public view returns (uint256) {
        uint256 entitled = FullMath.mulDiv(feesTaken[id][currency], treasuryShare, PIPS);
        uint256 alreadySwept = swept[id][currency];
        if (entitled <= alreadySwept) return 0;

        uint256 available = pot[id][currency];
        uint256 remaining = entitled - alreadySwept;
        return remaining > available ? available : remaining;
    }

    /// @notice Pay the treasury what it may take from this pool's pot in `currency`. Anyone may call.
    function sweep(PoolId id, Currency currency) external returns (uint256 amount) {
        amount = sweepable(id, currency);
        if (amount == 0) revert NothingToSweep();

        swept[id][currency] += amount;
        pot[id][currency] -= amount;
        emit Swept(id, currency, amount);
        _payOut(treasury, currency, amount);
    }

    /// @dev Burns `amount` of the hook's claims and sends the currency to `to`. The caller has
    ///      already taken the amount off whichever ledger it came from.
    function _payOut(address to, Currency currency, uint256 amount) internal {
        poolManager.unlock(abi.encode(to, currency, amount));
    }

    /// @dev The PoolManager calls this back only on the contract that called `unlock`, so the data is
    ///      always what `_payOut` encoded. The burn and the take cancel.
    function unlockCallback(bytes calldata data) external virtual onlyPoolManager returns (bytes memory) {
        (address to, Currency currency, uint256 amount) = abi.decode(data, (address, Currency, uint256));
        currency.settle(poolManager, address(this), amount, true);
        currency.take(poolManager, to, amount, false);
        return "";
    }
}
