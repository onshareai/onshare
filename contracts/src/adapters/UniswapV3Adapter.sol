// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, ISwapAdapter} from "../interfaces/IExternal.sol";

/// @notice Uniswap SwapRouter02 (IV3SwapRouter) subset.
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniswapV3Adapter
/// @notice Swaps through Uniswap v3 (SwapRouter02) along routes set by the adapter owner.
///
///         Uniswap addresses on Robinhood Chain (chain 4663), from the Uniswap sdk-core package:
///           SwapRouter02     0xCaf681a66D020601342297493863E78C959E5cb2
///           UniswapV3Factory 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
///           QuoterV2         0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7
///
/// @dev    The adapter never holds funds between calls: it pulls exactly `amountIn` from the
///         caller, swaps with the caller as recipient, and clears its router approval. Routes are
///         configuration only. A bad route cannot cost an OnshareAccount more than its oracle
///         slippage bound, because the account checks what it actually received.
contract UniswapV3Adapter is ISwapAdapter {
    IV3SwapRouter public immutable router;
    address public owner;
    address public pendingOwner;

    /// @dev keccak256(tokenIn, tokenOut) => encoded v3 path (token, fee, token, fee, token ...)
    mapping(bytes32 => bytes) private _routes;

    event RouteSet(address indexed tokenIn, address indexed tokenOut, bytes path);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Swapped(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error NoRoute(address tokenIn, address tokenOut);
    error BadPath();
    error TokenCallFailed(address token);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address router_, address owner_) {
        if (router_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        router = IV3SwapRouter(router_);
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------ config

    /// @notice Set the route for `tokenIn` -> `tokenOut`. `path` is a Uniswap v3 encoded path that
    ///         starts with `tokenIn` and ends with `tokenOut`. Pass an empty path to remove it.
    function setRoute(address tokenIn, address tokenOut, bytes calldata path) external onlyOwner {
        if (path.length != 0) {
            if (path.length < 43 || (path.length - 20) % 23 != 0) revert BadPath();
            if (address(bytes20(path[:20])) != tokenIn) revert BadPath();
            if (address(bytes20(path[path.length - 20:])) != tokenOut) revert BadPath();
        }
        _routes[_key(tokenIn, tokenOut)] = path;
        emit RouteSet(tokenIn, tokenOut, path);
    }

    /// @notice Convenience: direct single-pool route in both directions.
    function setDirectRoute(address tokenA, address tokenB, uint24 fee) external onlyOwner {
        bytes memory ab = abi.encodePacked(tokenA, fee, tokenB);
        bytes memory ba = abi.encodePacked(tokenB, fee, tokenA);
        _routes[_key(tokenA, tokenB)] = ab;
        _routes[_key(tokenB, tokenA)] = ba;
        emit RouteSet(tokenA, tokenB, ab);
        emit RouteSet(tokenB, tokenA, ba);
    }

    function routeOf(address tokenIn, address tokenOut) external view returns (bytes memory) {
        return _routes[_key(tokenIn, tokenOut)];
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

    // ------------------------------------------------------------------ swap

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        bytes memory path = _routes[_key(tokenIn, tokenOut)];
        if (path.length == 0) revert NoRoute(tokenIn, tokenOut);

        _call(tokenIn, abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), amountIn)));
        _call(tokenIn, abi.encodeCall(IERC20.approve, (address(router), amountIn)));
        amountOut = router.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: path, recipient: recipient, amountIn: amountIn, amountOutMinimum: minAmountOut
            })
        );
        _call(tokenIn, abi.encodeCall(IERC20.approve, (address(router), 0)));
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    // ------------------------------------------------------------------ internal

    function _key(address a, address b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    function _call(address token, bytes memory data) internal {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenCallFailed(token);
    }
}
