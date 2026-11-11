// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OnshareAccount} from "../src/OnshareAccount.sol";
import {MockERC20, MockFeed, MockAdapter} from "../test/mocks/Mocks.sol";

/// @notice Local end-to-end demo on anvil with mock tokens, feeds and a mock swap venue.
///         Shows one trade the policy accepts and one it rejects.
///
///   anvil &
///   forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// The key above is anvil's public test account #0. Never use it on a real network.
contract Demo is Script {
    function run() external {
        uint256 ownerKey =
            vm.envOr("OWNER_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        uint256 agentKey =
            vm.envOr("AGENT_KEY", uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d));
        address owner = vm.addr(ownerKey);
        address agent = vm.addr(agentKey);

        vm.startBroadcast(ownerKey);
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        MockERC20 nvda = new MockERC20("NVIDIA Stock Token", "NVDA", 18);
        MockFeed feed = new MockFeed(8, 200e8);
        MockAdapter venue = new MockAdapter();
        venue.setFeed(address(nvda), feed);
        venue.setSlip(30);
        OnshareAccount acct = new OnshareAccount(owner, address(usdg), address(0));
        acct.setAsset(address(nvda), address(feed), true);
        acct.setAdapter(address(venue), true);
        acct.setAgent(agent, uint64(block.timestamp + 1 days));
        usdg.mint(address(acct), 10_000e6);
        vm.stopBroadcast();

        // agent buys $500 of NVDA: inside every limit
        vm.startBroadcast(agentKey);
        uint256 out = acct.agentSwap(address(venue), address(usdg), address(nvda), 500e6, 2.475e18);
        vm.stopBroadcast();
        console.log("agent bought NVDA (wei):", out);
        console.log("NVDA allocation (bps):  ", acct.allocationBps(address(nvda)));
        console.log("daily budget left (USD):", acct.dailyRemaining() / 1e18);

        // a $2,000 buy would break daily_limit (10% of $10k), so the policy rejects it
        vm.prank(agent);
        try acct.agentSwap(address(venue), address(usdg), address(nvda), 2_000e6, 9.9e18) {
            console.log("unexpected: oversized trade passed");
        } catch (bytes memory err) {
            require(bytes4(err) == OnshareAccount.DailyLimitExceeded.selector, "wrong revert");
            console.log("oversized trade rejected: DailyLimitExceeded");
        }
    }
}
