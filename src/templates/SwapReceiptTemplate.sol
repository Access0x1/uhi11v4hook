// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SwapperIdentity} from "./SwapperIdentity.sol";

/// @title SwapReceiptTemplate
/// @notice Template for a hook that writes one receipt for a swap that names a payee and a reference.
///         A hook built on it writes one function, `_payeeIsValid`.
/// @dev One flag, so one bit in the address: afterSwap 0x40. Moves no funds, returns no delta, and
///      changes no price or fee. What the template guarantees, whatever the hook's payee rule is:
///        - a swap is never reverted by this hook: bad, missing or repeated receipt data means no
///          receipt, and the swap goes through;
///        - the amounts on a receipt are what the swap actually moved, not what was asked for;
///        - a receipt id is recorded at most once;
///        - the payer is taken from a trusted router or left empty, never from hookData.
///      A receipt says who the swap NAMED. It does not say where the swap's output went: that is the
///      router's choice, and a hook with this mask cannot see or control it.
abstract contract SwapReceiptTemplate is BaseHook, SwapperIdentity {
    /// @dev hookData for a receipt is exactly abi.encode(bytes32 payee, bytes32 orderRef).
    uint256 internal constant RECEIPT_DATA_LENGTH = 64;

    enum Refusal {
        Malformed,
        InvalidPayee,
        Duplicate
    }

    /// @notice Whether a receipt with this id has been written.
    mapping(bytes32 id => bool) public receipted;

    /// @param amount0 and amount1 are the swap's deltas from the swapper's side: negative paid, positive received.
    event Receipt(
        bytes32 indexed id,
        PoolId indexed poolId,
        bytes32 indexed payee,
        bytes32 orderRef,
        address payer,
        address sender,
        int128 amount0,
        int128 amount1
    );

    /// @notice A swap carried receipt data and no receipt was written. The swap itself went through.
    event ReceiptRefused(PoolId indexed poolId, address sender, Refusal reason);

    constructor(IPoolManager poolManager_, address[] memory trustedRouters_)
        BaseHook(poolManager_)
        SwapperIdentity(trustedRouters_)
    {}

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
    }

    /// @dev Runs after the pool has moved, so `delta` is final: this address has no returns-delta bit
    ///      and nothing after this callback changes the swapper's amounts. Nothing in here reverts.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        if (hookData.length != 0) _receipt(sender, key.toId(), delta, hookData);
        return (this.afterSwap.selector, 0);
    }

    function _receipt(address sender, PoolId poolId, BalanceDelta delta, bytes calldata hookData) internal {
        if (hookData.length != RECEIPT_DATA_LENGTH) {
            emit ReceiptRefused(poolId, sender, Refusal.Malformed);
            return;
        }
        // Two static words of exactly 64 bytes: this decode cannot revert.
        (bytes32 payee, bytes32 orderRef) = abi.decode(hookData, (bytes32, bytes32));

        if (!_payeeIsValid(payee)) {
            emit ReceiptRefused(poolId, sender, Refusal.InvalidPayee);
            return;
        }

        address payer = _swapperOf(sender);
        bytes32 id = receiptId(poolId, payee, orderRef, payer);
        if (receipted[id]) {
            emit ReceiptRefused(poolId, sender, Refusal.Duplicate);
            return;
        }

        receipted[id] = true;
        emit Receipt(id, poolId, payee, orderRef, payer, sender, delta.amount0(), delta.amount1());
    }

    /// @notice Whether `payee` may be named on a receipt. The one function a hook on this template writes.
    /// @dev Must not revert: it runs inside a swap. Wrap any outside call in try/catch and return false.
    function _payeeIsValid(bytes32 payee) internal view virtual returns (bool);

    /// @notice The id of the receipt for these four facts. Two swaps with the same id produce one receipt.
    /// @dev One receipt per pool, payee, order reference and payer. The payer is part of the id so
    ///      that a stranger who names someone else's order writes a receipt under their own address
    ///      and cannot use the order up. An order can therefore have several receipts: a reader
    ///      matches the payer it expects.
    ///      `payer` is address(0) when the swap did not come through a trusted router. Those swaps
    ///      share one id per order, so the first one takes it: an empty payer proves nothing about
    ///      who paid. Public, so an indexer or a front end computes the same id the hook does.
    function receiptId(PoolId poolId, bytes32 payee, bytes32 orderRef, address payer)
        public
        pure
        virtual
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, payee, orderRef, payer));
    }
}
