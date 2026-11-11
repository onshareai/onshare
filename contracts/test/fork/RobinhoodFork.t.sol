// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {OnshareAccount} from "../../src/OnshareAccount.sol";
import {UniswapV3Adapter} from "../../src/adapters/UniswapV3Adapter.sol";
import {IERC20, AggregatorV3Interface} from "../../src/interfaces/IExternal.sol";

interface IUniswapV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function liquidity() external view returns (uint128);
}

interface IQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

/// @notice Runs the account and the Uniswap v3 adapter against a fork of Robinhood Chain mainnet:
///         real USDG, real Stock Tokens, real Chainlink feeds and real Uniswap pools. No real
///         funds are used; balances exist only inside the local fork.
///
///   ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*" -vv
///
/// Without ROBINHOOD_RPC_URL every test here is skipped.
contract RobinhoodForkTest is Test {
    // Robinhood Chain mainnet (4663)
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // Paxos docs
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // Uniswap sdk-core
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

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
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    // ---------------------------------------------------------------- sanity

    function test_Fork_ContractsExist() public onlyFork {
        assertEq(block.chainid, 4663, "not Robinhood Chain mainnet");
        address[10] memory all = [USDG, ROUTER, FACTORY, QUOTER, NVDA, NVDA_FEED, TSLA, TSLA_FEED, AAPL, AAPL_FEED];
        for (uint256 i; i < all.length; ++i) {
            assertGt(all[i].code.length, 0, "no code at address");
        }
        assertEq(IERC20(USDG).decimals(), 6);
    }

    function test_Fork_FeedsReadable() public onlyFork {
        address[3] memory feeds = [NVDA_FEED, TSLA_FEED, AAPL_FEED];
        for (uint256 i; i < 3; ++i) {
            (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feeds[i]).latestRoundData();
            assertGt(answer, 0);
            console.log("feed", feeds[i]);
            console.log("  price (8 dp)", uint256(answer));
            console.log("  age (s)     ", block.timestamp - updatedAt);
        }
    }

    // ---------------------------------------------------------------- trades

    function test_Fork_NVDA() public onlyFork {
        _trade(NVDA, NVDA_FEED, "NVDA");
    }

    function test_Fork_TSLA() public onlyFork {
        _trade(TSLA, TSLA_FEED, "TSLA");
    }

    function test_Fork_AAPL() public onlyFork {
        _trade(AAPL, AAPL_FEED, "AAPL");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev External so a failed `deal` (unusual token storage) can be caught.
    function fund(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }

    function _bestPool(address token) internal view returns (uint24 bestFee, uint128 bestLiq) {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        for (uint256 i; i < 4; ++i) {
            address pool = IUniswapV3Factory(FACTORY).getPool(USDG, token, fees[i]);
            if (pool == address(0)) continue;
            uint128 liq = IUniswapV3Pool(pool).liquidity();
            if (liq > bestLiq) (bestFee, bestLiq) = (fees[i], liq);
        }
    }

    // per-test state, kept in storage to stay within the stack limit
    OnshareAccount acct;
    UniswapV3Adapter adapter;
    address token;
    uint24 fee;
    uint256 px;
    uint256 tokenDec;

    function _trade(address token_, address feed, string memory sym) internal {
        token = token_;
        uint128 liq;
        (fee, liq) = _bestPool(token);
        if (liq == 0) {
            console.log(sym, ": no Uniswap v3 USDG pool with liquidity; this pair trades on v4 only");
            vm.skip(true);
        }
        console.log(sym, ": using v3 fee tier", fee);
        _deploy(feed);
        (, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
        px = uint256(answer);
        tokenDec = IERC20(token).decimals();
        if (_buy(100e6)) _sellHalf();
    }

    function _deploy(address feed) internal {
        adapter = new UniswapV3Adapter(ROUTER, owner);
        acct = new OnshareAccount(owner, USDG, address(0));
        vm.startPrank(owner);
        adapter.setDirectRoute(USDG, token, fee);
        acct.setAsset(token, feed, true);
        acct.setAdapter(address(adapter), true);
        acct.setAgent(agent, uint64(block.timestamp + 1 days));
        // stock feeds pause on weekends and holidays; allow up to 7 days for a fork run
        acct.setPolicy(OnshareAccount.Policy(2500, 1000, 1000, 100, 7 days));
        vm.stopPrank();
        try this.fund(USDG, address(acct), 10_000e6) {}
        catch {
            console.log("could not fund USDG on the fork (storage layout); skipping");
            vm.skip(true);
        }
    }

    /// @return ok true if the buy went through (pool within 1% of the oracle)
    function _buy(uint256 amountIn) internal returns (bool ok) {
        uint256 expected = amountIn * 1e8 * (10 ** tokenDec) / px / 1e6;
        uint256 minOut = expected * 9_900 / 10_000 + 1;
        (uint256 quoted,,,) = IQuoterV2(QUOTER).quoteExactInput(abi.encodePacked(USDG, fee, token), amountIn);
        console.log("  oracle expects", expected);
        console.log("  pool quotes   ", quoted);
        console.log("  policy minimum", minOut);
        vm.prank(agent);
        if (quoted >= minOut) {
            uint256 got = acct.agentSwap(address(adapter), USDG, token, amountIn, minOut);
            assertGe(got, minOut);
            assertEq(IERC20(token).balanceOf(address(acct)), got);
            assertEq(IERC20(USDG).allowance(address(acct), address(adapter)), 0);
            assertEq(IERC20(USDG).balanceOf(address(adapter)), 0);
            console.log("  BUY OK, received", got);
            return true;
        }
        // the pool is more than 1% away from Chainlink: the policy must refuse the trade
        vm.expectRevert();
        acct.agentSwap(address(adapter), USDG, token, amountIn, minOut);
        console.log("  BUY REJECTED as expected: pool price is more than 1% from the oracle");
    }

    function _sellHalf() internal {
        uint256 sellIn = IERC20(token).balanceOf(address(acct)) / 2;
        uint256 expected = sellIn * px * 1e6 / 1e8 / (10 ** tokenDec);
        uint256 minOut = expected * 9_900 / 10_000 + 1;
        (uint256 quoted,,,) = IQuoterV2(QUOTER).quoteExactInput(abi.encodePacked(token, fee, USDG), sellIn);
        if (quoted < minOut) {
            console.log("  sell skipped: pool price is more than 1% from the oracle");
            return;
        }
        uint256 before = IERC20(USDG).balanceOf(address(acct));
        vm.prank(agent);
        acct.agentSwap(address(adapter), token, USDG, sellIn, minOut);
        assertGe(IERC20(USDG).balanceOf(address(acct)) - before, minOut);
        console.log("  SELL OK");
    }
}
