// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ICredential} from "./interfaces/ICredential.sol";
import {HookFeePotTemplate} from "./templates/HookFeePotTemplate.sol";
import {FeesCollectedTemplate} from "./templates/FeesCollectedTemplate.sol";
import {SwapperIdentity} from "./templates/SwapperIdentity.sol";
import {FeeOverride} from "./templates/FeeOverride.sol";

/// @title ReverseV4Hook
/// @custom:routing MANUAL. Dynamic-fee pools only, and both swap returns-delta flags. Uniswap's interface does not
///                 route to it until Uniswap Labs allowlists this address. The PoolManager itself accepts it.
/// @notice A loyalty hook with its own accounting, for dynamic-fee pools.
///         1. A swapper who holds the credential pays `memberFee` to the pool's LPs; anyone else pays `baseFee`.
///         2. Every swap also pays `hookFee` on its input into a per-pool pot the hook holds.
///         3. When a credential holder's position collects LP fees, the hook credits that holder a bonus of
///            `bonusRate` on the fees collected, out of the pot. The holder withdraws it with `claim`.
///         4. A treasury set at deployment may take up to `treasuryShare` of the hook fees, through `sweep`.
///            The share is bounded at deployment so that it cannot be taken out of the bonuses' part.
/// @dev Built from this repository's templates, and its mask is theirs combined:
///        HookFeePotTemplate    0xCC    beforeSwap, afterSwap and both swap returns-delta flags
///        FeesCollectedTemplate 0x500   afterAddLiquidity, afterRemoveLiquidity
///        this contract         0x2020  beforeInitialize (dynamic-fee pools only), beforeDonate (refused)
///      0xCC | 0x500 | 0x2020 = 0x25EC. SwapperIdentity and FeeOverride own no callback.
///      No owner, no upgrade path, every parameter immutable.
contract ReverseV4Hook is HookFeePotTemplate, FeesCollectedTemplate, SwapperIdentity, FeeOverride {
    /// @notice The registry asked whether an account holds the credential.
    ICredential public immutable credential;
    /// @notice The kind of credential that earns the member fee and the bonus.
    bytes32 public immutable credentialId;

    /// @notice LP fee for a credential holder who came through the trusted router.
    uint24 public immutable memberFee;
    /// @notice Bonus on LP fees collected by a credential holder's position, paid out of the pot.
    uint24 public immutable bonusRate;

    /// @notice Bonus credited to an account and not yet claimed, per currency.
    mapping(address => mapping(Currency => uint256)) public owed;

    event BonusCredited(PoolId indexed id, address indexed account, Currency indexed currency, uint256 amount);
    event Claimed(address indexed account, Currency indexed currency, uint256 amount);

    error MemberFeeAboveBaseFee();
    /// @dev bonusRate * baseFee must not exceed hookFee * 1e6. See the constructor.
    error BonusNotCoveredByHookFee();
    /// @dev treasuryShare * hookFee + bonusRate * baseFee must not exceed hookFee * 1e6. See the constructor.
    error TreasuryShareNotCovered();
    error DonationsNotAccepted();
    error NothingToClaim();

    /// @dev Everything the hook is deployed with. A struct, so the constructor fits the compiler's stack.
    struct Config {
        ICredential credential;
        bytes32 credentialId;
        address positionManager;
        address swapRouter;
        uint24 baseFee;
        uint24 memberFee;
        uint24 hookFee;
        uint24 bonusRate;
        address treasury;
        uint24 treasuryShare;
    }

    /// @dev BaseHook's constructor checks this contract's own address against getHookPermissions()
    ///      and reverts with HookAddressNotValid if the low 14 bits disagree.
    ///
    ///      The bound on bonusRate is what makes trading with yourself unprofitable. Someone who is the
    ///      only in-range LP gets the LP fee of their own swap straight back, at most baseFee of the
    ///      input, and with it a bonus of bonusRate on that fee. The same swap pays hookFee of the input
    ///      into the pot, in the same currency. While bonusRate * baseFee <= hookFee * 1e6, the swap puts
    ///      in at least what the bonus takes out.
    ///
    ///      The bound on treasuryShare keeps the treasury out of the bonuses' part of the pot. Bonuses
    ///      can use at most bonusRate * baseFee / hookFee of the hook fees, which happens when every
    ///      position holds the credential. The treasury's share must fit in what is left:
    ///      treasuryShare + bonusRate * baseFee / hookFee <= 100%, written without the division.
    constructor(IPoolManager poolManager_, Config memory c)
        BaseHook(poolManager_)
        HookFeePotTemplate(c.hookFee, c.treasury, c.treasuryShare)
        FeesCollectedTemplate(c.positionManager)
        SwapperIdentity(_only(c.swapRouter))
        FeeOverride(c.baseFee)
    {
        // A try/catch around a call to an address without code still reverts, which would stop
        // every swap on the pool.
        if (address(c.credential).code.length == 0) revert NotAContract(address(c.credential));
        if (c.memberFee > c.baseFee) revert MemberFeeAboveBaseFee();
        if (uint256(c.bonusRate) * c.baseFee > uint256(c.hookFee) * PIPS) revert BonusNotCoveredByHookFee();
        if (uint256(c.treasuryShare) * c.hookFee + uint256(c.bonusRate) * c.baseFee > uint256(c.hookFee) * PIPS) {
            revert TreasuryShareNotCovered();
        }

        credential = c.credential;
        credentialId = c.credentialId;
        memberFee = c.memberFee;
        bonusRate = c.bonusRate;
    }

    function _only(address router) private pure returns (address[] memory routers) {
        routers = new address[](1);
        routers[0] = router;
    }

    /// @notice The callbacks this hook implements: the two templates' and its own two.
    function getHookPermissions()
        public
        pure
        override(HookFeePotTemplate, FeesCollectedTemplate)
        returns (Hooks.Permissions memory permissions)
    {
        permissions.beforeInitialize = true;
        permissions.afterAddLiquidity = true;
        permissions.afterRemoveLiquidity = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeDonate = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    // ── wiring: which template answers which callback ────────────────────────────────────────
    //
    // Both templates descend from BaseHook, so each callback one of them implements has to be
    // pointed at that template by name. Nothing else happens in these four functions.

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override(BaseHook, HookFeePotTemplate)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return HookFeePotTemplate._beforeSwap(sender, key, params, hookData);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override(BaseHook, HookFeePotTemplate) returns (bytes4, int128) {
        return HookFeePotTemplate._afterSwap(sender, key, params, delta, hookData);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override(BaseHook, FeesCollectedTemplate) returns (bytes4, BalanceDelta) {
        return FeesCollectedTemplate._afterAddLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override(BaseHook, FeesCollectedTemplate) returns (bytes4, BalanceDelta) {
        return FeesCollectedTemplate._afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    // ── the pool ─────────────────────────────────────────────────────────────────────────────

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        _requireDynamicFee(key);
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

    // ── the LP fee ───────────────────────────────────────────────────────────────────────────

    /// @dev The fee pot's beforeSwap asks this for the swap's LP fee.
    function _lpFeeOverride(address sender, PoolKey calldata, SwapParams calldata)
        internal
        view
        override
        returns (uint24)
    {
        return _asOverride(_holdsCredential(_swapperOf(sender)) ? memberFee : baseFee);
    }

    // ── the bonus ────────────────────────────────────────────────────────────────────────────

    /// @dev Called when a position held through the PositionManager collects LP fees.
    function _onFeesCollected(PoolKey calldata key, address account, uint256 fees0, uint256 fees1) internal override {
        if (!_holdsCredential(account)) return;

        PoolId id = key.toId();
        if (fees0 != 0) _creditFromPot(id, key.currency0, account, fees0);
        if (fees1 != 0) _creditFromPot(id, key.currency1, account, fees1);
    }

    function _creditFromPot(PoolId id, Currency currency, address account, uint256 fees) internal {
        uint256 amount = _bonus(fees, pot[id][currency]);
        if (amount == 0) return;

        _spendFromPot(id, currency, amount);
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
    ///      Nobody (address(0), an unrecognised swapper) holds one.
    function _holdsCredential(address account) internal view returns (bool) {
        if (account == address(0)) return false;
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
        _payOut(msg.sender, currency, amount);
    }
}
