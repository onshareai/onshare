// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OnshareAccount} from "../src/OnshareAccount.sol";
import {PonsCurveAdapter} from "../src/adapters/PonsCurveAdapter.sol";
import {PonsCurveFeed} from "../src/feeds/PonsCurveFeed.sol";
import {MockERC20, MockFeed} from "./mocks/Mocks.sol";
import {MockV3Router} from "./mocks/MockV3Router.sol";
import {MockWETH, MockPonsCurve} from "./mocks/MockPons.sol";

contract PonsCurveAdapterTest is Test {
    PonsCurveAdapter adapter;
    PonsCurveFeed feed;
    MockPonsCurve curve;
    MockV3Router router;
    MockWETH weth;
    MockERC20 usdg;
    MockERC20 onshare;
    MockFeed ethFeed;
    OnshareAccount acct;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address user = makeAddr("user");

    // curve close to the live $ONSHARE curve: ~1.77 ETH virtual quote reserve, 1B supply
    uint256 constant QR = 1.77e18;
    uint256 constant TR = 1_000_000_000e18;
    uint256 constant SELLABLE = 800_000_000e18;

    function setUp() public {
        vm.warp(1_760_000_000);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        onshare = new MockERC20("Onshare", "ONSHARE", 18);
        weth = new MockWETH();
        ethFeed = new MockFeed(8, 3_000e8);
        router = new MockV3Router();
        router.setFeed(address(weth), ethFeed);
        router.setSlip(5); // 0.05% pool fee per hop
        curve = new MockPonsCurve(onshare, QR, TR, SELLABLE, 100, 100); // 1% fee + 1% creator tax
        vm.deal(address(curve), 100 ether);
        vm.deal(address(weth), 1_000 ether); // backs the WETH the router mock mints

        adapter = new PonsCurveAdapter(
            address(router), address(weth), address(usdg), address(onshare), address(curve), owner
        );
        vm.prank(owner);
        adapter.setRoutes(
            abi.encodePacked(address(usdg), uint24(500), address(weth)),
            abi.encodePacked(address(weth), uint24(500), address(usdg))
        );
        feed = new PonsCurveFeed(address(curve), address(ethFeed));

        acct = new OnshareAccount(owner, address(usdg), address(0));
        vm.startPrank(owner);
        acct.setAsset(address(onshare), address(feed), true);
        acct.setAdapter(address(adapter), true);
        acct.setAgent(agent, uint64(block.timestamp + 1 days));
        acct.setPolicy(
            OnshareAccount.Policy({
                maxAllocBps: 2500, dailyLimitBps: 1000, drawdownBps: 1000, maxSlippageBps: 300, maxFeedAge: 72 hours
            })
        );
        vm.stopPrank();
        usdg.mint(address(acct), 1_000e6);
    }

    // ------------------------------------------------------------- helpers

    function _expectedBuy(uint256 usdIn) internal view returns (uint256) {
        uint256 wethOut = usdIn * 1e12 / 3_000 * 9_995 / 10_000;
        return adapter.quoteBuyEth(wethOut);
    }

    function _agentBuy(uint256 usdIn) internal returns (uint256) {
        uint256 minOut = _expectedBuy(usdIn) * 9_990 / 10_000;
        vm.prank(agent);
        return acct.agentSwap(address(adapter), address(usdg), address(onshare), usdIn, minOut);
    }

    function _assertAdapterEmpty() internal view {
        assertEq(address(adapter).balance, 0, "adapter eth");
        assertEq(weth.balanceOf(address(adapter)), 0, "adapter weth");
        assertEq(usdg.balanceOf(address(adapter)), 0, "adapter usdg");
        assertEq(onshare.balanceOf(address(adapter)), 0, "adapter token");
        assertEq(usdg.allowance(address(acct), address(adapter)), 0, "acct->adapter usdg");
        assertEq(onshare.allowance(address(acct), address(adapter)), 0, "acct->adapter token");
        assertEq(usdg.allowance(address(adapter), address(router)), 0, "adapter->router usdg");
        assertEq(weth.allowance(address(adapter), address(router)), 0, "adapter->router weth");
        assertEq(onshare.allowance(address(adapter), address(curve)), 0, "adapter->curve token");
    }

    // ------------------------------------------------------------- feed

    function test_FeedPriceIsCurveSpotTimesEth() public view {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(feed.decimals(), 18);
        assertEq(uint256(answer), QR * 3_000e8 * 1e10 / TR);
        assertEq(updatedAt, block.timestamp);
        // about $0.0000053, close to the live token
        assertApproxEqRel(uint256(answer), 5.31e-6 * 1e18, 0.01e18);
    }

    function test_FeedFollowsTheCurve() public {
        (, int256 before,,,) = feed.latestRoundData();
        curve.pump(0.5 ether);
        (, int256 afterPump,,,) = feed.latestRoundData();
        assertGt(afterPump, before);
    }

    function test_FeedIsStaleAfterGraduation() public {
        _agentBuy(20e6); // the account holds the token, so its price is needed
        curve.setFlags(true, true);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, 0);
        vm.expectRevert(abi.encodeWithSelector(OnshareAccount.StalePrice.selector, address(feed), 0));
        acct.portfolioValue();
    }

    function test_RevertWhen_FeedOnErc20Curve() public {
        curve.setNative(false);
        vm.expectRevert(PonsCurveFeed.NotNativeCurve.selector);
        new PonsCurveFeed(address(curve), address(ethFeed));
        vm.expectRevert(PonsCurveAdapter.NotNativeCurve.selector);
        new PonsCurveAdapter(address(router), address(weth), address(usdg), address(onshare), address(curve), owner);
    }

    // ------------------------------------------------------------- agent trades through the account

    function test_AgentBuysOnshare() public {
        uint256 got = _agentBuy(20e6);
        assertEq(onshare.balanceOf(address(acct)), got);
        assertGe(got, _expectedBuy(20e6) * 9_990 / 10_000);
        assertEq(usdg.balanceOf(address(acct)), 980e6);
        assertLt(acct.allocationBps(address(onshare)), 250);
        _assertAdapterEmpty();
    }

    function test_AgentBuysThenSellsHalf() public {
        uint256 got = _agentBuy(20e6);
        uint256 half = got / 2;
        uint256 ethOut = adapter.quoteSellEth(half);
        uint256 minUsd = ethOut * 3_000 / 1e12 * 9_990 / 10_000;
        vm.prank(agent);
        uint256 usdOut = acct.agentSwap(address(adapter), address(onshare), address(usdg), half, minUsd);
        assertGe(usdOut, minUsd);
        assertEq(onshare.balanceOf(address(acct)), got - half);
        // round trip on $10 costs fees both ways, roughly 4-5%
        assertApproxEqRel(usdOut, 9.55e6, 0.02e18);
        _assertAdapterEmpty();
    }

    function test_RevertWhen_SlippageAtDefaultOnePercent() public {
        // curve fee + creator tax alone is 2%, so the default 1% oracle bound refuses the trade
        vm.prank(owner);
        acct.setPolicy(
            OnshareAccount.Policy({
                maxAllocBps: 2500, dailyLimitBps: 1000, drawdownBps: 1000, maxSlippageBps: 100, maxFeedAge: 72 hours
            })
        );
        uint256 minOut = _expectedBuy(20e6) * 9_990 / 10_000;
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.SlippageTooHigh.selector);
        acct.agentSwap(address(adapter), address(usdg), address(onshare), 20e6, minOut);
    }

    function test_RevertWhen_AboveMaxAlloc() public {
        vm.prank(owner);
        acct.setPolicy(
            OnshareAccount.Policy({
                maxAllocBps: 100, dailyLimitBps: 1000, drawdownBps: 1000, maxSlippageBps: 300, maxFeedAge: 72 hours
            })
        );
        uint256 minOut = _expectedBuy(20e6) * 9_990 / 10_000;
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.MaxAllocExceeded.selector);
        acct.agentSwap(address(adapter), address(usdg), address(onshare), 20e6, minOut);
    }

    function test_RevertWhen_AboveDailyLimit() public {
        // $1,000 portfolio, 10% daily limit
        vm.prank(agent);
        vm.expectPartialRevert(OnshareAccount.DailyLimitExceeded.selector);
        acct.agentSwap(address(adapter), address(usdg), address(onshare), 101e6, 1);
    }

    function test_RevertWhen_NotAgent() public {
        vm.prank(user);
        vm.expectRevert(OnshareAccount.NotAgent.selector);
        acct.agentSwap(address(adapter), address(usdg), address(onshare), 20e6, 1);
    }

    function test_KillSwitchStopsOnshareTrades() public {
        vm.prank(owner);
        acct.pause();
        vm.prank(agent);
        vm.expectRevert(OnshareAccount.IsPaused.selector);
        acct.agentSwap(address(adapter), address(usdg), address(onshare), 20e6, 1);
    }

    // ------------------------------------------------------------- curve state

    function test_RevertWhen_ReadyToGraduate() public {
        uint256 minOut = _expectedBuy(20e6) * 9_990 / 10_000;
        curve.setFlags(true, false);
        vm.prank(agent);
        vm.expectRevert(PonsCurveAdapter.CurveClosed.selector);
        acct.agentSwap(address(adapter), address(usdg), address(onshare), 20e6, minOut);
    }

    function test_RevertWhen_BuyWouldOnlyPartlyFill() public {
        uint256 minOut = _expectedBuy(20e6) * 9_990 / 10_000;
        curve.setSellable(1_000e18);
        vm.prank(agent);
        vm.expectPartialRevert(PonsCurveAdapter.PartialFill.selector);
        acct.agentSwap(address(adapter), address(usdg), address(onshare), 20e6, minOut);
    }

    // ------------------------------------------------------------- adapter on its own

    function test_RevertWhen_UnsupportedPair() public {
        usdg.mint(user, 10e6);
        vm.startPrank(user);
        usdg.approve(address(adapter), 10e6);
        vm.expectRevert(abi.encodeWithSelector(PonsCurveAdapter.UnsupportedPair.selector, address(usdg), address(weth)));
        adapter.swap(address(usdg), address(weth), 10e6, 0, user);
        vm.stopPrank();
    }

    function test_RevertWhen_NoRoutes() public {
        PonsCurveAdapter fresh = new PonsCurveAdapter(
            address(router), address(weth), address(usdg), address(onshare), address(curve), owner
        );
        usdg.mint(user, 10e6);
        vm.startPrank(user);
        usdg.approve(address(fresh), 10e6);
        vm.expectRevert(PonsCurveAdapter.NoRoute.selector);
        fresh.swap(address(usdg), address(onshare), 10e6, 0, user);
        vm.stopPrank();
    }

    function test_RevertWhen_BadRoutes() public {
        vm.startPrank(owner);
        vm.expectRevert(PonsCurveAdapter.BadPath.selector);
        adapter.setRoutes(
            abi.encodePacked(address(usdg), uint24(500), address(onshare)),
            abi.encodePacked(address(weth), uint24(500), address(usdg))
        );
        vm.expectRevert(PonsCurveAdapter.BadPath.selector);
        adapter.setRoutes(
            abi.encodePacked(address(usdg), uint24(500), address(weth)), abi.encodePacked(address(usdg), address(weth))
        );
        vm.stopPrank();
    }

    function test_RevertWhen_NotOwnerSetsRoutes() public {
        vm.prank(user);
        vm.expectRevert(PonsCurveAdapter.NotOwner.selector);
        adapter.setRoutes("", "");
    }

    function test_OwnershipTwoStep() public {
        vm.prank(owner);
        adapter.transferOwnership(user);
        assertEq(adapter.owner(), owner);
        vm.prank(user);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), user);
    }

    function test_RevertWhen_StrangerSendsEth() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(adapter).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------- fuzz

    function testFuzz_BuyAndSellLeaveNothingBehind(uint256 usdIn, uint256 sellPct) public {
        usdIn = bound(usdIn, 1e6, 100e6);
        sellPct = bound(sellPct, 1, 100);
        vm.prank(owner);
        acct.setPolicy(
            OnshareAccount.Policy({
                maxAllocBps: 5000, dailyLimitBps: 3000, drawdownBps: 1000, maxSlippageBps: 1000, maxFeedAge: 72 hours
            })
        );
        uint256 got = _agentBuy(usdIn);
        assertGt(got, 0);
        _assertAdapterEmpty();

        uint256 amt = got * sellPct / 100;
        if (amt == 0) return;
        uint256 ethOut = adapter.quoteSellEth(amt);
        uint256 minUsd = ethOut * 3_000 / 1e12 * 9_990 / 10_000;
        vm.prank(agent);
        acct.agentSwap(address(adapter), address(onshare), address(usdg), amt, minUsd);
        _assertAdapterEmpty();
        assertEq(onshare.balanceOf(address(acct)), got - amt);
    }
}
