// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

import {SafeERC20, IERC20, IERC20Permit, Address} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SignatureHelper} from "./SignatureHelper.sol";

abstract contract TokenInteractor {
    address constant internal NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bool private _msgValueAcquired;
    uint256 private _msgValue;

    modifier whenNonZero(uint256 amount_) { if (amount_ != 0) _; }

    modifier valueTrack() {
        if (_msgValueAcquired) _;
        else { _acquireMsgValue(); _; _releaseMsgValue(); }
    }

    function multicall(bytes[] calldata data_) external payable valueTrack returns (bytes[] memory results) {
        results = new bytes[](data_.length);
        for (uint256 i = 0; i < data_.length; i++)
            results[i] = Address.functionDelegateCall(address(this), data_[i], "TI: delegate call failed");
    }

    function _receiveToken(address token_, uint256 amount_) internal whenNonZero(amount_) {
        if (token_ == NATIVE_TOKEN) _spendMsgValue(amount_);
        else SafeERC20.safeTransferFrom(IERC20(token_), msg.sender, address(this), amount_);
    }

    function _sendToken(address token_, uint256 amount_, address to_) internal whenNonZero(amount_) {
        if (token_ == NATIVE_TOKEN) Address.sendValue(payable(to_), amount_);
        else SafeERC20.safeTransfer(IERC20(token_), to_, amount_);
    }

    function _resendToken(address token_, uint256 amount_, address to_) internal {
        _receiveToken(token_, amount_);
        _sendToken(token_, amount_, to_);
    }

    function _acquireMsgValue() private {
        (_msgValueAcquired, _msgValue) = (true, msg.value);
    }

    function _releaseMsgValue() private {
        _sendToken(NATIVE_TOKEN, _msgValue, msg.sender); // Return unspent
        (_msgValueAcquired, _msgValue) = (false, 0);
    }

    function _spendMsgValue(uint256 amount_) private {
        require(_msgValue >= amount_, "TI: insufficient msg.value");
        _msgValue -= amount_;
    }
}

interface IDaiPermit {
    function nonces(address holder) external returns (uint256);
    function permit(address holder, address spender, uint256 nonce, uint256 expiry, bool allowed, uint8 v, bytes32 r, bytes32 s) external;
}

abstract contract TokenPermitInteractor is TokenInteractor {
    function permit(address token_, uint256 amount_, uint256 deadline_, bytes calldata signature_) external payable valueTrack {
        (bytes32 r, bytes32 s, uint8 v) = SignatureHelper.read(signature_, 0);
        SafeERC20.safePermit(IERC20Permit(token_), msg.sender, address(this), amount_, deadline_, v, r, s);
    }

    function permitDai(address token_, bool allowed_, uint256 deadline_, bytes calldata signature_) external payable valueTrack {
        uint256 nonce = IDaiPermit(token_).nonces(msg.sender);
        (bytes32 r, bytes32 s, uint8 v) = SignatureHelper.read(signature_, 0);
        IDaiPermit(token_).permit(msg.sender, address(this), nonce, deadline_, allowed_, v, r, s);
        require(IDaiPermit(token_).nonces(msg.sender) == nonce + 1, "TI: permit did not succeed"); // Like SafeERC20.safePermit
    }
}
