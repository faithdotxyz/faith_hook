// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title FAITHFUL
/// @notice Tithes 0.3% of the price of every swap to the treasury of the Faith: 0.3% of what a buyer pays and
///         of what a seller is paid, always in the pool's quote currency (ETH, WETH or USDG), whichever way and
///         whichever side the swap specifies. Immutable, ownerless, holds nothing between swaps.
contract FaithfulHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint160 public constant REQUIRED_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 public constant TITHE_BPS = 30;
    uint256 public constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    address public immutable treasury;
    Currency public immutable usdg;
    Currency public immutable weth;

    mapping(PoolId => bool) public titheInCurrency0;

    event Tithe(PoolId indexed poolId, address indexed sender, Currency indexed currency, uint256 amount);

    error NotPoolManager();
    error HookNotImplemented();
    error NoQuoteCurrency();

    constructor(IPoolManager poolManager_, address treasury_, Currency usdg_, Currency weth_) {
        poolManager = poolManager_;
        treasury = treasury_;
        usdg = usdg_;
        weth = weth_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function isQuote(Currency currency) public view returns (bool) {
        return currency.isAddressZero() || currency == usdg || currency == weth;
    }

    /// @notice The tithe on `amount` of quote. An exact-input amount already contains the tithe, an exact-output
    ///         amount does not, so both come to 0.3% of the full price paid or received.
    function titheOf(uint256 amount, bool exactInput) public pure returns (uint256) {
        return amount * TITHE_BPS / (exactInput ? BPS : BPS - TITHE_BPS);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (isQuote(key.currency0)) titheInCurrency0[key.toId()] = true;
        else if (!isQuote(key.currency1)) revert NoQuoteCurrency();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_titheIsSpecified(key, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 tithe = titheOf(_abs(params.amountSpecified), params.amountSpecified < 0);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(tithe.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        bool inCurrency0 = titheInCurrency0[poolId];
        Currency currency = inCurrency0 ? key.currency0 : key.currency1;
        bool exactInput = params.amountSpecified < 0;
        if (_titheIsSpecified(key, params)) {
            _pay(poolId, sender, currency, titheOf(_abs(params.amountSpecified), exactInput));
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 tithe = titheOf(_abs(inCurrency0 ? delta.amount0() : delta.amount1()), exactInput);
        _pay(poolId, sender, currency, tithe);
        return (IHooks.afterSwap.selector, tithe.toInt128());
    }

    function _titheIsSpecified(PoolKey calldata key, SwapParams calldata params) internal view returns (bool) {
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIsCurrency0 == titheInCurrency0[key.toId()];
    }

    function _pay(PoolId poolId, address sender, Currency currency, uint256 tithe) internal {
        if (tithe == 0) return;
        poolManager.take(currency, treasury, tithe);
        emit Tithe(poolId, sender, currency, tithe);
    }

    function _abs(int256 amount) internal pure returns (uint256) {
        return amount < 0 ? uint256(-amount) : uint256(amount);
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
