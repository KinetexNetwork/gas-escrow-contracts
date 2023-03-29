// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.16;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract TrackerRegistry is Ownable, Multicall {
    event TrackerSet(address token, address tracker);
    event TrackerUnset(address token);
    event DecimalsSet(address token, uint8 decimals);
    event DecimalsUnset(address token);

    uint8 public constant COST_DECIMALS = 18;

    mapping(address => address) public trackers; // token, tracker
    mapping(address => uint16) private _decimals; // token, decimals + set flag

    function setTracker(address token_, address tracker_) external onlyOwner {
        require(tracker_ != address(0), "TR: zero tracker");
        _setTrackerValue(token_, tracker_);
        emit TrackerSet(token_, tracker_);
    }

    function unsetTracker(address token_) external onlyOwner {
        _setTrackerValue(token_, address(0));
        emit TrackerUnset(token_);
    }

    function setDecimals(address token_, uint8 decimals_) external onlyOwner {
        _setDecimalsValue(token_, (uint16(1) << 15) | decimals_);
        emit DecimalsSet(token_, decimals_);
    }

    function unsetDecimals(address token_) external onlyOwner {
        _setDecimalsValue(token_, 0);
        emit DecimalsUnset(token_);
    }

    function hasTracker(address token_) public view returns (bool) {
        return trackers[token_] != address(0);
    }

    function hasDecimals(address token_) public view returns (bool) {
        return _decimals[token_] != 0;
    }

    function decimals(address token_) public view returns (uint8) {
        return uint8(_decimals[token_]);
    }

    function resolvedDecimals(address token_) public view returns (uint8) {
        return hasDecimals(token_) ? decimals(token_) : _metaDecimals(token_);
    }

    function latestPrice(address token_) public view returns (uint256, uint8) {
        address tracker = trackers[token_];
        require(tracker != address(0), "TR: tracker not set");
        (,int256 result,,,) = AggregatorV3Interface(tracker).latestRoundData();
        require(result >= 0, "TR: price result < 0");
        return (uint256(result), AggregatorV3Interface(tracker).decimals());
    }

    function latestCost(address token_, uint256 amount_) external view returns (uint256 cost) {
        if (amount_ == 0) return 0;
        (uint256 price, uint8 priceDecimals) = latestPrice(token_);

        cost = amount_ * price;
        uint256 d = resolvedDecimals(token_) + priceDecimals;
        if (d < COST_DECIMALS) cost *= (10 ** (COST_DECIMALS - d));
        else if (d > COST_DECIMALS) cost /= (10 ** (d - COST_DECIMALS));
    }

    function _setTrackerValue(address token_, address tracker_) private {
        require(trackers[token_] != tracker_, "TR: same tracker");
        trackers[token_] = tracker_;
    }

    function _setDecimalsValue(address token_, uint16 decimals_) private {
        require(_decimals[token_] != decimals_, "TR: same decimals");
        _decimals[token_] = decimals_;
    }

    function _metaDecimals(address token_) private view returns (uint8) {
        try IERC20Metadata(token_).decimals() returns (uint8 d) { return d; }
        catch { revert("TR: no token decimals meta"); } // TODO: fix no revert message
    }
}
