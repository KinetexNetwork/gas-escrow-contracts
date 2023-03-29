// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

contract ProoferRegistry is Ownable, Multicall {
    event ProoferApproved(uint256 chain, address proofer);
    event ProoferRevoked(uint256 chain, address proofer);

    mapping(uint256 => mapping(address => bool)) public proofers; // chain, proofer, allowed

    function approveProofer(uint256 chain_, address proofer_) external onlyOwner {
        _setProoferAllowed(chain_, proofer_, true);
        emit ProoferApproved(chain_, proofer_);
    }

    function revokeProofer(uint256 chain_, address proofer_) external onlyOwner {
        _setProoferAllowed(chain_, proofer_, false);
        emit ProoferRevoked(chain_, proofer_);
    }

    function _setProoferAllowed(uint256 chain_, address proofer_, bool allowed_) private {
        require(proofers[chain_][proofer_] != allowed_, "PR: same proofer allowance");
        proofers[chain_][proofer_] = allowed_;
    }
}
