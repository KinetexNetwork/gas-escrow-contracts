// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

import {EIP712, ECDSA} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {TokenInteractor} from "./lib/TokenInteractor.sol";
import {ProofHelper, Proof} from "./lib/ProofHelper.sol";
import {SignatureHelper} from "./lib/SignatureHelper.sol";
import {Estimable} from "./lib/Estimable.sol";

struct Deposit {
    uint256 chain;
    address[] tokens;
    uint256[] amounts;
    uint256[] providerRewards;
    uint256[] insurerRewards;
}

struct GasBorrow {
    address borrower;
    address[] receivers;
    uint256[] amounts;
    uint256 lenderReward;
    uint256 repayTime;
    address depositor;
    Deposit deposit;
    uint256 depositRequiredCost;
    uint256 nonce;
    uint256 deadline;
}

enum BorrowState {
    None,
    Lent,
    Repaid,
    Liquidated
}

struct BorrowParticipants {
    address borrower;
    address depositor;
    address lender;
    address closer;
}

struct BorrowRecord {
    BorrowState state;
    BorrowParticipants participants;
    uint256 amount;
    uint256 deadline;
    Deposit deposit;
    uint256 depositRequiredCost;
}

struct LiquidatedBorrow {
    BorrowParticipants participants;
    Deposit deposit;
}

