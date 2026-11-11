// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IV3SwapRouter} from "../../src/adapters/UniswapV3Adapter.sol";
import {MockERC20, MockFeed} from "./Mocks.sol";

/// @notice Fake SwapRouter02: reads the first and last token of the path, pulls `amountIn`
///         from the caller and mints the output at feed prices minus `slipBps` per hop.
contract MockV3Router is IV3SwapRouter {
    mapping(address => MockFeed) public feedOf;
    uint256 public slipBps;
    uint256 public lastHops;

    function setFeed(address t, MockFeed f) external {
        feedOf[t] = f;
    }

    function setSlip(uint256 b) external {
        slipBps = b;
    }

    function _px(address t) internal view returns (uint256) {
        MockFeed f = feedOf[t];
        return address(f) == address(0) ? 1e8 : uint256(f.answer());
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 out) {
        address tin = address(bytes20(p.path[:20]));
        address tout = address(bytes20(p.path[p.path.length - 20:]));
        uint256 hops = (p.path.length - 20) / 23;
        lastHops = hops;
        MockERC20(tin).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * _px(tin) * (10 ** MockERC20(tout).decimals()) / _px(tout) / (10 ** MockERC20(tin).decimals());
        for (uint256 i; i < hops; ++i) {
            out = out * (10_000 - slipBps) / 10_000;
        }
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(tout).mint(p.recipient, out);
    }
}
