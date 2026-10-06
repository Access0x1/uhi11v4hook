// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICredential} from "../interfaces/ICredential.sol";

/// @title TestnetCredentialRegistry
/// @notice A credential registry for testnets: one issuer says who holds which kind of credential,
///         and until when. It exists so that a hook which asks `hasValidCredential` has something
///         real to ask on a testnet.
/// @dev Not a credential system. The issuer is a single address fixed at deployment, grants cost
///      it nothing and prove nothing about the account, and there is no way to change the issuer.
///      Anything that matters must not depend on it.
contract TestnetCredentialRegistry is ICredential {
    /// @notice The only address that may grant or revoke.
    address public immutable issuer;

    /// @notice The last second at which `account` holds a credential of kind `id`. Zero: none.
    mapping(address account => mapping(bytes32 id => uint64)) public validUntil;

    event Granted(address indexed account, bytes32 indexed id, uint64 validUntil);
    event Revoked(address indexed account, bytes32 indexed id);

    error IssuerNotSet();
    error NotIssuer(address caller);
    error AccountNotSet();
    error AlreadyExpired(uint64 validUntil);

    constructor(address issuer_) {
        if (issuer_ == address(0)) revert IssuerNotSet();
        issuer = issuer_;
    }

    modifier onlyIssuer() {
        if (msg.sender != issuer) revert NotIssuer(msg.sender);
        _;
    }

    /// @notice Give `account` a credential of kind `id`, valid through the second `until`.
    /// @dev Granting again replaces the expiry, later or earlier. Address zero is refused: a hook
    ///      may use it to mean "nobody", and nobody must never hold a credential.
    function grant(address account, bytes32 id, uint64 until) external onlyIssuer {
        if (account == address(0)) revert AccountNotSet();
        if (until < block.timestamp) revert AlreadyExpired(until);
        validUntil[account][id] = until;
        emit Granted(account, id, until);
    }

    /// @notice Take the credential away at once.
    function revoke(address account, bytes32 id) external onlyIssuer {
        delete validUntil[account][id];
        emit Revoked(account, id);
    }

    /// @inheritdoc ICredential
    function hasValidCredential(address account, bytes32 id) external view returns (bool) {
        uint64 until = validUntil[account][id];
        return until != 0 && block.timestamp <= until;
    }
}
