// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, AggregatorV3Interface, ISwapAdapter} from "../../src/interfaces/IExternal.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract MockFeed is AggregatorV3Interface {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Pays out at oracle price minus `slipBps`. Modes let tests simulate bad venues.
contract MockAdapter is ISwapAdapter {
    enum Mode {
        Honest,
        PayLess, // ignores minAmountOut and pays half
        Reenter, // tries to call agentSwap again
        PullMore // tries to pull more than approved
    }

    mapping(address => MockFeed) public feedOf; // token => feed (quote uses 1.0 if unset)
    uint256 public slipBps;
    Mode public mode;

    function setFeed(address token, MockFeed f) external {
        feedOf[token] = f;
    }

    function setSlip(uint256 b) external {
        slipBps = b;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function _px(address t) internal view returns (uint256) {
        MockFeed f = feedOf[t];
        return address(f) == address(0) ? 1e8 : uint256(f.answer());
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256, address recipient)
        external
        returns (uint256 out)
    {
        if (mode == Mode.Reenter) {
            (bool ok, bytes memory ret) = msg.sender
                .call(
                    abi.encodeWithSignature(
                        "agentSwap(address,address,address,uint256,uint256)", address(this), tokenIn, tokenOut, 1, 0
                    )
                );
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        uint256 pull = mode == Mode.PullMore ? amountIn + 1 : amountIn;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), pull);
        uint8 di = MockERC20(tokenIn).decimals();
        uint8 dout = MockERC20(tokenOut).decimals();
        out = amountIn * _px(tokenIn) * (10 ** dout) / _px(tokenOut) / (10 ** di);
        out = out * (10_000 - slipBps) / 10_000;
        if (mode == Mode.PayLess) out = out / 2;
        MockERC20(tokenOut).mint(recipient, out);
    }
}
