// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

abstract contract Estimable {
    function _inEstimate() internal virtual view returns (bool) {
        return false;
    }
}
