// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {OnshareAccount} from "../../src/OnshareAccount.sol";
import {PonsCurveAdapter} from "../../src/adapters/PonsCurveAdapter.sol";
import {PonsCurveFeed} from "../../src/feeds/PonsCurveFeed.sol";
import {IERC20} from "../../src/interfaces/IExternal.sol";
import {IPonsCurve} from "../../src/interfaces/IPons.sol";

interface IUniswapV3FactoryP {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IUniswapV3PoolP {
    function liquidity() external view returns (uint128);
}

/// @notice The agent buys and sells $ONSHARE on its live Pons curve, inside a local fork of
///         Robinhood Chain mainnet. Real USDG, WETH, Uniswap pools, ETH/USD feed and curve.
///         Balances exist only in the fork; no real funds move.
///
///   ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-path test/fork/PonsFork.t.sol -vv
///
/// Without ROBINHOOD_RPC_URL every test here is skipped.
contract PonsForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant ONSHARE = 0xe2b14F1A82FD525C66780DaAfCcf0EE88cF52F0F;
    address constant CURVE = 0x6bb433C0ffAD10e852410E52FCd52B5d913C095c;

    bool forked;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        forked = true;
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function _deepestWethFee() internal view returns (uint24 best) {
        uint24[3] memory fees = [uint24(500), 3000, 10000];
        uint128 most;
        for (uint256 i; i < 3; ++i) {
            address pool = IUniswapV3FactoryP(FACTORY).getPool(USDG, WETH, fees[i]);
            if (pool == address(0)) continue;
            uint128 l = IUniswapV3PoolP(pool).liquidity();
            if (l > most) (most, best) = (l, fees[i]);
        }
        require(best != 0, "no USDG/WETH v3 pool");
    }

    function test_Fork_AgentBuysAndSellsOnshare() public onlyFork {
        IPonsCurve c = IPonsCurve(CURVE);
        if (c.graduated() || c.readyToGraduate()) {
            console.log("curve closed: skip");
            vm.skip(true);
        }
        uint24 fee = _deepestWethFee();
        uint256 curveCost = c.feeBps() + c.creatorTaxBps();
        console.log("USDG/WETH fee tier", fee);
        console.log("curve fee+tax bps ", curveCost);

        PonsCurveAdapter adapter = new PonsCurveAdapter(ROUTER, WETH, USDG, ONSHARE, CURVE, owner);
        vm.prank(owner);
        adapter.setRoutes(abi.encodePacked(USDG, fee, WETH), abi.encodePacked(WETH, fee, USDG));
        PonsCurveFeed feed = new PonsCurveFeed(CURVE, ETH_USD);
        (, int256 px,,,) = feed.latestRoundData();
        console.log("ONSHARE price (USD, 1e18)", uint256(px));

        OnshareAccount acct = new OnshareAccount(owner, USDG, address(0));
        uint16 slip = uint16(curveCost + 150); // fee+tax plus 1.5% for pool fee and price impact
        vm.startPrank(owner);
        acct.setAsset(ONSHARE, address(feed), true);
        acct.setAdapter(address(adapter), true);
        acct.setAgent(agent, uint64(block.timestamp + 1 days));
        acct.setPolicy(
            OnshareAccount.Policy({
                maxAllocBps: 2500, dailyLimitBps: 1000, drawdownBps: 1000, maxSlippageBps: slip, maxFeedAge: 72 hours
            })
        );
        vm.stopPrank();
        deal(USDG, address(acct), 1_000e6);

        // $10 buy, minimum = the account's own oracle bound
        uint256 usdIn = 10e6;
        uint256 minOut = uint256(10e18) * 1e18 / uint256(px) * (10_000 - slip) / 10_000;
        vm.prank(agent);
        uint256 got = acct.agentSwap(address(adapter), USDG, ONSHARE, usdIn, minOut);
        console.log("bought ONSHARE (1e18)", got);
        assertGt(got, 0);
        assertEq(IERC20(ONSHARE).balanceOf(address(acct)), got);
        assertEq(address(adapter).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDG).allowance(address(acct), address(adapter)), 0);

        // sell half back
        uint256 half = got / 2;
        (, px,,,) = feed.latestRoundData();
        uint256 minUsd = half * uint256(px) / 1e18 / 1e12 * (10_000 - slip) / 10_000;
        vm.prank(agent);
        uint256 usdOut = acct.agentSwap(address(adapter), ONSHARE, USDG, half, minUsd);
        console.log("sold half for USDG (1e6)", usdOut);
        assertGt(usdOut, 0);
        assertEq(IERC20(ONSHARE).balanceOf(address(acct)), got - half);
        assertEq(address(adapter).balance, 0);
        assertEq(IERC20(ONSHARE).allowance(address(adapter), CURVE), 0);
    }
}
