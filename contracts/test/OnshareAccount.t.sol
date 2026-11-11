// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OnshareAccount} from "../src/OnshareAccount.sol";
import {OnshareAccountFactory} from "../src/OnshareAccountFactory.sol";
import {MockERC20, MockFeed, MockAdapter} from "./mocks/Mocks.sol";

contract Base is Test {
    OnshareAccount acct;
    MockERC20 usdg;
    MockERC20 nvda;
    MockERC20 tsla;
    MockFeed nvdaFeed;
    MockFeed tslaFeed;
    MockAdapter adapter;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockERC20("NVIDIA Stock Token", "NVDA", 18);
        tsla = new MockERC20("Tesla Stock Token", "TSLA", 18);
        nvdaFeed = new MockFeed(8, 200e8);
        tslaFeed = new MockFeed(8, 400e8);
        adapter = new MockAdapter();
        adapter.setFeed(address(nvda), nvdaFeed);
        adapter.setFeed(address(tsla), tslaFeed);
        adapter.setSlip(50); // 0.5%

        acct = new OnshareAccount(owner, address(usdg), address(0));
        vm.startPrank(owner);
        acct.setAsset(address(nvda), address(nvdaFeed), true);
        acct.setAsset(address(tsla), address(tslaFeed), true);
        acct.setAdapter(address(adapter), true);
        acct.setAgent(agent, uint64(block.timestamp + 7 days));
        vm.stopPrank();
        usdg.mint(address(acct), 10_000e6);
    }

    // expected output at oracle price, minus 1% (the policy's max slippage)
    function _minOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        uint256 pin =
            tokenIn == address(usdg) ? 1e8 : uint256((tokenIn == address(nvda) ? nvdaFeed : tslaFeed).answer());
        uint256 pout =
            tokenOut == address(usdg) ? 1e8 : uint256((tokenOut == address(nvda) ? nvdaFeed : tslaFeed).answer());
        uint256 din = MockERC20(tokenIn).decimals();
        uint256 dout = MockERC20(tokenOut).decimals();
        uint256 expected = amountIn * pin * (10 ** dout) / pout / (10 ** din);
        return expected * 9_900 / 10_000 + 1; // +1 to absorb rounding
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        uint256 m = _minOut(tokenIn, tokenOut, amountIn);
        vm.prank(agent);
        return acct.agentSwap(address(adapter), tokenIn, tokenOut, amountIn, m);
    }

    function _refreshFeeds() internal {
        nvdaFeed.set(nvdaFeed.answer());
        tslaFeed.set(tslaFeed.answer());
    }
}

