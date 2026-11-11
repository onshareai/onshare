// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OnshareAccount} from "../src/OnshareAccount.sol";
import {MockERC20, MockFeed, MockAdapter} from "./mocks/Mocks.sol";

/// @notice Drives the account with random agent trades, price moves and time jumps.
contract Handler is Test {
    OnshareAccount public acct;
    MockERC20 public usdg;
    MockERC20[2] public stocks;
    MockFeed[2] public feeds;
    MockAdapter public adapter;
    address public agent;

    uint256 public successfulSwaps;
    mapping(bytes4 => uint256) public failures;
    uint256 public attempts;

    constructor(
        OnshareAccount a,
        MockERC20 u,
        MockERC20 s0,
        MockERC20 s1,
        MockFeed f0,
        MockFeed f1,
        MockAdapter ad,
        address ag
    ) {
        acct = a;
        usdg = u;
        stocks = [s0, s1];
        feeds = [f0, f1];
        adapter = ad;
        agent = ag;
    }

    function _token(uint256 i) internal view returns (address) {
        i = i % 3;
        return i == 2 ? address(usdg) : address(stocks[i]);
    }

    function _price(address t) internal view returns (uint256) {
        if (t == address(usdg)) return 1e8;
        return uint256((t == address(stocks[0]) ? feeds[0] : feeds[1]).answer());
    }

    function swap(uint256 inSeed, uint256 outSeed, uint256 fraction, uint256 tightness) external {
        // pick a token the account actually holds, and a different one to buy
        address tin = _token(inSeed);
        for (uint256 k; k < 3 && MockERC20(tin).balanceOf(address(acct)) == 0; ++k) {
            tin = _token(inSeed % 3 + k + 1);
        }
        address tout = _token(outSeed);
        if (tout == tin) tout = _token(outSeed % 3 + 1);
        uint256 bal = MockERC20(tin).balanceOf(address(acct));
        if (bal == 0) return;
        uint256 amountIn = bal * bound(fraction, 1, 1_200) / 10_000;
        if (amountIn == 0) return;
        attempts++;
        uint256 expected = amountIn * _price(tin) * (10 ** MockERC20(tout).decimals()) / _price(tout)
            / (10 ** MockERC20(tin).decimals());
        uint256 m = expected * (10_000 - bound(tightness, 0, 150)) / 10_000;
        vm.prank(agent);
        try acct.agentSwap(address(adapter), tin, tout, amountIn, m) {
            successfulSwaps++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            failures[sel]++;
        }
    }

    function movePrice(uint256 which, uint256 pctSeed, bool up) external {
        MockFeed f = feeds[which % 2];
        uint256 pct = bound(pctSeed, 0, 800); // up to 8%
        uint256 p = uint256(f.answer());
        p = up ? p * (10_000 + pct) / 10_000 : p * (10_000 - pct) / 10_000;
        if (p == 0) p = 1;
        f.set(int256(p));
    }

    function passTime(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 30 hours));
        feeds[0].set(feeds[0].answer());
        feeds[1].set(feeds[1].answer());
    }
}

abstract contract InvariantSetup is Test {
    OnshareAccount acct;
    Handler handler;
    MockERC20 usdg;
    MockERC20 nvda;
    MockERC20 tsla;
    MockAdapter adapter;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockERC20("NVDA", "NVDA", 18);
        tsla = new MockERC20("TSLA", "TSLA", 18);
        MockFeed f0 = new MockFeed(8, 200e8);
        MockFeed f1 = new MockFeed(8, 400e8);
        adapter = new MockAdapter();
        adapter.setFeed(address(nvda), f0);
        adapter.setFeed(address(tsla), f1);
        adapter.setSlip(30);
        acct = new OnshareAccount(owner, address(usdg), address(0));
        vm.startPrank(owner);
        acct.setAsset(address(nvda), address(f0), true);
        acct.setAsset(address(tsla), address(f1), true);
        acct.setAdapter(address(adapter), true);
        acct.setAgent(agent, type(uint64).max);
        vm.stopPrank();
        usdg.mint(address(acct), 100_000e6);
        handler = new Handler(acct, usdg, nvda, tsla, f0, f1, adapter, agent);
        targetContract(address(handler));
    }
}

contract OnshareInvariantTest is InvariantSetup {
    /// The agent never trades more than the daily limit.
    function invariant_DailyVolumeWithinLimit() public view {
        assertLe(acct.dayVolume(), acct.dayBaseValue() * 1000 / 10_000);
    }

    function afterInvariant() public {
        emit log_named_uint("agent swaps that passed the policy", handler.successfulSwaps());
        emit log_named_uint("agent swaps the policy rejected", handler.attempts() - handler.successfulSwaps());
    }

    /// No approval is ever left open to the swap venue.
    function invariant_NoDanglingAllowance() public view {
        assertEq(usdg.allowance(address(acct), address(adapter)), 0);
        assertEq(nvda.allowance(address(acct), address(adapter)), 0);
        assertEq(tsla.allowance(address(acct), address(adapter)), 0);
    }

    /// The agent can never change who controls the account or its rules.
    function invariant_ControlUnchanged() public view {
        assertEq(acct.owner(), owner);
        assertEq(acct.agent(), agent);
        (uint16 a, uint16 d, uint16 dd, uint16 s, uint32 age) = acct.policy();
        assertEq(a, 2500);
        assertEq(d, 1000);
        assertEq(dd, 1000);
        assertEq(s, 100);
        assertEq(age, 72 hours);
        assertFalse(acct.adapters(address(handler)));
    }
}

/// Sanity check that the handler really exercises the account (not only reverting paths).
contract HandlerCoverageTest is InvariantSetup {
    function test_HandlerTradesAndGetsRejected() public {
        for (uint256 i; i < 200; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i)));
            handler.swap(r, r >> 8, r >> 16, r >> 32);
            if (i % 7 == 0) handler.movePrice(r, r >> 40, (r >> 50) % 2 == 0);
            if (i % 11 == 0) handler.passTime(r >> 60);
        }
        assertGt(handler.successfulSwaps(), 20);
        assertGt(handler.attempts(), handler.successfulSwaps());
    }
}
