// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {RobinhoodChain} from "./RobinhoodChain.sol";

/// @notice Initializes the USDG/$FAITH FAITHFUL pool at the live $FAITH price. Liquidity is added afterwards
///         from the treasury, through the Uniswap app's "custom hook" position flow.
/// forge script script/OpenFaithPool.s.sol --sig "run(address)" <hook> --rpc-url https://rpc.mainnet.chain.robinhood.com --account <keystore> --broadcast
contract OpenFaithPool is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run(address hook) external returns (PoolId poolId) {
        IPoolManager manager = IPoolManager(RobinhoodChain.POOL_MANAGER);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(RobinhoodChain.livePonsPoolKey().toId());
        PoolKey memory key = RobinhoodChain.faithPoolKey(IHooks(hook));
        vm.startBroadcast();
        manager.initialize(key, sqrtPriceX96);
        vm.stopBroadcast();
        poolId = key.toId();
        console.logBytes32(PoolId.unwrap(poolId));
    }
}
