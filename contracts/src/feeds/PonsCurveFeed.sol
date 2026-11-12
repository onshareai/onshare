// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../interfaces/IExternal.sol";
import {IPonsCurve} from "../interfaces/IPons.sol";

/// @title PonsCurveFeed
/// @notice USD price of a Pons launch token, in the Chainlink AggregatorV3 shape so that an
///         OnshareAccount can list the token with `setAsset(token, feed, true)`.
///
///         price = curve marginal price in ETH (quoteReserve / tokenReserve) x ETH/USD feed
///
///         Reported with 18 decimals: launch tokens trade far below one cent, and 8 decimals
///         would round the price to a few significant digits.
///
/// @dev    `updatedAt` is the ETH/USD feed's timestamp, so the account's feed-age rule still
///         applies. After the curve graduates its reserves stop moving, so the feed reports
///         `updatedAt = 0` and the account treats the price as stale. The owner then points the
///         asset at a new feed (or delists it) with `setAsset`.
///
///         The curve price is a spot price: it can be moved inside one block by anyone willing to
///         trade on the curve. The account's max_alloc and daily_limit cap how much of a portfolio
///         is exposed to that.
contract PonsCurveFeed is AggregatorV3Interface {
    IPonsCurve public immutable curve;
    AggregatorV3Interface public immutable ethUsd;
    uint8 private immutable _ethDecimals;

    uint8 public constant decimals = 18;
    string public constant description = "Pons curve token / USD";

    error ZeroAddress();
    error NotNativeCurve();
    error BadEthPrice();

    constructor(address curve_, address ethUsd_) {
        if (curve_ == address(0) || ethUsd_ == address(0)) revert ZeroAddress();
        if (!IPonsCurve(curve_).isNativeQuote()) revert NotNativeCurve();
        curve = IPonsCurve(curve_);
        ethUsd = AggregatorV3Interface(ethUsd_);
        _ethDecimals = AggregatorV3Interface(ethUsd_).decimals();
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (uint80 rid, int256 eth,, uint256 ethUpdatedAt,) = ethUsd.latestRoundData();
        if (eth <= 0) revert BadEthPrice();
        (uint256 qr, uint256 tr) = curve.getReserves();
        // ETH per token (both 18 decimals) x USD per ETH, scaled to 18 decimals
        answer = tr == 0 ? int256(0) : int256(qr * uint256(eth) * (10 ** (18 - _ethDecimals)) / tr);
        updatedAt = curve.graduated() ? 0 : ethUpdatedAt;
        return (rid, answer, updatedAt, updatedAt, rid);
    }
}
