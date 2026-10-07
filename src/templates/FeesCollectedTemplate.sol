// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev The one function this template needs from the PositionManager's ERC-721.
interface IPositionOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title FeesCollectedTemplate
/// @custom:routing AUTOMATIC. No swap returns-delta flag, and it works on static-fee pools.
/// @notice Template for a hook that acts when a position collects LP fees, knowing who owns the
///         position and how much it earned. A hook built on it writes one function, `_onFeesCollected`.
/// @dev Two flags, so two bits in the address: afterAddLiquidity 0x400 | afterRemoveLiquidity 0x100 = 0x500.
///      The PoolManager hands both callbacks `feesAccrued`: the LP fees the position earned since it
///      was last touched, already worked out for its range. A change of zero liquidity, which is how
///      fees are collected, arrives at afterRemoveLiquidity (Hooks.sol, afterModifyLiquidity).
///      A position's owner in the PoolManager is the contract that called it, not a person. Only the
///      PositionManager named at deployment is believed: it sets the position's salt to its token
///      id, and its ERC-721 names the holder.
///      What the template guarantees: nothing in it reverts, so it cannot block a deposit, a
///      withdrawal or a collection; a position held any other way is skipped; a position whose token
///      is already burned is skipped (the PositionManager burns the token before it removes the
///      liquidity, so collect before burning).
///      A hook that PAYS on fees collected must also refuse donations (beforeDonate, 0x20): an LP
///      alone in range can donate to itself and receive the donation back as fees collected.
abstract contract FeesCollectedTemplate is BaseHook {
    /// @notice The only liquidity caller whose positions are recognised.
    address public immutable positionManager;

    error PositionManagerHasNoCode();

    constructor(address positionManager_) {
        // A try/catch around a call to an address without code still reverts, and that would
        // block every liquidity change on the pool.
        if (positionManager_.code.length == 0) revert PositionManagerHasNoCode();
        positionManager = positionManager_;
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.afterAddLiquidity = true;
        permissions.afterRemoveLiquidity = true;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        _collected(sender, key, params.salt, feesAccrued);
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal virtual override returns (bytes4, BalanceDelta) {
        _collected(sender, key, params.salt, feesAccrued);
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _collected(address sender, PoolKey calldata key, bytes32 salt, BalanceDelta feesAccrued) private {
        if (sender != positionManager) return;

        int128 fees0 = feesAccrued.amount0();
        int128 fees1 = feesAccrued.amount1();
        if (fees0 <= 0 && fees1 <= 0) return;

        try IPositionOwner(positionManager).ownerOf(uint256(salt)) returns (address account) {
            _onFeesCollected(
                key, account, fees0 > 0 ? uint256(uint128(fees0)) : 0, fees1 > 0 ? uint256(uint128(fees1)) : 0
            );
        } catch {}
    }

    /// @notice `account`'s position on this pool just collected `fees0` and `fees1` in LP fees.
    /// @dev Must not revert: it runs inside every deposit, withdrawal and collection through the
    ///      PositionManager. At least one of the two amounts is non-zero.
    function _onFeesCollected(PoolKey calldata key, address account, uint256 fees0, uint256 fees1) internal virtual;
}
