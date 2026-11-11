// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {OnshareAccount} from "../src/OnshareAccount.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {MockERC20, MockFeed} from "../test/mocks/Mocks.sol";
import {MockV3Router} from "../test/mocks/MockV3Router.sol";

/// @notice A complete local stack for trying the CLI and the dashboard on anvil:
///         mock USDG/NVDA/TSLA, mock Chainlink feeds, a mock Uniswap router behind the real
///         UniswapV3Adapter, and an OnshareAccount with NVDA deliberately over max_alloc.
///
///   anvil &
///   AGENT=<agent address> forge script script/LocalStack.s.sol --rpc-url http://127.0.0.1:8545 \
///     --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// Writes the addresses to local-stack.json (or $STACK_OUT).
contract LocalStack is Script {
    function run() external {
        address agent = vm.envAddress("AGENT");
        string memory out = vm.envOr("STACK_OUT", string("local-stack.json"));

        vm.startBroadcast();
        address owner = msg.sender;
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        MockERC20 nvda = new MockERC20("NVIDIA Stock Token", "NVDA", 18);
        MockERC20 tsla = new MockERC20("Tesla Stock Token", "TSLA", 18);
        MockFeed nvdaFeed = new MockFeed(8, 200e8);
        MockFeed tslaFeed = new MockFeed(8, 400e8);
        MockV3Router router = new MockV3Router();
        router.setFeed(address(nvda), nvdaFeed);
        router.setFeed(address(tsla), tslaFeed);
        router.setSlip(30);
        UniswapV3Adapter adapter = new UniswapV3Adapter(address(router), owner);
        adapter.setDirectRoute(address(usdg), address(nvda), 500);
        adapter.setDirectRoute(address(usdg), address(tsla), 3000);

        OnshareAccount acct = new OnshareAccount(owner, address(usdg), address(0));
        acct.setAsset(address(nvda), address(nvdaFeed), true);
        acct.setAsset(address(tsla), address(tslaFeed), true);
        acct.setAdapter(address(adapter), true);
        acct.setAgent(agent, uint64(block.timestamp + 1 days));
        usdg.mint(address(acct), 10_000e6);
        nvda.mint(address(acct), 30e18); // $6,000 of $16,000 = 37.5%, above the 25% cap
        vm.stopBroadcast();

        string memory j = "stack";
        vm.serializeAddress(j, "owner", owner);
        vm.serializeAddress(j, "agent", agent);
        vm.serializeAddress(j, "account", address(acct));
        vm.serializeAddress(j, "adapter", address(adapter));
        vm.serializeAddress(j, "usdg", address(usdg));
        vm.serializeAddress(j, "nvda", address(nvda));
        vm.serializeAddress(j, "tsla", address(tsla));
        vm.serializeAddress(j, "nvdaFeed", address(nvdaFeed));
        string memory json = vm.serializeAddress(j, "tslaFeed", address(tslaFeed));
        vm.writeJson(json, out);
        console.log("account", address(acct));
        console.log("adapter", address(adapter));
    }
}
