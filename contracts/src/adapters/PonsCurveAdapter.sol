// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, ISwapAdapter} from "../interfaces/IExternal.sol";
import {IPonsCurve, IWETH} from "../interfaces/IPons.sol";
import {IV3SwapRouter} from "./UniswapV3Adapter.sol";

/// @title PonsCurveAdapter
/// @notice Lets an OnshareAccount trade one Pons launch token on its bonding curve, using the
///         account's quote token (USDG) on the other side.
///
///         buy:  USDG --Uniswap v3--> WETH --unwrap--> ETH --curve.buy--> token to the account
///         sell: token --curve.sell--> ETH --wrap--> WETH --Uniswap v3--> USDG to the account
///
/// @dev    Same contract shape as UniswapV3Adapter: the account approves exactly `amountIn`,
///         calls `swap`, and measures real balance changes afterwards. The adapter never holds
///         funds between calls and clears every approval it sets.
///
///         Before graduation only. Once the curve is ready to graduate (or has graduated) the
///         adapter reverts, and the token has to move to a Uniswap v4 route.
///
///         A buy that the curve would only partially fill reverts instead of leaving ETH behind.
contract PonsCurveAdapter is ISwapAdapter {
    uint256 private constant BPS = 10_000;

    IV3SwapRouter public immutable router;
    IWETH public immutable weth;
    address public immutable quoteToken; // USDG
    address public immutable token; // the Pons launch token, e.g. $ONSHARE
    IPonsCurve public immutable curve;

    address public owner;
    address public pendingOwner;
    bytes public quoteToWeth; // Uniswap v3 path, starts with quoteToken and ends with WETH
    bytes public wethToQuote; // Uniswap v3 path, starts with WETH and ends with quoteToken

    uint256 private _lock = 1;

    event RoutesSet(bytes quoteToWeth, bytes wethToQuote);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error BadPath();
    error NoRoute();
    error UnsupportedPair(address tokenIn, address tokenOut);
    error NotNativeCurve();
    error CurveClosed();
    error PartialFill(uint256 tokensOut, uint256 sellable);
    error LeftoverEth(uint256 amount);
    error UnexpectedEth(address from);
    error Reentrancy();
    error TokenCallFailed(address token);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address router_, address weth_, address quoteToken_, address token_, address curve_, address owner_) {
        if (
            router_ == address(0) || weth_ == address(0) || quoteToken_ == address(0) || token_ == address(0)
                || curve_ == address(0) || owner_ == address(0)
        ) revert ZeroAddress();
        if (!IPonsCurve(curve_).isNativeQuote()) revert NotNativeCurve();
        router = IV3SwapRouter(router_);
        weth = IWETH(weth_);
        quoteToken = quoteToken_;
        token = token_;
        curve = IPonsCurve(curve_);
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @dev Only the curve (sell proceeds, buy refunds) and WETH (unwrap) may send ETH.
    receive() external payable {
        if (msg.sender != address(curve) && msg.sender != address(weth)) revert UnexpectedEth(msg.sender);
    }

    // ------------------------------------------------------------------ config

    /// @notice Set the Uniswap v3 paths between the quote token and WETH, e.g.
    ///         abi.encodePacked(USDG, uint24(500), WETH) and abi.encodePacked(WETH, uint24(500), USDG).
    function setRoutes(bytes calldata quoteToWeth_, bytes calldata wethToQuote_) external onlyOwner {
        _checkPath(quoteToWeth_, quoteToken, address(weth));
        _checkPath(wethToQuote_, address(weth), quoteToken);
        quoteToWeth = quoteToWeth_;
        wethToQuote = wethToQuote_;
        emit RoutesSet(quoteToWeth_, wethToQuote_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ------------------------------------------------------------------ views

    /// @notice True while the curve accepts trades through this adapter.
    function curveOpen() public view returns (bool) {
        return !curve.graduated() && !curve.readyToGraduate();
    }

    /// @notice Tokens out for `ethIn` on the curve after fee and creator tax (no snipe tax:
    ///         the snipe window only lasts seconds after launch).
    function quoteBuyEth(uint256 ethIn) public view returns (uint256) {
        (uint256 qr, uint256 tr) = curve.getReserves();
        uint256 net = ethIn - ethIn * curve.feeBps() / BPS - ethIn * curve.creatorTaxBps() / BPS;
        return net * tr / (qr + net);
    }

    /// @notice ETH out for selling `tokensIn` on the curve after fee and creator tax.
    function quoteSellEth(uint256 tokensIn) public view returns (uint256) {
        (uint256 qr, uint256 tr) = curve.getReserves();
        uint256 gross = tokensIn * qr / (tr + tokensIn);
        return gross - gross * curve.feeBps() / BPS - gross * curve.creatorTaxBps() / BPS;
    }

    // ------------------------------------------------------------------ swap

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (!curveOpen()) revert CurveClosed();
        uint256 ethBefore = address(this).balance;

        if (tokenIn == quoteToken && tokenOut == token) {
            amountOut = _buy(amountIn, minAmountOut, recipient);
        } else if (tokenIn == token && tokenOut == quoteToken) {
            amountOut = _sell(amountIn, minAmountOut, recipient);
        } else {
            revert UnsupportedPair(tokenIn, tokenOut);
        }

        if (address(this).balance > ethBefore) revert LeftoverEth(address(this).balance - ethBefore);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _buy(uint256 amountIn, uint256 minAmountOut, address recipient) internal returns (uint256 tokensOut) {
        bytes memory path = quoteToWeth;
        if (path.length == 0) revert NoRoute();

        // USDG -> WETH, received here
        _call(quoteToken, abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), amountIn)));
        _call(quoteToken, abi.encodeCall(IERC20.approve, (address(router), amountIn)));
        uint256 wethOut = router.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: 0
            })
        );
        _call(quoteToken, abi.encodeCall(IERC20.approve, (address(router), 0)));

        // a buy the curve can only partly fill would refund ETH: refuse it up front
        uint256 expected = quoteBuyEth(wethOut);
        uint256 sellable = curve.sellableTokens();
        if (expected > sellable) revert PartialFill(expected, sellable);

        // WETH -> ETH -> token, sent straight to the account. The account checks the final
        // amount against its own oracle bound; minAmountOut is passed through as well.
        weth.withdraw(wethOut);
        tokensOut = curve.buy{value: wethOut}(wethOut, minAmountOut, recipient);
    }

    function _sell(uint256 amountIn, uint256 minAmountOut, address recipient) internal returns (uint256 quoteOut) {
        bytes memory path = wethToQuote;
        if (path.length == 0) revert NoRoute();

        // token -> ETH, received here
        _call(token, abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), amountIn)));
        _call(token, abi.encodeCall(IERC20.approve, (address(curve), amountIn)));
        uint256 ethBefore = address(this).balance;
        curve.sell(amountIn, 0, address(this));
        _call(token, abi.encodeCall(IERC20.approve, (address(curve), 0)));
        uint256 ethOut = address(this).balance - ethBefore;

        // ETH -> WETH -> USDG, sent straight to the account with the caller's minimum
        weth.deposit{value: ethOut}();
        _call(address(weth), abi.encodeCall(IERC20.approve, (address(router), ethOut)));
        quoteOut = router.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: path, recipient: recipient, amountIn: ethOut, amountOutMinimum: minAmountOut
            })
        );
        _call(address(weth), abi.encodeCall(IERC20.approve, (address(router), 0)));
    }

    // ------------------------------------------------------------------ internal

    function _checkPath(bytes calldata path, address first, address last) internal pure {
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert BadPath();
        if (address(bytes20(path[:20])) != first) revert BadPath();
        if (address(bytes20(path[path.length - 20:])) != last) revert BadPath();
    }

    function _call(address t, bytes memory data) internal {
        (bool ok, bytes memory ret) = t.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenCallFailed(t);
    }
}