contract OnshareAccountTest is Base {
    // ---------------------------------------------------------------- happy path

    function test_BuyWithinLimits() public {
        uint256 out = _swap(address(usdg), address(nvda), 500e6);
        assertEq(out, 2.4875e18); // $500 / $200 minus 0.5% venue slippage
        assertEq(nvda.balanceOf(address(acct)), out);
        assertApproxEqAbs(acct.portfolioValue(), 9_997.5e18, 1e12);
        assertEq(acct.dayVolume(), 500e18);
    }

    function test_DefaultPolicy() public view {
        (uint16 a, uint16 d, uint16 dd, uint16 s, uint32 age) = acct.policy();
        assertEq(a, 2500);
        assertEq(d, 1000);
        assertEq(dd, 1000);
        assertEq(s, 100);
        assertEq(age, 72 hours);
    }

    function test_AllowanceClearedAfterSwap() public {
        _swap(address(usdg), address(nvda), 500e6);
        assertEq(usdg.allowance(address(acct), address(adapter)), 0);
    }

    // ---------------------------------------------------------------- who may trade

    function test_RevertWhen_NotAgent() public {
        vm.prank(stranger);
        vm.expectRevert(OnshareAccount.NotAgent.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, 0);
    }

    function test_RevertWhen_OwnerTriesAgentSwap() public {
        vm.prank(owner);
        vm.expectRevert(OnshareAccount.NotAgent.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, 0);
    }

    function test_RevertWhen_AgentExpired() public {
        vm.warp(block.timestamp + 7 days);
        _refreshFeeds();
        uint256 m = _minOut(address(usdg), address(nvda), 100e6);
        vm.prank(agent);
        vm.expectRevert(OnshareAccount.AgentExpired.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, m);
    }

    function test_PauseIsKillSwitch() public {
        vm.prank(owner);
        acct.pause();
        assertEq(acct.agent(), address(0));
        assertFalse(acct.agentActive());
        vm.prank(agent);
        vm.expectRevert(OnshareAccount.IsPaused.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, 0);

        // unpausing alone does not restore the old session key
        vm.prank(owner);
        acct.unpause();
        vm.prank(agent);
        vm.expectRevert(OnshareAccount.NotAgent.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, 0);
    }

    function test_RevertWhen_StrangerConfigures() public {
        vm.startPrank(agent);
        vm.expectRevert(OnshareAccount.NotOwner.selector);
        acct.setAgent(agent, type(uint64).max);
        vm.expectRevert(OnshareAccount.NotOwner.selector);
        acct.withdraw(address(usdg), agent, 1);
        vm.expectRevert(OnshareAccount.NotOwner.selector);
        acct.setAdapter(agent, true);
        vm.expectRevert(OnshareAccount.NotOwner.selector);
        acct.execute(address(usdg), 0, abi.encodeWithSignature("transfer(address,uint256)", agent, 1));
        vm.expectRevert(OnshareAccount.NotOwner.selector);
        acct.unpause();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- allowlist

    function test_RevertWhen_AdapterNotAllowed() public {
        MockAdapter evil = new MockAdapter();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(OnshareAccount.AdapterNotAllowed.selector, address(evil)));
        acct.agentSwap(address(evil), address(usdg), address(nvda), 100e6, 0);
    }

    function test_RevertWhen_TokenNotListed() public {
        MockERC20 rug = new MockERC20("Rug", "RUG", 18);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(OnshareAccount.AssetNotListed.selector, address(rug)));
        acct.agentSwap(address(adapter), address(usdg), address(rug), 100e6, 0);
    }

    function test_RevertWhen_DelistedToken() public {
        vm.prank(owner);
        acct.setAsset(address(tsla), address(0), false);
        assertEq(acct.assetCount(), 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(OnshareAccount.AssetNotListed.selector, address(tsla)));
        acct.agentSwap(address(adapter), address(usdg), address(tsla), 100e6, 0);
    }

    function test_RevertWhen_SameTokenOrZero() public {
        vm.startPrank(agent);
        vm.expectRevert(OnshareAccount.SameToken.selector);
        acct.agentSwap(address(adapter), address(usdg), address(usdg), 100e6, 0);
        vm.expectRevert(OnshareAccount.ZeroAmount.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 0, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- max_alloc

    function test_RevertWhen_MaxAllocExceeded() public {
        nvda.mint(address(acct), 14e18); // $2,800 already in NVDA, portfolio $12,800
        uint256 m = _minOut(address(usdg), address(nvda), 600e6);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.MaxAllocExceeded.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 600e6, m);
    }

    function test_SellingOverAllocatedStockIsAllowed() public {
        nvda.mint(address(acct), 40e18); // $8,000 NVDA = 44% of $18,000
        _swap(address(nvda), address(usdg), 4e18); // sell $800
        assertEq(nvda.balanceOf(address(acct)), 36e18);
    }

    function test_RevertWhen_RotatingIntoOverAllocatedStock() public {
        nvda.mint(address(acct), 10e18); // $2,000
        tsla.mint(address(acct), 6e18); // $2,400 TSLA, total $14,400; TSLA at 16.7%
        // daily limit is $1,440; buying $1,400 of TSLA with NVDA puts TSLA at ~26.3%
        uint256 m = _minOut(address(nvda), address(tsla), 7e18);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.MaxAllocExceeded.selector);
        acct.agentSwap(address(adapter), address(nvda), address(tsla), 7e18, m);
    }

    // ---------------------------------------------------------------- daily_limit

    function test_DailyLimitAccumulatesAndResets() public {
        _swap(address(usdg), address(nvda), 500e6);
        _swap(address(usdg), address(tsla), 400e6);
        assertEq(acct.dailyRemaining(), 100e18);

        uint256 m = _minOut(address(usdg), address(tsla), 200e6);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.DailyLimitExceeded.selector);
        acct.agentSwap(address(adapter), address(usdg), address(tsla), 200e6, m);

        vm.warp(block.timestamp + 1 days);
        _refreshFeeds();
        _swap(address(usdg), address(tsla), 200e6);
        assertEq(acct.dayVolume(), 200e18);
    }

    function test_RevertWhen_SingleTradeOverDailyLimit() public {
        uint256 m = _minOut(address(usdg), address(nvda), 1_001e6);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.DailyLimitExceeded.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 1_001e6, m);
    }

    // ---------------------------------------------------------------- oracle

    function test_RevertWhen_FeedStale() public {
        nvda.mint(address(acct), 1e18);
        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.StalePrice.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, 0);
    }

    function test_FeedWithinMaxAgeIsAccepted() public {
        vm.warp(block.timestamp + 71 hours); // e.g. a weekend
        _swap(address(usdg), address(nvda), 100e6);
    }

    function test_RevertWhen_FeedNegativeOrZero() public {
        nvdaFeed.set(0);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.InvalidPrice.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, 1);
    }

    function test_RevertWhen_FeedInFuture() public {
        nvdaFeed.setUpdatedAt(block.timestamp + 1);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.StalePrice.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, 1);
    }

    // ---------------------------------------------------------------- slippage + venue

    function test_RevertWhen_MinOutBelowOracleBound() public {
        uint256 expected = 0.5e18; // $100 / $200
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.SlippageTooHigh.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, expected * 98 / 100);
    }

    function test_RevertWhen_VenuePaysLessThanMin() public {
        adapter.setMode(MockAdapter.Mode.PayLess);
        uint256 m = _minOut(address(usdg), address(nvda), 100e6);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.InsufficientOutput.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, m);
    }

    function test_RevertWhen_VenueSlipsMoreThanPolicy() public {
        adapter.setSlip(150); // 1.5% worse than oracle, policy allows 1%
        uint256 m = _minOut(address(usdg), address(nvda), 100e6);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.InsufficientOutput.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, m);
    }

    function test_RevertWhen_VenuePullsMoreThanApproved() public {
        adapter.setMode(MockAdapter.Mode.PullMore);
        uint256 m = _minOut(address(usdg), address(nvda), 100e6);
        vm.prank(agent);
        vm.expectRevert(); // allowance underflow in the token
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, m);
    }

    function test_RevertWhen_Reentrancy() public {
        adapter.setMode(MockAdapter.Mode.Reenter);
        uint256 m = _minOut(address(usdg), address(nvda), 100e6);
        vm.prank(agent);
        vm.expectRevert(OnshareAccount.Reentrancy.selector);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 100e6, m);
    }

    // ---------------------------------------------------------------- drawdown

    function test_DrawdownSwitchesToSellOnly() public {
        nvda.mint(address(acct), 20e18); // $4,000 NVDA + $10,000 USDG
        _swap(address(usdg), address(tsla), 100e6); // sets the peak at ~$14,000
        uint256 peak = acct.peakValue();
        assertApproxEqAbs(peak, 14_000e18, 1e18);

        nvdaFeed.set(100e8); // NVDA halves: -$2,000, about -14%
        uint256 m = _minOut(address(usdg), address(tsla), 100e6);
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.DrawdownSellOnly.selector);
        acct.agentSwap(address(adapter), address(usdg), address(tsla), 100e6, m);

        // de-risking into the quote token is still allowed
        _swap(address(nvda), address(usdg), 2e18);
    }

    function test_SmallDipDoesNotTriggerDrawdown() public {
        nvda.mint(address(acct), 20e18);
        _swap(address(usdg), address(tsla), 100e6);
        nvdaFeed.set(180e8); // -$400, about -2.9%
        _swap(address(usdg), address(tsla), 100e6);
    }

    // ---------------------------------------------------------------- owner

    function test_OwnerWithdrawRescalesPeakAndBudget() public {
        _swap(address(usdg), address(nvda), 500e6);
        uint256 peak = acct.peakValue();
        uint256 base = acct.dayBaseValue();
        uint256 before = acct.portfolioValue();
        vm.prank(owner);
        acct.withdraw(address(usdg), owner, 4_750e6); // about half the portfolio
        uint256 afterValue = acct.portfolioValue();
        assertEq(usdg.balanceOf(owner), 4_750e6);
        assertEq(acct.peakValue(), peak * afterValue / before);
        assertEq(acct.dayBaseValue(), base * afterValue / before);
        assertLt(acct.peakValue(), peak * 55 / 100);
        // the agent is not put into sell-only mode by the owner's withdrawal,
        // and its remaining daily budget shrank with the portfolio
        _swap(address(usdg), address(tsla), 20e6);
        assertLt(acct.dailyRemaining(), 5e18);
    }

    function test_OwnerCanWithdrawEvenWhenFeedsAreStale() public {
        nvda.mint(address(acct), 1e18);
        vm.warp(block.timestamp + 30 days);
        vm.startPrank(owner);
        acct.withdraw(address(nvda), owner, 1e18);
        acct.withdraw(address(usdg), owner, 10_000e6);
        vm.stopPrank();
        assertEq(nvda.balanceOf(owner), 1e18);
        assertEq(acct.peakValue(), 0);
    }

    function test_OwnerWithdrawEth() public {
        vm.deal(address(acct), 1 ether);
        vm.prank(owner);
        acct.withdraw(address(0), owner, 1 ether);
        assertEq(owner.balance, 1 ether);
    }

    function test_OwnerExecute() public {
        vm.prank(owner);
        acct.execute(address(usdg), 0, abi.encodeWithSignature("transfer(address,uint256)", owner, 1e6));
        assertEq(usdg.balanceOf(owner), 1e6);
    }

    function test_SetPolicyBounds() public {
        vm.startPrank(owner);
        acct.setPolicy(OnshareAccount.Policy(3000, 500, 1500, 50, 1 days));
        (uint16 a,,,,) = acct.policy();
        assertEq(a, 3000);
        vm.expectRevert(OnshareAccount.BadPolicy.selector);
        acct.setPolicy(OnshareAccount.Policy(10_001, 500, 1500, 50, 1 days));
        vm.expectRevert(OnshareAccount.BadPolicy.selector);
        acct.setPolicy(OnshareAccount.Policy(3000, 0, 1500, 50, 1 days));
        vm.expectRevert(OnshareAccount.BadPolicy.selector);
        acct.setPolicy(OnshareAccount.Policy(3000, 500, 9500, 50, 1 days));
        vm.expectRevert(OnshareAccount.BadPolicy.selector);
        acct.setPolicy(OnshareAccount.Policy(3000, 500, 1500, 2000, 1 days));
        vm.expectRevert(OnshareAccount.BadPolicy.selector);
        acct.setPolicy(OnshareAccount.Policy(3000, 500, 1500, 50, 8 days));
        vm.stopPrank();
    }

    function test_TwoStepOwnership() public {
        address next = makeAddr("next");
        vm.prank(owner);
        acct.transferOwnership(next);
        assertEq(acct.owner(), owner);
        vm.prank(stranger);
        vm.expectRevert(OnshareAccount.NotPendingOwner.selector);
        acct.acceptOwnership();
        vm.prank(next);
        acct.acceptOwnership();
        assertEq(acct.owner(), next);
    }

    function test_AssetCap() public {
        vm.startPrank(owner);
        for (uint256 i = 2; i < acct.MAX_ASSETS(); ++i) {
            MockERC20 t = new MockERC20("T", "T", 18);
            acct.setAsset(address(t), address(nvdaFeed), true);
        }
        MockERC20 extra = new MockERC20("X", "X", 18);
        vm.expectRevert(OnshareAccount.TooManyAssets.selector);
        acct.setAsset(address(extra), address(nvdaFeed), true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- factory

    function test_FactoryPredictsAddress() public {
        OnshareAccountFactory f = new OnshareAccountFactory(address(usdg), address(0));
        address predicted = f.accountAddress(owner, bytes32("main"));
        vm.prank(owner);
        OnshareAccount a = f.createAccount(bytes32("main"));
        assertEq(address(a), predicted);
        assertEq(a.owner(), owner);
        assertEq(a.quoteToken(), address(usdg));
    }

    // ---------------------------------------------------------------- fuzz

    /// After any successful agent buy, the bought stock is within max_alloc and the day's
    /// volume is within the daily limit.
    function testFuzz_BuyNeverBreaksPolicy(uint256 usdIn, uint256 heldNvda, bool useTsla) public {
        usdIn = bound(usdIn, 1e6, 5_000e6);
        heldNvda = bound(heldNvda, 0, 30e18);
        nvda.mint(address(acct), heldNvda);
        address out = useTsla ? address(tsla) : address(nvda);
        uint256 m = _minOut(address(usdg), out, usdIn);
        vm.prank(agent);
        try acct.agentSwap(address(adapter), address(usdg), out, usdIn, m) {
            assertLe(acct.allocationBps(out), 2500);
            assertLe(acct.dayVolume(), acct.dayBaseValue() * 1000 / 10_000);
        } catch {}
    }

    /// The oracle bound always holds: whatever the venue does, the account never receives
    /// less than (oracle value - 1%) for what it sold.
    function testFuzz_SlippageBound(uint256 usdIn, uint256 venueSlip) public {
        usdIn = bound(usdIn, 1e6, 1_000e6);
        venueSlip = bound(venueSlip, 0, 500);
        adapter.setSlip(venueSlip);
        uint256 before = acct.portfolioValue();
        uint256 m = _minOut(address(usdg), address(nvda), usdIn);
        vm.prank(agent);
        try acct.agentSwap(address(adapter), address(usdg), address(nvda), usdIn, m) {
            uint256 tradeUsd = usdIn * 1e12;
            assertGe(acct.portfolioValue() + tradeUsd / 100 + 1e12, before);
        } catch {
            assertGe(venueSlip, 100);
        }
    }
}
