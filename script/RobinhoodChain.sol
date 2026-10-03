// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Robinhood Chain (4663) addresses the hook is deployed and tested against.
library RobinhoodChain {
    uint256 internal constant CHAIN_ID = 4663;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant V4_QUOTER = 0x55083D93eAdff4E1875E5489986Ad56806883139;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address internal constant TREASURY = 0x94C114b759937e232F9228afaBf1CfB12fD59F62;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant FAITH = 0x72AEC25d3c3A5fD9772901e8433fe5c8cf4eaA04;
    address internal constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;

    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    // 2.7% to LPs plus the 0.3% tithe matches the live pool's 3% creator tax, so this pool never undercuts it.
    uint24 internal constant FAITH_POOL_LP_FEE = 27_000;
    int24 internal constant TICK_SPACING = 200;

    function constructorArgs() internal pure returns (bytes memory) {
        return abi.encode(POOL_MANAGER, TREASURY, USDG, WETH);
    }

    function faithPoolKey(IHooks hook) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDG), Currency.wrap(FAITH), FAITH_POOL_LP_FEE, TICK_SPACING, hook);
    }

    function livePonsPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDG), Currency.wrap(FAITH), 0, TICK_SPACING, IHooks(PONS_HOOK));
    }
}
