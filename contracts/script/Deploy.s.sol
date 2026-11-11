// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OnshareAccount} from "../src/OnshareAccount.sol";
import {OnshareAccountFactory} from "../src/OnshareAccountFactory.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";

/// @notice Deploys the factory and an account for the broadcaster, then lists assets.
///
/// Required env:
///   QUOTE_TOKEN       quote token address (e.g. USDG on the target network)
/// Optional env:
///   QUOTE_FEED        Chainlink feed for the quote token (omit to value it at 1 USD)
///   ASSET_TOKENS      comma-separated Stock Token addresses
///   ASSET_FEEDS       comma-separated Chainlink USD feeds, same order as ASSET_TOKENS
///   ADAPTER           an existing swap adapter to allowlist
///   UNISWAP_ROUTER    deploy a new UniswapV3Adapter on this SwapRouter02 instead
///   ROUTE_FEES        comma-separated v3 fee tiers (e.g. 500,3000), one per asset, for
///                     direct QUOTE_TOKEN <-> asset routes on the new adapter
///   AGENT             agent session key address
///   AGENT_TTL         session key lifetime in seconds (default 7 days)
///
/// Example:
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --account deployer
contract Deploy is Script {
    function run() external returns (OnshareAccountFactory factory, OnshareAccount account) {
        address quote = vm.envAddress("QUOTE_TOKEN");
        address quoteFeed = vm.envOr("QUOTE_FEED", address(0));
        address[] memory tokens = vm.envOr("ASSET_TOKENS", ",", new address[](0));
        address[] memory feeds = vm.envOr("ASSET_FEEDS", ",", new address[](0));
        require(tokens.length == feeds.length, "ASSET_TOKENS and ASSET_FEEDS length mismatch");
        address adapter = vm.envOr("ADAPTER", address(0));
        address uniRouter = vm.envOr("UNISWAP_ROUTER", address(0));
        uint256[] memory fees = vm.envOr("ROUTE_FEES", ",", new uint256[](0));
        address agent = vm.envOr("AGENT", address(0));
        uint256 ttl = vm.envOr("AGENT_TTL", uint256(7 days));

        vm.startBroadcast();
        factory = new OnshareAccountFactory(quote, quoteFeed);
        account = factory.createAccount(bytes32("main"));
        for (uint256 i; i < tokens.length; ++i) {
            account.setAsset(tokens[i], feeds[i], true);
        }
        if (adapter == address(0) && uniRouter != address(0)) {
            require(fees.length == tokens.length, "ROUTE_FEES must have one fee per asset");
            UniswapV3Adapter uni = new UniswapV3Adapter(uniRouter, msg.sender);
            for (uint256 i; i < tokens.length; ++i) {
                uni.setDirectRoute(quote, tokens[i], uint24(fees[i]));
            }
            adapter = address(uni);
        }
        if (adapter != address(0)) account.setAdapter(adapter, true);
        if (agent != address(0)) account.setAgent(agent, uint64(block.timestamp + ttl));
        vm.stopBroadcast();

        console.log("factory ", address(factory));
        console.log("account ", address(account));
        console.log("owner   ", account.owner());
        console.log("assets  ", account.assetCount());
        console.log("adapter ", adapter);
    }
}
