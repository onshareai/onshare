// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OnshareAccount} from "./OnshareAccount.sol";

/// @title OnshareAccountFactory
/// @notice Deploys one OnshareAccount per caller and salt, at a predictable CREATE2 address.
contract OnshareAccountFactory {
    address public immutable quoteToken;
    address public immutable quoteFeed;

    event AccountCreated(address indexed owner, address indexed account, bytes32 salt);

    constructor(address quoteToken_, address quoteFeed_) {
        quoteToken = quoteToken_;
        quoteFeed = quoteFeed_;
    }

    /// @notice Create an account owned by the caller.
    function createAccount(bytes32 salt) external returns (OnshareAccount account) {
        account = new OnshareAccount{salt: _salt(msg.sender, salt)}(msg.sender, quoteToken, quoteFeed);
        emit AccountCreated(msg.sender, address(account), salt);
    }

    /// @notice Address an account for `owner` and `salt` will have (or has).
    function accountAddress(address owner, bytes32 salt) external view returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _salt(owner, salt),
                keccak256(abi.encodePacked(type(OnshareAccount).creationCode, abi.encode(owner, quoteToken, quoteFeed)))
            )
        );
        return address(uint160(uint256(h)));
    }

    function _salt(address owner, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }
}
