// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Pons V2 bonding curve (one contract per launched token), subset used by Onshare.
/// @dev    Event signatures match the logs emitted by live curves on Robinhood Chain:
///         CurveBuy(address,address,uint256,uint256,uint256,uint256)  0xec36bf57...
///         CurveSell(address,address,uint256,uint256,uint256,uint256) 0x8113d738...
///         CurveCompleted(address,uint256,uint256)                    0xf8d37a90...
///         For a native-ETH curve, `buy` takes `quoteIn` as msg.value. Near graduation a buy
///         can be partially filled and the unspent ETH is refunded to the caller.
///         `sell` pulls `tokensIn` with transferFrom and pays ETH to `recipient`.
interface IPonsCurve {
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function sellableTokens() external view returns (uint256);
    function readyToGraduate() external view returns (bool);
    function graduated() external view returns (bool);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function isNativeQuote() external view returns (bool);

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
