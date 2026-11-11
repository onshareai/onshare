// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, AggregatorV3Interface, ISwapAdapter} from "./interfaces/IExternal.sol";

/// @title OnshareAccount
/// @notice A smart account that holds tokenized stocks for one owner and lets an AI agent trade
///         them through a limited, expiring session key. Every agent trade is checked on-chain
///         against the owner's policy before and after it executes:
///
///         - allowlist:   only listed Stock Tokens, the quote token and allowlisted swap adapters
///         - max_alloc:   no single stock may exceed `maxAllocBps` of portfolio value after a buy
///         - daily_limit: agent volume per UTC day is capped at `dailyLimitBps` of portfolio value
///         - drawdown:    below `drawdownBps` from the peak, the agent may only sell into the quote token
///         - slippage:    output must be within `maxSlippageBps` of the Chainlink oracle price
///         - feed age:    prices older than `maxFeedAge` are rejected
///         - kill switch: `pause()` stops the agent and revokes its session key immediately
///
///         The owner keeps full control: deposit, withdraw and change the policy at any time.
///         The agent can never withdraw, change settings or call arbitrary contracts.
/// @dev    v0 is a direct-call smart account (the agent signs normal transactions with its session
///         key). ERC-4337 validation and the lending module are planned for later versions.
contract OnshareAccount {
    // ------------------------------------------------------------------ types

    struct Policy {
        uint16 maxAllocBps; // max share of one stock after a buy, e.g. 2500 = 25%
        uint16 dailyLimitBps; // max agent volume per day, e.g. 1000 = 10%
        uint16 drawdownBps; // drawdown from peak that switches to sell-only, e.g. 1000 = 10%
        uint16 maxSlippageBps; // max deviation from oracle price, e.g. 100 = 1%
        uint32 maxFeedAge; // seconds, e.g. 72 hours (stock feeds pause over weekends)
    }

    struct Asset {
        address feed; // Chainlink feed, USD price
        uint8 tokenDecimals;
        uint8 feedDecimals;
        bool listed;
    }

    // ------------------------------------------------------------------ constants

    uint256 public constant MAX_ASSETS = 16;
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    // ------------------------------------------------------------------ storage

    address public owner;
    address public pendingOwner;

    address public agent;
    uint64 public agentExpiry;
    bool public paused;

    Policy public policy;

    address public immutable quoteToken; // e.g. USDG
    uint8 public immutable quoteDecimals;
    address public immutable quoteFeed; // optional; zero means the quote token is valued at 1 USD
    uint8 public immutable quoteFeedDecimals;

    mapping(address => Asset) public assets;
    address[] public assetList;
    mapping(address => bool) public adapters;

    uint256 public peakValue; // USD, 18 decimals
    uint64 public currentDay;
    uint256 public dayBaseValue; // portfolio value at the first agent trade of the day
    uint256 public dayVolume; // agent volume today, USD 18 decimals

    uint256 private _lock = 1;

    // ------------------------------------------------------------------ events

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event AgentSet(address indexed agent, uint64 expiry);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event PolicyUpdated(Policy policy);
    event AssetSet(address indexed token, address indexed feed, bool listed);
    event AdapterSet(address indexed adapter, bool allowed);
    event PeakReset(uint256 newPeak);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Executed(address indexed target, uint256 value, bytes data);
    event AgentSwap(
        address indexed adapter,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 tradeValueUsd,
        uint256 portfolioValueAfter
    );

    // ------------------------------------------------------------------ errors

    error NotOwner();
    error NotPendingOwner();
    error NotAgent();
    error AgentExpired();
    error IsPaused();
    error Reentrancy();
    error ZeroAddress();
    error BadPolicy();
    error TooManyAssets();
    error AssetNotListed(address token);
    error AdapterNotAllowed(address adapter);
    error SameToken();
    error ZeroAmount();
    error StalePrice(address feed, uint256 updatedAt);
    error InvalidPrice(address feed);
    error MaxAllocExceeded(address token, uint256 allocBps, uint256 maxBps);
    error DailyLimitExceeded(uint256 volumeAfter, uint256 limit);
    error DrawdownSellOnly(uint256 value, uint256 peak);
    error SlippageTooHigh(uint256 minAmountOut, uint256 minAcceptable);
    error InsufficientOutput(uint256 received, uint256 minAmountOut);
    error OverSpent(uint256 spent, uint256 amountIn);
    error TokenCallFailed(address token);
    error CallFailed(bytes reason);

    // ------------------------------------------------------------------ modifiers

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ------------------------------------------------------------------ constructor

    constructor(address owner_, address quoteToken_, address quoteFeed_) {
        if (owner_ == address(0) || quoteToken_ == address(0)) revert ZeroAddress();
        owner = owner_;
        quoteToken = quoteToken_;
        quoteDecimals = IERC20(quoteToken_).decimals();
        quoteFeed = quoteFeed_;
        quoteFeedDecimals = quoteFeed_ == address(0) ? 8 : AggregatorV3Interface(quoteFeed_).decimals();
        policy = Policy({
            maxAllocBps: 2500, dailyLimitBps: 1000, drawdownBps: 1000, maxSlippageBps: 100, maxFeedAge: 72 hours
        });
        emit OwnershipTransferred(address(0), owner_);
        emit PolicyUpdated(policy);
    }

    receive() external payable {}

    // ================================================================== owner

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Give the agent a session key that expires at `expiry` (unix seconds).
    function setAgent(address agent_, uint64 expiry) external onlyOwner {
        agent = agent_;
        agentExpiry = expiry;
        emit AgentSet(agent_, expiry);
    }

    /// @notice Kill switch: stop the agent and revoke its session key.
    function pause() external onlyOwner {
        paused = true;
        agent = address(0);
        agentExpiry = 0;
        emit AgentSet(address(0), 0);
        emit Paused(msg.sender);
    }

    /// @notice Resume. A new session key must be set with `setAgent`.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setPolicy(Policy calldata p) external onlyOwner {
        if (
            p.maxAllocBps < 100 || p.maxAllocBps > BPS || p.dailyLimitBps == 0 || p.dailyLimitBps > BPS
                || p.drawdownBps < 100 || p.drawdownBps > 9000 || p.maxSlippageBps > 1000 || p.maxFeedAge < 60
                || p.maxFeedAge > 7 days
        ) revert BadPolicy();
        policy = p;
        emit PolicyUpdated(p);
    }

    /// @notice List or delist a Stock Token with its Chainlink USD feed.
    function setAsset(address token, address feed, bool listed) external onlyOwner {
        if (token == address(0) || token == quoteToken) revert ZeroAddress();
        Asset storage a = assets[token];
        if (listed) {
            if (feed == address(0)) revert ZeroAddress();
            if (!a.listed) {
                if (assetList.length >= MAX_ASSETS) revert TooManyAssets();
                assetList.push(token);
            }
            a.feed = feed;
            a.tokenDecimals = IERC20(token).decimals();
            a.feedDecimals = AggregatorV3Interface(feed).decimals();
            a.listed = true;
        } else if (a.listed) {
            a.listed = false;
            uint256 n = assetList.length;
            for (uint256 i; i < n; ++i) {
                if (assetList[i] == token) {
                    assetList[i] = assetList[n - 1];
                    assetList.pop();
                    break;
                }
            }
        }
        emit AssetSet(token, feed, listed);
    }

    function setAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        adapters[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    /// @notice Reset the drawdown peak to the current portfolio value.
    function resetPeak() external onlyOwner {
        peakValue = portfolioValue();
        emit PeakReset(peakValue);
    }

    /// @notice Withdraw any token (or ETH with token = address(0)). Never blocked by the policy.
    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, uint256 before) = _tryPortfolioValue();
        if (token == address(0)) {
            (bool sent,) = to.call{value: amount}("");
            if (!sent) revert CallFailed("");
        } else {
            _safeTransfer(token, to, amount);
        }
        _rescaleAfterOwnerAction(ok, before);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Owner escape hatch for anything else (e.g. claiming, migrating).
    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        returns (bytes memory result)
    {
        (bool ok, uint256 before) = _tryPortfolioValue();
        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) revert CallFailed(result);
        _rescaleAfterOwnerAction(ok, before);
        emit Executed(target, value, data);
    }

    // ================================================================== agent

    /// @notice Swap `amountIn` of `tokenIn` for at least `minAmountOut` of `tokenOut` through an
    ///         allowlisted adapter. Reverts unless every policy rule passes.
    function agentSwap(address adapter, address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        // --- who
        if (paused) revert IsPaused();
        if (msg.sender != agent || agent == address(0)) revert NotAgent();
        if (block.timestamp >= agentExpiry) revert AgentExpired();

        // --- what
        if (!adapters[adapter]) revert AdapterNotAllowed(adapter);
        if (tokenIn == tokenOut) revert SameToken();
        if (amountIn == 0) revert ZeroAmount();
        _requireTradable(tokenIn);
        _requireTradable(tokenOut);

        uint256 tradeValue = _preTradeChecks(tokenIn, tokenOut, amountIn, minAmountOut);
        amountOut = _executeSwap(adapter, tokenIn, tokenOut, amountIn, minAmountOut);
        uint256 valueAfter = _postTradeChecks(tokenOut);

        emit AgentSwap(adapter, tokenIn, tokenOut, amountIn, amountOut, tradeValue, valueAfter);
    }

    /// @dev Drawdown, daily limit and oracle slippage bound. Returns the trade value in USD.
    function _preTradeChecks(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 tradeValue)
    {
        Policy memory p = policy;
        uint256 valueBefore = portfolioValue();

        // drawdown: below the limit the agent may only de-risk into the quote token
        if (valueBefore > peakValue) peakValue = valueBefore;
        if (valueBefore * BPS < peakValue * (BPS - p.drawdownBps) && tokenOut != quoteToken) {
            revert DrawdownSellOnly(valueBefore, peakValue);
        }

        // daily limit, measured against the portfolio value at the first trade of the day
        tradeValue = _usdValue(tokenIn, amountIn);
        uint64 today = uint64(block.timestamp / 1 days);
        if (today != currentDay) {
            currentDay = today;
            dayVolume = 0;
            dayBaseValue = valueBefore;
        }
        uint256 volumeAfter = dayVolume + tradeValue;
        uint256 limit = dayBaseValue * p.dailyLimitBps / BPS;
        if (volumeAfter > limit) revert DailyLimitExceeded(volumeAfter, limit);
        dayVolume = volumeAfter;

        // slippage bound from the oracle
        uint256 minAcceptable = _amountForUsd(tokenOut, tradeValue) * (BPS - p.maxSlippageBps) / BPS;
        if (minAmountOut < minAcceptable) revert SlippageTooHigh(minAmountOut, minAcceptable);
    }

    /// @dev Approve exactly `amountIn`, swap, clear the approval and measure real balance changes.
    function _executeSwap(address adapter, address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        _safeApprove(tokenIn, adapter, amountIn);
        ISwapAdapter(adapter).swap(tokenIn, tokenOut, amountIn, minAmountOut, address(this));
        _safeApprove(tokenIn, adapter, 0);
        uint256 spent = inBefore - IERC20(tokenIn).balanceOf(address(this));
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (spent > amountIn) revert OverSpent(spent, amountIn);
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
    }

    /// @dev Max allocation after a buy. Returns the portfolio value after the trade.
    function _postTradeChecks(address tokenOut) internal view returns (uint256 valueAfter) {
        valueAfter = portfolioValue();
        if (tokenOut != quoteToken && valueAfter > 0) {
            uint256 maxBps = policy.maxAllocBps;
            uint256 allocBps = _usdValue(tokenOut, IERC20(tokenOut).balanceOf(address(this))) * BPS / valueAfter;
            if (allocBps > maxBps) revert MaxAllocExceeded(tokenOut, allocBps, maxBps);
        }
    }

    // ================================================================== views

    /// @notice Portfolio value in USD with 18 decimals (quote token + listed assets).
    ///         Reverts if a held asset's price is stale or invalid.
    function portfolioValue() public view returns (uint256 total) {
        uint256 qb = IERC20(quoteToken).balanceOf(address(this));
        if (qb > 0) total = _usdValue(quoteToken, qb);
        uint256 n = assetList.length;
        for (uint256 i; i < n; ++i) {
            address t = assetList[i];
            uint256 b = IERC20(t).balanceOf(address(this));
            if (b > 0) total += _usdValue(t, b);
        }
    }

    /// @notice Share of portfolio value held in `token`, in basis points.
    function allocationBps(address token) external view returns (uint256) {
        uint256 v = portfolioValue();
        if (v == 0) return 0;
        return _usdValue(token, IERC20(token).balanceOf(address(this))) * BPS / v;
    }

    /// @notice Agent volume still available today, USD 18 decimals.
    function dailyRemaining() external view returns (uint256) {
        Policy memory p = policy;
        uint256 base = uint64(block.timestamp / 1 days) == currentDay ? dayBaseValue : portfolioValue();
        uint256 used = uint64(block.timestamp / 1 days) == currentDay ? dayVolume : 0;
        uint256 limit = base * p.dailyLimitBps / BPS;
        return limit > used ? limit - used : 0;
    }

    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    function agentActive() external view returns (bool) {
        return !paused && agent != address(0) && block.timestamp < agentExpiry;
    }

    // ================================================================== internal

    function _requireTradable(address token) internal view {
        if (token != quoteToken && !assets[token].listed) revert AssetNotListed(token);
    }

    function _price(address token) internal view returns (uint256 price, uint8 feedDecimals, uint8 tokenDecimals) {
        address feed;
        if (token == quoteToken) {
            tokenDecimals = quoteDecimals;
            feedDecimals = quoteFeedDecimals;
            if (quoteFeed == address(0)) return (10 ** uint256(feedDecimals), feedDecimals, tokenDecimals);
            feed = quoteFeed;
        } else {
            Asset storage a = assets[token];
            if (!a.listed) revert AssetNotListed(token);
            feed = a.feed;
            feedDecimals = a.feedDecimals;
            tokenDecimals = a.tokenDecimals;
        }
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(feed);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > policy.maxFeedAge) {
            revert StalePrice(feed, updatedAt);
        }
        price = uint256(answer);
    }

    function _usdValue(address token, uint256 amount) internal view returns (uint256) {
        (uint256 price, uint8 fd, uint8 td) = _price(token);
        return amount * price * WAD / (10 ** uint256(td)) / (10 ** uint256(fd));
    }

    function _amountForUsd(address token, uint256 usd) internal view returns (uint256) {
        (uint256 price, uint8 fd, uint8 td) = _price(token);
        return usd * (10 ** uint256(td)) * (10 ** uint256(fd)) / price / WAD;
    }

    function _tryPortfolioValue() internal view returns (bool ok, uint256 value) {
        try this.portfolioValue() returns (uint256 v) {
            return (true, v);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Owner withdrawals must not look like a drawdown to the agent, and must shrink the
    ///      daily budget proportionally. If prices are unavailable the peak is cleared instead.
    function _rescaleAfterOwnerAction(bool okBefore, uint256 before) internal {
        (bool okAfter, uint256 afterValue) = _tryPortfolioValue();
        if (okBefore && okAfter && before > 0) {
            if (afterValue < before) {
                peakValue = peakValue * afterValue / before;
                dayBaseValue = dayBaseValue * afterValue / before;
            }
        } else {
            peakValue = 0;
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenCallFailed(token);
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.approve, (spender, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenCallFailed(token);
    }
}
