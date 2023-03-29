// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

library SignatureHelper {
    function read(bytes calldata signature_, uint256 offset_) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            let ptr := add(signature_.offset, offset_)
            r := calldataload(ptr)
            s := calldataload(add(ptr, 0x20))
            v := byte(0, calldataload(add(ptr, 0x40)))
        }
    }
}
