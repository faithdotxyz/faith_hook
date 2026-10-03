// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FaithfulHook} from "../src/FaithfulHook.sol";
import {HookMiner} from "../src/HookMiner.sol";

contract FaithfulHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant LP_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    FaithfulHook internal hook;
    address internal treasury = makeAddr("treasury");

    MockERC20 internal low;
    MockERC20 internal usdg;
    MockERC20 internal high;
    MockERC20 internal weth;

    PoolKey internal quoteIsCurrency1;
    PoolKey internal quoteIsCurrency0;
    PoolKey internal nativeEth;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        MockERC20[3] memory tokens =
            [new MockERC20("A", "A", 18), new MockERC20("B", "B", 18), new MockERC20("C", "C", 18)];
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (address(tokens[j]) < address(tokens[i])) (tokens[i], tokens[j]) = (tokens[j], tokens[i]);
            }
        }
        (low, usdg, high) = (tokens[0], tokens[1], tokens[2]);
        weth = new MockERC20("WETH", "WETH", 18);
        MockERC20[4] memory all = [low, usdg, high, weth];
        for (uint256 i = 0; i < 4; i++) {
            all[i].mint(address(this), 1e30);
            all[i].approve(address(swapRouter), type(uint256).max);
            all[i].approve(address(liquidityRouter), type(uint256).max);
        }
        vm.deal(address(this), 1e30);

        bytes memory args = abi.encode(manager, treasury, Currency.wrap(address(usdg)), Currency.wrap(address(weth)));
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), hookFlags(), type(FaithfulHook).creationCode, args);
        hook =
            new FaithfulHook{salt: salt}(manager, treasury, Currency.wrap(address(usdg)), Currency.wrap(address(weth)));
        assertEq(address(hook), expected);

        quoteIsCurrency1 = open(Currency.wrap(address(low)), Currency.wrap(address(usdg)));
        quoteIsCurrency0 = open(Currency.wrap(address(usdg)), Currency.wrap(address(high)));
        nativeEth = open(Currency.wrap(address(0)), Currency.wrap(address(low)));
    }

    receive() external payable {}

    function hookFlags() internal pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    function open(Currency currency0, Currency currency1) internal returns (PoolKey memory key) {
        key = PoolKey(currency0, currency1, LP_FEE, TICK_SPACING, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e24, salt: 0});
        liquidityRouter.modifyLiquidity{value: currency0.isAddressZero() ? 1e24 : 0}(key, params, "");
    }

    function quoteOf(PoolKey memory key) internal view returns (Currency) {
        return hook.isQuote(key.currency0) ? key.currency0 : key.currency1;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint256 value = key.currency0.isAddressZero() && zeroForOne ? 1e24 : 0;
        return swapRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Swaps, then checks the tithe reached the treasury as 0.3% of the full price paid or received,
    ///      that the swapper got exactly what they specified, and that the hook kept nothing.
    function swapAndCheck(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256 tithe, uint256 price)
    {
        Currency quote = quoteOf(key);
        uint256 before = quote.balanceOf(treasury);
        BalanceDelta delta = swap(key, zeroForOne, amountSpecified);
        tithe = quote.balanceOf(treasury) - before;

        bool specifiedIsCurrency0 = (amountSpecified < 0) == zeroForOne;
        assertEq(
            specifiedIsCurrency0 ? delta.amount0() : delta.amount1(), amountSpecified, "swapper got what they asked"
        );

        int128 quoteDelta = quote == key.currency0 ? delta.amount0() : delta.amount1();
        price = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : uint256(uint128(quoteDelta)) + tithe;
        assertApproxEqAbs(tithe, price * 30 / 10_000, 1, "0.3% of the price");
        assertEq(quote.balanceOf(address(hook)), 0, "the hook holds nothing");
    }

    function test_addressCarriesExactlyTheDeclaredFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, hook.REQUIRED_FLAGS());
        assertEq(hook.REQUIRED_FLAGS(), hookFlags());
    }

    function test_quoteSideIsRecordedAtInitialize() public view {
        assertFalse(hook.titheInCurrency0(_id(quoteIsCurrency1)));
        assertTrue(hook.titheInCurrency0(_id(quoteIsCurrency0)));
        assertTrue(hook.titheInCurrency0(_id(nativeEth)));
    }

    function test_exactInputBuyTithesThePricePaid() public {
        (uint256 tithe, uint256 price) = swapAndCheck(quoteIsCurrency1, false, -1_000 ether);
        assertEq(price, 1_000 ether);
        assertEq(tithe, 3 ether);
    }

    function test_exactOutputBuyTithesOnTopOfThePrice() public {
        swapAndCheck(quoteIsCurrency1, false, 1_000 ether);
    }

    function test_exactInputSellTithesTheProceeds() public {
        swapAndCheck(quoteIsCurrency1, true, -1_000 ether);
    }

    function test_exactOutputSellPaysExactlyAndTithesTheGrossProceeds() public {
        (uint256 tithe, uint256 price) = swapAndCheck(quoteIsCurrency1, true, 997 ether);
        assertEq(price, 1_000 ether);
        assertEq(tithe, 3 ether);
    }

    function test_allFourShapesWhenQuoteIsCurrency0() public {
        swapAndCheck(quoteIsCurrency0, true, -1_000 ether);
        swapAndCheck(quoteIsCurrency0, true, 1_000 ether);
        swapAndCheck(quoteIsCurrency0, false, -1_000 ether);
        swapAndCheck(quoteIsCurrency0, false, 1_000 ether);
    }

    function test_nativeEthPoolTithesEth() public {
        (uint256 tithe,) = swapAndCheck(nativeEth, true, -1 ether);
        assertEq(tithe, 0.003 ether);
        assertEq(treasury.balance, 0.003 ether);
        swapAndCheck(nativeEth, false, -1 ether);
    }

    function test_dustSwapTithesNothingAndStillSettles() public {
        (uint256 tithe,) = swapAndCheck(quoteIsCurrency1, false, -100);
        assertEq(tithe, 0);
    }

    function test_poolWithoutAQuoteCurrencyCannotOpen() public {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(low)), Currency.wrap(address(high)), LP_FEE, TICK_SPACING, IHooks(address(hook))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FaithfulHook.NoQuoteCurrency.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_callbacksRefuseAnyoneButThePoolManager() public {
        vm.expectRevert(FaithfulHook.NotPoolManager.selector);
        hook.afterSwap(address(this), quoteIsCurrency1, SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
        vm.expectRevert(FaithfulHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), quoteIsCurrency1, SQRT_PRICE_1_1);
    }

    function testFuzz_titheIsAlwaysPointThreePercentOfThePrice(
        uint8 pool,
        bool zeroForOne,
        bool exactInput,
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 1e22);
        PoolKey memory key = pool % 3 == 0 ? quoteIsCurrency1 : pool % 3 == 1 ? quoteIsCurrency0 : nativeEth;
        swapAndCheck(key, zeroForOne, exactInput ? -int256(amount) : int256(amount));
    }

    function _id(PoolKey memory key) internal pure returns (PoolId) {
        return key.toId();
    }
}
