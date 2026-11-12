// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OnshareAccount} from "../src/OnshareAccount.sol";
import {PonsCurveAdapter} from "../src/adapters/PonsCurveAdapter.sol";
import {PonsCurveFeed} from "../src/feeds/PonsCurveFeed.sol";
import {IPonsCurve} from "../src/interfaces/IPons.sol";

/// @notice Deploys the Pons curve adapter and price feed for one launch token, and optionally
///         lists the token on an existing OnshareAccount owned by the broadcaster.
///
/// Defaults are Robinhood Chain mainnet (4663) and $ONSHARE. Override any of them with env:
///   PONS_TOKEN      launch token          (default $ONSHARE 0xe2b14f1a...2f0f)
///   PONS_CURVE      its bonding curve     (default 0x6bb433C0...095c)
///   QUOTE_TOKEN     account quote token   (default USDG)
///   WETH            wrapped ETH           (default WETH9 from Uniswap sdk-core)
///   ETH_USD_FEED    ETH / USD feed        (default 0x78F3556b...d3A9)
///   UNISWAP_ROUTER  SwapRouter02          (default 0xCaf681a6...5cb2)
///   WETH_FEE        v3 fee tier of the USDG/WETH pool (default 500)
///   ACCOUNT         OnshareAccount to set up; the broadcaster must be its owner
///   SLIPPAGE_BPS    new maxSlippageBps for ACCOUNT (other policy fields are kept)
///
/// Example (signs with a keystore account, never a raw private key):
///   ACCOUNT=0xcc21... SLIPPAGE_BPS=300 \
///   forge script script/DeployPons.s.sol --rpc-url robinhood --broadcast --account deployer
contract DeployPons is Script {
    address constant ONSHARE = 0xe2b14F1A82FD525C66780DaAfCcf0EE88cF52F0F;
    address constant ONSHARE_CURVE = 0x6bb433C0ffAD10e852410E52FCd52B5d913C095c;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH9 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;

    function run() external returns (PonsCurveAdapter adapter, PonsCurveFeed feed) {
        address token = vm.envOr("PONS_TOKEN", ONSHARE);
        address curve = vm.envOr("PONS_CURVE", ONSHARE_CURVE);
        address quote = vm.envOr("QUOTE_TOKEN", USDG);
        address weth = vm.envOr("WETH", WETH9);
        address ethUsd = vm.envOr("ETH_USD_FEED", ETH_USD);
        address router = vm.envOr("UNISWAP_ROUTER", ROUTER);
        uint24 wethFee = uint24(vm.envOr("WETH_FEE", uint256(500)));
        address account = vm.envOr("ACCOUNT", address(0));
        uint256 slippage = vm.envOr("SLIPPAGE_BPS", uint256(0));

        IPonsCurve c = IPonsCurve(curve);
        require(!c.graduated() && !c.readyToGraduate(), "curve is closed: use a Uniswap v4 route instead");
        uint256 curveCost = c.feeBps() + c.creatorTaxBps();

        vm.startBroadcast();
        adapter = new PonsCurveAdapter(router, weth, quote, token, curve, msg.sender);
        adapter.setRoutes(abi.encodePacked(quote, wethFee, weth), abi.encodePacked(weth, wethFee, quote));
        feed = new PonsCurveFeed(curve, ethUsd);

        if (account != address(0)) {
            OnshareAccount acct = OnshareAccount(payable(account));
            acct.setAsset(token, address(feed), true);
            acct.setAdapter(address(adapter), true);
            if (slippage != 0) {
                (uint16 maxAlloc, uint16 daily, uint16 drawdown,, uint32 feedAge) = acct.policy();
                acct.setPolicy(
                    OnshareAccount.Policy({
                        maxAllocBps: maxAlloc,
                        dailyLimitBps: daily,
                        drawdownBps: drawdown,
                        maxSlippageBps: uint16(slippage),
                        maxFeedAge: feedAge
                    })
                );
            }
        }
        vm.stopBroadcast();

        (, int256 px,,,) = feed.latestRoundData();
        console.log("adapter      ", address(adapter));
        console.log("feed         ", address(feed));
        console.log("token price  ", uint256(px), "(USD, 18 decimals)");
        console.log("curve fee+tax", curveCost, "bps");
        if (account != address(0)) {
            (,,, uint16 s,) = OnshareAccount(payable(account)).policy();
            console.log("account slip ", s, "bps");
            if (s <= curveCost) {
                console.log("WARNING: maxSlippageBps must be above the curve fee+tax or every buy reverts");
            }
        }
    }
}
