// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ICredential
/// @notice The one question ReverseV4Hook asks of a credential registry.
interface ICredential {
    /// @notice Whether `account` holds a credential of kind `credentialId` that is valid in this block.
    function hasValidCredential(address account, bytes32 credentialId) external view returns (bool);
}
