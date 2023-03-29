// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

import {Proof, ProofValidator} from "../ProofValidator.sol";
import {ProoferRegistry} from "../ProoferRegistry.sol";

library ProofHelper {
    function validate(Proof calldata proof_, bytes calldata proofSignature_, address proofValidator_, uint256 birthPast_, uint256 birthFuture_, uint256 chain_, address prooferRegistry_, bytes32 dataHash_) internal view {
        ProofValidator(proofValidator_).validateProof(proof_, proofSignature_);
        require(proof_.birth >= block.timestamp - birthPast_, "PH: proof expired");
        require(proof_.birth <= block.timestamp + birthFuture_, "PH: proof not born");
        require(proof_.chain == chain_, "PH: proof chain invalid");
        require(ProoferRegistry(prooferRegistry_).proofers(proof_.chain, proof_.target), "PH: proof target invalid");
        require(keccak256(proof_.data) == dataHash_, "PH: proof data invalid");
    }
}