contract GasProvider is EIP712, TokenInteractor, Estimable {
    event GasLent(bytes32 borrowHash);
    event GasRepaid(bytes32 borrowHash);
    event Liquidated(bytes32 borrowHash);

    address public immutable proofValidator;
    address public immutable insurerProoferRegistry;

    mapping(address => mapping(uint256 => bool)) private _usedBorrowNonces; // borrower, nonce, used
    mapping(address => mapping(uint256 => mapping(address => uint256))) public usedDepositAmounts; // depositor, chain, token, amount
    mapping(bytes32 => BorrowRecord) private _borrows; // borrow hash, borrow
    mapping(address => mapping(uint256 => mapping(uint256 => bytes32[]))) private _liquidationsTimeline; // depositor, chain, time frame, borrow hashes

    constructor(address proofValidator_, address insurerProoferRegistry_)
        EIP712("Kinetex Gas Provider", "1") {
        proofValidator = proofValidator_;
        insurerProoferRegistry = insurerProoferRegistry_;
    }

    function lendGas(GasBorrow calldata borrow_, bytes calldata borrowSignature_, Proof calldata depositProof_, bytes calldata depositProofSignature_) external payable valueTrack returns (bytes32 borrowHash) {
        borrowHash = _useBorrow(borrow_, borrowSignature_);
        _useDeposit(borrow_, depositProof_, depositProofSignature_);

        uint256 repayAmount = borrow_.lenderReward;
        for (uint256 i = 0; i < borrow_.receivers.length; i++) {
            _resendToken(NATIVE_TOKEN, borrow_.amounts[i], borrow_.receivers[i]);
            repayAmount += borrow_.amounts[i];
        }

        _borrows[borrowHash] = BorrowRecord({state: BorrowState.Lent, participants: BorrowParticipants({borrower: borrow_.borrower, depositor: borrow_.depositor, lender: msg.sender, closer: address(0)}), amount: repayAmount, deadline: block.timestamp + borrow_.repayTime, deposit: borrow_.deposit, depositRequiredCost: borrow_.depositRequiredCost});
        emit GasLent(borrowHash);
    }

    function repayGas(bytes32 borrowHash_) external payable valueTrack {
        BorrowRecord storage borrow = _borrowInState(borrowHash_, BorrowState.Lent);
        _resendToken(NATIVE_TOKEN, borrow.amount, borrow.participants.lender);
        _closeBorrow(borrow, BorrowState.Repaid);
        emit GasRepaid(borrowHash_);
    }

    function borrows(bytes32 borrowHash_) external view returns (BorrowRecord memory) {
        return _borrows[borrowHash_];
    }

    function liquidatedBorrows(bytes32 borrowHash_) external view returns (LiquidatedBorrow memory) {
        BorrowRecord storage borrow = _borrowInState(borrowHash_, BorrowState.Liquidated);
        return LiquidatedBorrow({participants: borrow.participants, deposit: borrow.deposit});
    }

    function recentLiquidations(address depositor_, uint256 chain_) public view returns (bytes32[] memory borrowHashes) {
        uint256 currentFrame = _liquidationTimelineFrame();
        bytes32[] storage previousLiquidations = _liquidationsTimeline[depositor_][chain_][currentFrame - 1];
        bytes32[] storage currentLiquidations = _liquidationsTimeline[depositor_][chain_][currentFrame];
        borrowHashes = new bytes32[](previousLiquidations.length + currentLiquidations.length);
        for (uint256 i = 0; i < previousLiquidations.length; i++)
            borrowHashes[i] = previousLiquidations[i];
        for (uint256 i = 0; i < currentLiquidations.length; i++)
            borrowHashes[i + previousLiquidations.length] = currentLiquidations[i];
    }

    function depositorState(address depositor_, uint256 chain_, address token_) external view returns (uint256 usedDepositAmount, bytes32[] memory liquidatedBorrowHashes) {
        return (usedDepositAmounts[depositor_][chain_][token_], recentLiquidations(depositor_, chain_));
    }

    function canLiquidateByTime(bytes32 borrowHash_) public view returns (bool) {
        return block.timestamp >= _borrowInState(borrowHash_, BorrowState.Lent).deadline;
    }

    function liquidateByTime(bytes32 borrowHash_) external payable valueTrack {
        require(canLiquidateByTime(borrowHash_), "GP: cannot liquidate by time");
        _liquidate(borrowHash_);
    }

    function canLiquidateByCost(bytes32 borrowHash_, Proof calldata costProof_, bytes calldata costProofSignature_) public view returns (bool) {
        BorrowRecord storage borrow = _borrowInState(borrowHash_, BorrowState.Lent);
        ProofHelper.validate(costProof_, costProofSignature_, proofValidator, 5 minutes, 15 seconds, borrow.deposit.chain, insurerProoferRegistry, keccak256(abi.encodeWithSignature("costState(address[],uint256[])", borrow.deposit.tokens, borrow.deposit.amounts)));
        return abi.decode(costProof_.result, (uint256)) < borrow.depositRequiredCost;
    }

    function liquidateByCost(bytes32 borrowHash_, Proof calldata costProof_, bytes calldata costProofSignature_) external payable valueTrack {
        require(canLiquidateByCost(borrowHash_, costProof_, costProofSignature_), "GP: cannot liquidate by cost");
        _liquidate(borrowHash_);
    }

    function _borrowInState(bytes32 borrowHash_, BorrowState state_) private view returns (BorrowRecord storage borrow) {
        borrow = _borrows[borrowHash_];
        require(borrow.state == state_, "GP: wrong borrow state");
    }

    function _useBorrow(GasBorrow calldata borrow_, bytes calldata borrowSignature_) private returns (bytes32 borrowHash) {
        require(block.timestamp < borrow_.deadline, "GP: borrow expired");

        require(borrow_.receivers.length == borrow_.amounts.length, "GP: bad borrow receivers");
        require(borrow_.deposit.amounts.length == borrow_.deposit.tokens.length, "GP: bad deposit amounts");
        require(borrow_.deposit.providerRewards.length == borrow_.deposit.tokens.length, "GP: bad deposit provider rewards");
        require(borrow_.deposit.insurerRewards.length == borrow_.deposit.tokens.length, "GP: bad deposit insurer rewards");
        for (uint256 i = 0; i < borrow_.deposit.tokens.length; i++)
            require(borrow_.deposit.providerRewards[i] + borrow_.deposit.insurerRewards[i] <= borrow_.deposit.amounts[i], "GP: insufficient reward deposit");

        bytes32 depositHash = keccak256(abi.encode(0x7653ae9e734ca6fd1f22f7df14633b21a3e6d98b5f6c98f789d68747948ce463, borrow_.deposit.chain, keccak256(abi.encodePacked(borrow_.deposit.tokens)), keccak256(abi.encodePacked(borrow_.deposit.amounts)), keccak256(abi.encodePacked(borrow_.deposit.providerRewards)), keccak256(abi.encodePacked(borrow_.deposit.insurerRewards))));
        borrowHash = _hashTypedDataV4(keccak256(abi.encode(0x8f9f823c81bdd57c2e5f9ec021a3f9b8052f738c82cafc2b79bb48d0b1fb29c3, borrow_.borrower, keccak256(abi.encodePacked(borrow_.receivers)), keccak256(abi.encodePacked(borrow_.amounts)), borrow_.lenderReward, borrow_.repayTime, borrow_.depositor, depositHash, borrow_.depositRequiredCost, borrow_.nonce)));

        (bytes32 r, bytes32 s, uint8 v) = SignatureHelper.read(borrowSignature_, 0);
        require(ECDSA.recover(borrowHash, v, r, s) == borrow_.borrower || _inEstimate(), "GP: invalid borrow signer");

        require(!_usedBorrowNonces[borrow_.borrower][borrow_.nonce], "GP: invalid borrow nonce");
        _usedBorrowNonces[borrow_.borrower][borrow_.nonce] = true;
    }

    function _useDeposit(GasBorrow calldata borrow_, Proof calldata depositProof_, bytes calldata depositProofSignature_) private {
        bytes32 dataHash = keccak256(abi.encodeWithSignature("depositCostState(address,address,uint256,address[],uint256[])", borrow_.depositor, borrow_.borrower, block.chainid, borrow_.deposit.tokens, borrow_.deposit.amounts));
        ProofHelper.validate(depositProof_, depositProofSignature_, proofValidator, 5 minutes, 15 seconds, borrow_.deposit.chain, insurerProoferRegistry, dataHash);
        (uint256 depositCost, uint256[] memory depositAmounts) = abi.decode(depositProof_.result, (uint256, uint256[]));
        require(depositCost >= borrow_.depositRequiredCost, "TG: required deposit not reached");

        for (uint256 i = 0; i < borrow_.deposit.tokens.length; i++) {
            uint256 availableDeposit = depositAmounts[i] - usedDepositAmounts[borrow_.depositor][borrow_.deposit.chain][borrow_.deposit.tokens[i]];
            require(availableDeposit >= borrow_.deposit.amounts[i], "GP: insufficient deposit");
            usedDepositAmounts[borrow_.depositor][borrow_.deposit.chain][borrow_.deposit.tokens[i]] += borrow_.deposit.amounts[i];
        }
    }

    function _liquidate(bytes32 borrowHash_) private {
        BorrowRecord storage borrow = _borrowInState(borrowHash_, BorrowState.Lent);
        _closeBorrow(borrow, BorrowState.Liquidated);
        _liquidationsTimeline[borrow.participants.depositor][borrow.deposit.chain][_liquidationTimelineFrame()].push(borrowHash_);
        emit Liquidated(borrowHash_);
    }

    function _liquidationTimelineFrame() private view returns (uint256) {
        return block.timestamp / 12 hours;
    }

    function _closeBorrow(BorrowRecord storage borrow, BorrowState state_) private {
        for (uint256 i = 0; i < borrow.deposit.tokens.length; i++)
            usedDepositAmounts[borrow.participants.depositor][borrow.deposit.chain][borrow.deposit.tokens[i]] -= borrow.deposit.amounts[i];

        borrow.state = state_;
        borrow.participants.closer = msg.sender;
    }
}
