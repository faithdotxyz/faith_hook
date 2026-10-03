// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {FaithfulHook} from "../src/FaithfulHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {RobinhoodChain} from "../script/RobinhoodChain.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @dev Run with `forge test --fork-url <Robinhood Chain RPC>`; skipped on any other chain. Deploys the hook
///      through the deterministic CREATE2 deployer exactly as the deploy script does, opens a USDG/$FAITH
///      pool on the real PoolManager at the price of the live $FAITH pool, and swaps through the deployed
///      Universal Router and V4Quoter.
contract FaithfulHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // The Robinhood Chain Universal Router's single-pool swap struct carries one uint256 more than v4-periphery's.
    struct ExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amount;
        uint128 limit;
        uint256 extra;
        bytes hookData;
    }

    bytes1 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE = 0x0e;

    IPoolManager internal manager = IPoolManager(RobinhoodChain.POOL_MANAGER);
    IERC20Minimal internal usdg = IERC20Minimal(RobinhoodChain.USDG);
    IERC20Minimal internal faith = IERC20Minimal(RobinhoodChain.FAITH);
    FaithfulHook internal hook;
    PoolKey internal key;

    function setUp() public {
        if (block.chainid != RobinhoodChain.CHAIN_ID) vm.skip(true);

        bytes memory args = RobinhoodChain.constructorArgs();
        (address expected, bytes32 salt) =
            HookMiner.find(RobinhoodChain.CREATE2_DEPLOYER, RobinhoodChain.FLAGS, type(FaithfulHook).creationCode, args);
        (bool ok,) = RobinhoodChain.CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(FaithfulHook).creationCode, args));
        assertTrue(ok);
        hook = FaithfulHook(expected);
        assertEq(hook.treasury(), RobinhoodChain.TREASURY);

        key = RobinhoodChain.faithPoolKey(IHooks(address(hook)));
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(RobinhoodChain.livePonsPoolKey().toId());
        manager.initialize(key, sqrtPriceX96);
        assertTrue(hook.titheInCurrency0(key.toId()), "USDG is currency0 and the quote");

        deal(address(usdg), address(this), 1_000_000e6);
        deal(address(faith), address(this), 1_000_000_000 ether);
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        usdg.approve(address(liquidityRouter), type(uint256).max);
        faith.approve(address(liquidityRouter), type(uint256).max);
        int24 center = tick / key.tickSpacing * key.tickSpacing;
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: center - 40 * key.tickSpacing,
                tickUpper: center + 40 * key.tickSpacing,
                liquidityDelta: 1e17,
                salt: 0
            }),
            ""
        );

        usdg.approve(RobinhoodChain.PERMIT2, type(uint256).max);
        faith.approve(RobinhoodChain.PERMIT2, type(uint256).max);
        IPermit2(RobinhoodChain.PERMIT2)
            .approve(address(usdg), RobinhoodChain.UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(RobinhoodChain.PERMIT2)
            .approve(address(faith), RobinhoodChain.UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
    }

    function routerSwap(uint8 action, bool buy, uint128 amount, uint128 limit) internal {
        (address payIn, address getOut) = buy ? (address(usdg), address(faith)) : (address(faith), address(usdg));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactSingleParams(key, buy, amount, limit, 0, ""));
        params[1] = abi.encode(payIn, action == SWAP_EXACT_IN_SINGLE ? amount : limit);
        params[2] = abi.encode(getOut, address(this), 0);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(action, SETTLE_ALL, TAKE), params);
        IUniversalRouter(RobinhoodChain.UNIVERSAL_ROUTER).execute(abi.encodePacked(V4_SWAP), inputs);
    }

    function test_universalRouterExactInputBuy() public {
        (uint256 quoted,) = IV4Quoter(RobinhoodChain.V4_QUOTER)
            .quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, true, 100e6, ""));
        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 faithBefore = faith.balanceOf(address(this));
        uint256 treasuryBefore = usdg.balanceOf(RobinhoodChain.TREASURY);
        routerSwap(SWAP_EXACT_IN_SINGLE, true, 100e6, 0);
        assertEq(usdgBefore - usdg.balanceOf(address(this)), 100e6, "paid exactly the input");
        assertEq(usdg.balanceOf(RobinhoodChain.TREASURY) - treasuryBefore, 0.3e6, "0.3% of 100 USDG");
        assertEq(faith.balanceOf(address(this)) - faithBefore, quoted, "the quoter prices the tithe in");
    }

    function test_universalRouterExactInputSell() public {
        (uint256 quoted,) = IV4Quoter(RobinhoodChain.V4_QUOTER)
            .quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, false, 10_000 ether, ""));
        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 treasuryBefore = usdg.balanceOf(RobinhoodChain.TREASURY);
        routerSwap(SWAP_EXACT_IN_SINGLE, false, 10_000 ether, 0);
        uint256 received = usdg.balanceOf(address(this)) - usdgBefore;
        uint256 tithe = usdg.balanceOf(RobinhoodChain.TREASURY) - treasuryBefore;
        assertEq(received, quoted, "the quoter prices the tithe in");
        assertApproxEqAbs(tithe, (received + tithe) * 30 / 10_000, 1, "0.3% of the gross proceeds");
    }

    function test_universalRouterExactOutputBuy() public {
        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 faithBefore = faith.balanceOf(address(this));
        uint256 treasuryBefore = usdg.balanceOf(RobinhoodChain.TREASURY);
        routerSwap(SWAP_EXACT_OUT_SINGLE, true, 1_000 ether, 1_000_000e6);
        uint256 paid = usdgBefore - usdg.balanceOf(address(this));
        assertEq(faith.balanceOf(address(this)) - faithBefore, 1_000 ether, "received exactly the output");
        assertApproxEqAbs(usdg.balanceOf(RobinhoodChain.TREASURY) - treasuryBefore, paid * 30 / 10_000, 1);
    }

    function test_universalRouterExactOutputSell() public {
        uint256 usdgBefore = usdg.balanceOf(address(this));
        uint256 treasuryBefore = usdg.balanceOf(RobinhoodChain.TREASURY);
        routerSwap(SWAP_EXACT_OUT_SINGLE, false, 9.97e6, type(uint128).max);
        assertEq(usdg.balanceOf(address(this)) - usdgBefore, 9.97e6, "received exactly the output");
        assertEq(usdg.balanceOf(RobinhoodChain.TREASURY) - treasuryBefore, 0.03e6, "0.3% of 10 USDG gross");
    }

    function test_directPoolManagerSwapsInAllFourShapes() public {
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        usdg.approve(address(swapRouter), type(uint256).max);
        faith.approve(address(swapRouter), type(uint256).max);
        int256[4] memory amounts = [int256(-100e6), int256(1_000 ether), int256(-10_000 ether), int256(10e6)];
        bool[4] memory buys = [true, true, false, false];
        for (uint256 i = 0; i < 4; i++) {
            uint256 treasuryBefore = usdg.balanceOf(RobinhoodChain.TREASURY);
            BalanceDelta delta = swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: buys[i],
                    amountSpecified: amounts[i],
                    sqrtPriceLimitX96: buys[i] ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            uint256 tithe = usdg.balanceOf(RobinhoodChain.TREASURY) - treasuryBefore;
            uint256 price = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : uint128(delta.amount0()) + tithe;
            assertApproxEqAbs(tithe, price * 30 / 10_000, 1);
        }
    }
}
