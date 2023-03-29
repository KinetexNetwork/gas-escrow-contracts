// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {Estimable} from "./lib/Estimable.sol";
import {SignatureHelper} from "./lib/SignatureHelper.sol";

struct Proof {
    uint256 birth;
    uint256 chain;
    address target;
    bytes data;
    bytes result;
}

contract ProofValidator is Ownable, Multicall, Estimable {
    event SignerApproved(address signer, bytes32 fingerprint);
    event SignerRevoked(address signer);
    event ThresholdSet(uint256 threshold);

    mapping(address => bytes32) public signers; // signer, fingerprint
    uint256 public threshold;

    constructor() {
        setThreshold(1);
    }

    function approveSigner(address signer_, bytes32 fingerprint_) external onlyOwner {
        require(fingerprint_ != bytes32(0), "PV: zero fingerprint");
        _setSigner(signer_, fingerprint_);
        emit SignerApproved(signer_, fingerprint_);
    }

    function revokeSigner(address signer_) external onlyOwner {
        _setSigner(signer_, bytes32(0));
        emit SignerRevoked(signer_);
    }

    function _setSigner(address signer_, bytes32 fingerprint_) private {
        require(signers[signer_] != fingerprint_, "PV: same signer");
        signers[signer_] = fingerprint_;
    }

    function setThreshold(uint256 threshold_) public onlyOwner {
        require(threshold_ > 0, "PV: threshold > 0");
        require(threshold != threshold_, "PV: same threshold");
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    function validateProof(Proof calldata proof_, bytes calldata proofSignatures_) external view {
        require(proofSignatures_.length % 65 == 0, "PV: bad signature pack");
        uint256 totalSignatures = proofSignatures_.length / 65;
        require(totalSignatures >= _validationThreshold(), "PV: threshold not reached");

        bytes32 proofHash = ECDSA.toTypedDataHash(0x60b7d43486679ca1385badf1ecc33d42c7769bc89a2d77d4282e0ca113ac12df, keccak256(abi.encode(0x023476c441462fe6af2a3f462964f59189c84129ade757925f54c807a88cf772, proof_.birth, proof_.chain, proof_.target, keccak256(proof_.data), keccak256(proof_.result))));

        address[] memory usedSigners = new address[](totalSignatures);
        uint256 offset = 0;
        for (uint256 i = 0; i < totalSignatures; i = _inc(i)) {
            (bytes32 r, bytes32 s, uint8 v) = SignatureHelper.read(proofSignatures_, offset);
            (address signer, ECDSA.RecoverError error) = ECDSA.tryRecover(proofHash, v, r, s);
            require(error == ECDSA.RecoverError.NoError || _inEstimate(), "PV: invalid signature");
            require(_validationSigners(signer) != bytes32(0) || _inEstimate(), "PV: bad signer");
            for (uint256 j = 0; j < i; j = _inc(j)) require(usedSigners[j] != signer || _inEstimate(), "PV: duplicate signer");
            usedSigners[i] = signer;
            unchecked { offset += 65; }
        }
    }

    function _validationThreshold() internal virtual view returns (uint256) {
        return threshold;
    }

    function _validationSigners(address signer_) internal virtual view returns (bytes32) {
        return signers[signer_];
    }

    function _inc(uint256 x) private pure returns (uint256) {
        unchecked { return x + 1; }
    }
}
