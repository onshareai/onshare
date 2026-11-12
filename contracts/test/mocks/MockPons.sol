// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./Mocks.sol";

/// @notice WETH with real ETH backing. Tests must fund it with vm.deal when a router mock
///         mints WETH out of thin air.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 a) external {
        balanceOf[msg.sender] -= a;
        totalSupply -= a;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "eth send");
    }
}

/// @notice Constant-product Pons-style curve with virtual reserves, native ETH quote, fee and
///         creator tax on both sides, a sellable cap with refund, and graduation flags.
contract MockPonsCurve {
    uint256 private constant BPS = 10_000;

    MockERC20 public immutable launchToken;
    uint256 public quoteReserve;
    uint256 public tokenReserve;
    uint256 public sellableTokens;
    uint256 public feeBps;
    uint256 public creatorTaxBps;
    bool public readyToGraduate;
    bool public graduated;
    bool public nativeQuote = true;
    bool public refundToRecipient; // test hook: send refunds to the recipient instead

    event CurveBuy(
        address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax
    );
    event CurveSell(
        address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax
    );
    event CurveBuyRefunded(address indexed buyer, uint256 refund);

    constructor(MockERC20 t, uint256 qr, uint256 tr, uint256 sellable, uint256 fee, uint256 tax) {
        launchToken = t;
        quoteReserve = qr;
        tokenReserve = tr;
        sellableTokens = sellable;
        feeBps = fee;
        creatorTaxBps = tax;
        t.mint(address(this), sellable);
    }

    function isNativeQuote() external view returns (bool) {
        return nativeQuote;
    }

    function setNative(bool v) external {
        nativeQuote = v;
    }

    function setFlags(bool ready, bool grad) external {
        readyToGraduate = ready;
        graduated = grad;
    }

    function setSellable(uint256 s) external {
        sellableTokens = s;
    }

    function setRefundToRecipient(bool v) external {
        refundToRecipient = v;
    }

    /// @dev Move the price as another trader would (no tokens move; reserves only).
    function pump(uint256 ethIn) external {
        uint256 out = ethIn * tokenReserve / (quoteReserve + ethIn);
        quoteReserve += ethIn;
        tokenReserve -= out;
    }

    function getReserves() external view returns (uint256, uint256) {
        return (quoteReserve, tokenReserve);
    }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 out) {
        require(!graduated && !readyToGraduate, "CurveClosed");
        require(msg.value == quoteIn, "value");
        uint256 fee = quoteIn * feeBps / BPS;
        uint256 tax = quoteIn * creatorTaxBps / BPS;
        uint256 net = quoteIn - fee - tax;
        out = net * tokenReserve / (quoteReserve + net);
        uint256 refund;
        if (out > sellableTokens) {
            out = sellableTokens;
            uint256 netUsed = out * quoteReserve / (tokenReserve - out) + 1;
            uint256 gross = netUsed * BPS / (BPS - feeBps - creatorTaxBps) + 1;
            if (gross > quoteIn) gross = quoteIn;
            refund = quoteIn - gross;
            net = netUsed;
        }
        require(out >= minTokensOut, "slippage");
        quoteReserve += net;
        tokenReserve -= out;
        sellableTokens -= out;
        launchToken.transfer(recipient, out);
        if (refund > 0) {
            (bool ok,) = (refundToRecipient ? recipient : msg.sender).call{value: refund}("");
            require(ok, "refund");
            emit CurveBuyRefunded(msg.sender, refund);
        }
        emit CurveBuy(msg.sender, recipient, quoteIn, out, fee, tax);
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut) {
        require(!graduated && !readyToGraduate, "CurveClosed");
        launchToken.transferFrom(msg.sender, address(this), tokensIn);
        uint256 gross = tokensIn * quoteReserve / (tokenReserve + tokensIn);
        uint256 fee = gross * feeBps / BPS;
        uint256 tax = gross * creatorTaxBps / BPS;
        quoteOut = gross - fee - tax;
        require(quoteOut >= minQuoteOut, "slippage");
        quoteReserve -= gross;
        tokenReserve += tokensIn;
        sellableTokens += tokensIn;
        (bool ok,) = recipient.call{value: quoteOut}("");
        require(ok, "eth send");
        emit CurveSell(msg.sender, recipient, tokensIn, quoteOut, fee, tax);
    }

    receive() external payable {}
}
