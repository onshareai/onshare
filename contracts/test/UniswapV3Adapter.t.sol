// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OnshareAccount} from "../src/OnshareAccount.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {MockERC20, MockFeed} from "./mocks/Mocks.sol";
import {MockV3Router} from "./mocks/MockV3Router.sol";

contract UniswapV3AdapterTest is Test {
    UniswapV3Adapter adapter;
    MockV3Router router;
    MockERC20 usdg;
    MockERC20 nvda;
    MockERC20 weth;
    MockFeed nvdaFeed;
    MockFeed wethFeed;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address user = makeAddr("user");

    function setUp() public {
        vm.warp(1_760_000_000);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        nvda = new MockERC20("NVDA", "NVDA", 18);
        weth = new MockERC20("WETH", "WETH", 18);
        nvdaFeed = new MockFeed(8, 200e8);
        wethFeed = new MockFeed(8, 3_000e8);
        router = new MockV3Router();
        router.setFeed(address(nvda), nvdaFeed);
        router.setFeed(address(weth), wethFeed);
        router.setSlip(30);
        adapter = new UniswapV3Adapter(address(router), owner);
        vm.prank(owner);
        adapter.setDirectRoute(address(usdg), address(nvda), 500);
    }

    // ------------------------------------------------------------- config

    function test_DirectRouteBothWays() public view {
        assertEq(
            adapter.routeOf(address(usdg), address(nvda)), abi.encodePacked(address(usdg), uint24(500), address(nvda))
        );
        assertEq(
            adapter.routeOf(address(nvda), address(usdg)), abi.encodePacked(address(nvda), uint24(500), address(usdg))
        );
    }

    function test_SetMultiHopRoute() public {
        bytes memory path = abi.encodePacked(address(usdg), uint24(500), address(weth), uint24(3000), address(nvda));
        vm.prank(owner);
        adapter.setRoute(address(usdg), address(nvda), path);
        assertEq(adapter.routeOf(address(usdg), address(nvda)), path);
    }

    function test_RevertWhen_PathMalformed() public {
        vm.startPrank(owner);
        vm.expectRevert(UniswapV3Adapter.BadPath.selector);
        adapter.setRoute(address(usdg), address(nvda), abi.encodePacked(address(usdg), address(nvda)));
        vm.expectRevert(UniswapV3Adapter.BadPath.selector);
        adapter.setRoute(address(usdg), address(nvda), abi.encodePacked(address(weth), uint24(500), address(nvda)));
        vm.expectRevert(UniswapV3Adapter.BadPath.selector);
        adapter.setRoute(address(usdg), address(nvda), abi.encodePacked(address(usdg), uint24(500), address(weth)));
        vm.stopPrank();
    }

    function test_RemoveRoute() public {
        vm.prank(owner);
        adapter.setRoute(address(usdg), address(nvda), "");
        usdg.mint(user, 100e6);
        vm.startPrank(user);
        usdg.approve(address(adapter), 100e6);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3Adapter.NoRoute.selector, address(usdg), address(nvda)));
        adapter.swap(address(usdg), address(nvda), 100e6, 0, user);
        vm.stopPrank();
    }

    function test_RevertWhen_NotOwner() public {
        vm.startPrank(user);
        vm.expectRevert(UniswapV3Adapter.NotOwner.selector);
        adapter.setDirectRoute(address(usdg), address(weth), 500);
        vm.expectRevert(UniswapV3Adapter.NotOwner.selector);
        adapter.setRoute(address(usdg), address(nvda), "");
        vm.expectRevert(UniswapV3Adapter.NotOwner.selector);
        adapter.transferOwnership(user);
        vm.stopPrank();
    }

    function test_TwoStepOwnership() public {
        vm.prank(owner);
        adapter.transferOwnership(user);
        vm.prank(agent);
        vm.expectRevert(UniswapV3Adapter.NotPendingOwner.selector);
        adapter.acceptOwnership();
        vm.prank(user);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), user);
    }

    // ------------------------------------------------------------- swap

    function test_SwapPullsExactAmountAndHoldsNothing() public {
        usdg.mint(user, 1_000e6);
        vm.startPrank(user);
        usdg.approve(address(adapter), 1_000e6);
        uint256 out = adapter.swap(address(usdg), address(nvda), 400e6, 1.9e18, user);
        vm.stopPrank();
        assertEq(out, 1.994e18); // $400 / $200 minus 0.3%
        assertEq(nvda.balanceOf(user), out);
        assertEq(usdg.balanceOf(user), 600e6);
        assertEq(usdg.balanceOf(address(adapter)), 0);
        assertEq(nvda.balanceOf(address(adapter)), 0);
        assertEq(usdg.allowance(address(adapter), address(router)), 0);
    }

    function test_RevertWhen_RouterCannotMeetMinimum() public {
        usdg.mint(user, 100e6);
        vm.startPrank(user);
        usdg.approve(address(adapter), 100e6);
        vm.expectRevert("Too little received");
        adapter.swap(address(usdg), address(nvda), 100e6, 0.5e18, user);
        vm.stopPrank();
    }

    function test_RevertWhen_RecipientZero() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        adapter.swap(address(usdg), address(nvda), 1, 0, address(0));
    }

    function test_RevertWhen_ConstructorZero() public {
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        new UniswapV3Adapter(address(0), owner);
        vm.expectRevert(UniswapV3Adapter.ZeroAddress.selector);
        new UniswapV3Adapter(address(router), address(0));
    }

    // ------------------------------------------------------------- with the account

    function _account() internal returns (OnshareAccount acct) {
        acct = new OnshareAccount(owner, address(usdg), address(0));
        vm.startPrank(owner);
        acct.setAsset(address(nvda), address(nvdaFeed), true);
        acct.setAdapter(address(adapter), true);
        acct.setAgent(agent, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        usdg.mint(address(acct), 10_000e6);
    }

    function test_AccountBuysAndSellsThroughAdapter() public {
        OnshareAccount acct = _account();
        vm.prank(agent);
        uint256 got = acct.agentSwap(address(adapter), address(usdg), address(nvda), 500e6, 2.475e18);
        assertEq(nvda.balanceOf(address(acct)), got);
        vm.prank(agent);
        acct.agentSwap(address(adapter), address(nvda), address(usdg), got / 2, (got / 2) * 200 * 99 / 100 / 1e12);
        assertEq(usdg.allowance(address(acct), address(adapter)), 0);
        assertEq(usdg.balanceOf(address(adapter)), 0);
    }

    function test_AccountMultiHopRoute() public {
        bytes memory path = abi.encodePacked(address(usdg), uint24(500), address(weth), uint24(3000), address(nvda));
        vm.prank(owner);
        adapter.setRoute(address(usdg), address(nvda), path);
        OnshareAccount acct = _account();
        vm.prank(agent);
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 500e6, 2.475e18);
        assertEq(router.lastHops(), 2);
    }

    function test_BadRouteCannotBeatTheOracleBound() public {
        // owner of the adapter misconfigures a route through a very lossy pool
        router.setSlip(500);
        OnshareAccount acct = _account();
        vm.prank(agent);
        vm.expectRevert("Too little received");
        acct.agentSwap(address(adapter), address(usdg), address(nvda), 500e6, 2.475e18);
    }
}
