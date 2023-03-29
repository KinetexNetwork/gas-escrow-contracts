// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TokenPermitInteractor} from "./lib/TokenInteractor.sol";
import {ProofHelper, Proof} from "./lib/ProofHelper.sol";

import {TrackerRegistry} from "./TrackerRegistry.sol";
import {LiquidatedBorrow} from "./GasProvider.sol";

struct WithdrawRecord {
    address depositor;
    uint256 chain;
    address token;
    uint256 amount;
    uint256 when;
}

contract GasInsurer is TokenPermitInteractor {
    event Deposited(address depositor, uint256 chain, address token, uint256 amount);
    event WithdrawInitiated(bytes32 withdrawHash);
    event Withdrawn(bytes32 withdrawHash);
    event DepositLiquidated(uint256 chain, bytes32 borrowHash);
    event BorrowerApproved(address depositor, address borrower);
    event BorrowerRevoked(address depositor, address borrower);

    address public immutable proofValidator;
    address public immutable providerProoferRegistry;
    address public immutable trackerRegistry;

    mapping(address => mapping(uint256 => mapping(address => uint256))) public depositAmounts; // depositor, chain, token, amount
    mapping(address => mapping(uint256 => mapping(address => uint256))) public withdrawAmounts; // depositor, chain, token, amount
    mapping(address => mapping(address => uint256)) public redistributedAmounts; // depositor, token, amount
    mapping(address => mapping(address => bool)) public borrowers; // depositor, borrower, allowed
    mapping(address => uint256) private _withdrawCounts; // depositor, withdraw count
    mapping(bytes32 => WithdrawRecord) private _withdraws; // withdraw hash, withdraw
    mapping(uint256 => mapping(bytes32 => bool)) public liquidatedBorrows; // chain, borrow hash, liquidated

    constructor(address proofValidator_, address providerProoferRegistry_, address trackerRegistry_) {
        proofValidator = proofValidator_;
        providerProoferRegistry = providerProoferRegistry_;
        trackerRegistry = trackerRegistry_;
    }

    function deposit(uint256 chain_, address token_, uint256 amount_, bool redistribution_) external payable valueTrack {
        require(amount_ > 0, "GI: zero deposit amount");

        if (redistribution_) {
            require(redistributedAmounts[msg.sender][token_] >= amount_, "GI: insufficient redistr amount");
            redistributedAmounts[msg.sender][token_] -= amount_;
        } else _receiveToken(token_, amount_);

        depositAmounts[msg.sender][chain_][token_] += amount_;
        emit Deposited(msg.sender, chain_, token_, amount_);
    }

    function depositCostState(address depositor_, address borrower_, uint256 chain_, address[] calldata tokens_, uint256[] calldata amounts_) external view returns (uint256 cost, uint256[] memory deposits) {
        cost = costState(tokens_, amounts_);

        if (depositor_ != borrower_)
            require(borrowers[depositor_][borrower_], "GI: borrower not whitelisted");

        deposits = new uint256[](tokens_.length);
        for (uint256 i = 0; i < tokens_.length; i++)
            deposits[i] = depositAmounts[depositor_][chain_][tokens_[i]];
    }

    function costState(address[] calldata tokens_, uint256[] calldata amounts_) public view returns (uint256 cost) {
        require(tokens_.length == amounts_.length, "GI: cost state length mismatch");
        for (uint256 i = 0; i < tokens_.length; i++) {
            for (uint256 j = 0; j < i; j++)
                require(tokens_[j] != tokens_[i], "GI: cost state token duplicate");
            cost += TrackerRegistry(trackerRegistry).latestCost(tokens_[i], amounts_[i]);
        }
    }

    function approveBorrower(address borrower_) external payable valueTrack {
        _setBorrowerAllowed(borrower_, true);
        emit BorrowerApproved(msg.sender, borrower_);
    }

    function revokeBorrower(address borrower_) external payable valueTrack {
        _setBorrowerAllowed(borrower_, false);
        emit BorrowerRevoked(msg.sender, borrower_);
    }

    function _setBorrowerAllowed(address borrower_, bool allowed_) private {
        require(borrower_ != msg.sender, "GI: cannot set self allowance");
        require(borrowers[msg.sender][borrower_] != allowed_, "GI: same borrower allowance");
        borrowers[msg.sender][borrower_] = allowed_;
    }

    function initiateWithdraw(uint256 chain_, address token_, uint256 amount_) external payable valueTrack returns (bytes32 withdrawHash) {
        require(amount_ > 0, "GI: zero withdraw amount");
        require(amount_ <= depositAmounts[msg.sender][chain_][token_], "GI: excessive withdraw amount");

        depositAmounts[msg.sender][chain_][token_] -= amount_;
        withdrawAmounts[msg.sender][chain_][token_] += amount_;

        withdrawHash = keccak256(abi.encodePacked(block.chainid, msg.sender, _withdrawCounts[msg.sender]++));
        _withdraws[withdrawHash] = WithdrawRecord({depositor: msg.sender, chain: chain_, token: token_, amount: amount_, when: block.timestamp + 10 minutes});
        emit WithdrawInitiated(withdrawHash);
    }

    function proceedWithdraw(bytes32 withdrawHash_, Proof calldata usedDepositProof_, bytes calldata usedDepositProofSignature_, bool redistribution_) external payable valueTrack {
        WithdrawRecord storage withdraw = _withdraws[withdrawHash_];
        require(withdraw.depositor != address(0), "GI: withdraw does not exist");
        require(block.timestamp >= withdraw.when, "GI: withdraw time not reached");

        ProofHelper.validate(usedDepositProof_, usedDepositProofSignature_, proofValidator, 5 minutes, 15 seconds, withdraw.chain, providerProoferRegistry, keccak256(abi.encodeWithSignature("depositorState(address,uint256,address)", withdraw.depositor, block.chainid, withdraw.token)));
        (uint256 usedDepositAmount, bytes32[] memory liquidatedBorrowHashes) = abi.decode(usedDepositProof_.result, (uint256, bytes32[]));

        for (uint256 i = 0; i < liquidatedBorrowHashes.length; i++)
            require(liquidatedBorrows[withdraw.chain][liquidatedBorrowHashes[i]], "GI: withdraw needs liquidation");

        require(depositAmounts[withdraw.depositor][withdraw.chain][withdraw.token] >= usedDepositAmount, "GI: used deposit not backed");
        require(withdrawAmounts[withdraw.depositor][withdraw.chain][withdraw.token] >= withdraw.amount, "GI: withdraw not backed");
        withdrawAmounts[withdraw.depositor][withdraw.chain][withdraw.token] -= withdraw.amount;

        if (redistribution_) redistributedAmounts[withdraw.depositor][withdraw.token] += withdraw.amount;
        else _sendToken(withdraw.token, withdraw.amount, withdraw.depositor);

        emit Withdrawn(withdrawHash_); // Keeping withdraw info (or `delete _withdraws[withdrawHash_];` here)
    }

    function cancelWithdraw(uint256 chain_, address token_, uint256 amount_) external payable valueTrack {
        require(amount_ > 0, "GI: zero cancel withdraw amount");
        withdrawAmounts[msg.sender][chain_][token_] -= amount_;
        depositAmounts[msg.sender][chain_][token_] += amount_;
    }

    function withdraws(bytes32 withdrawHash_) external view returns (WithdrawRecord memory) {
        return _withdraws[withdrawHash_];
    }

    function liquidate(uint256 chain_, bytes32 borrowHash_, Proof calldata liquidationProof_, bytes calldata liquidationProofSignature_) external payable valueTrack {
        require(!liquidatedBorrows[chain_][borrowHash_], "GI: borrow already liquidated");

        ProofHelper.validate(liquidationProof_, liquidationProofSignature_, proofValidator, 5 minutes, 15 seconds, chain_, providerProoferRegistry, keccak256(abi.encodeWithSignature("liquidatedBorrows(bytes32)", borrowHash_)));
        (LiquidatedBorrow memory borrow) = abi.decode(liquidationProof_.result, (LiquidatedBorrow));
        require(borrow.deposit.chain == block.chainid, "GI: invalid borrow deposit chain");

        for (uint256 i = 0; i < borrow.deposit.tokens.length; i++) {
            (address depositToken, uint256 depositAmount) = (borrow.deposit.tokens[i], borrow.deposit.amounts[i]);
            uint256 amountFromDeposit = Math.min(depositAmount, depositAmounts[borrow.participants.depositor][chain_][depositToken]);
            depositAmounts[borrow.participants.depositor][chain_][depositToken] -= amountFromDeposit;
            withdrawAmounts[borrow.participants.depositor][chain_][depositToken] -= (depositAmount - amountFromDeposit);

            _sendToken(depositToken, borrow.deposit.providerRewards[i], borrow.participants.closer);
            _sendToken(depositToken, borrow.deposit.insurerRewards[i], msg.sender);
            _sendToken(depositToken, depositAmount - borrow.deposit.providerRewards[i] - borrow.deposit.insurerRewards[i], borrow.participants.lender);
        }

        liquidatedBorrows[chain_][borrowHash_] = true;
        emit DepositLiquidated(chain_, borrowHash_);
    }
}
