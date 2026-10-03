// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {FaithfulHook} from "../src/FaithfulHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {RobinhoodChain} from "./RobinhoodChain.sol";

/// @notice Mines the salt and deploys FAITHFUL through the deterministic CREATE2 deployer, so anyone can
///         reproduce the address from the source, the constructor arguments and the salt.
/// forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account <keystore> --broadcast
contract Deploy is Script {
    function run() external returns (FaithfulHook hook) {
        require(block.chainid == RobinhoodChain.CHAIN_ID, "Robinhood Chain only");
        bytes memory initCode = abi.encodePacked(type(FaithfulHook).creationCode, RobinhoodChain.constructorArgs());
        (address expected, bytes32 salt) = HookMiner.find(
            RobinhoodChain.CREATE2_DEPLOYER,
            RobinhoodChain.FLAGS,
            type(FaithfulHook).creationCode,
            RobinhoodChain.constructorArgs()
        );
        console.log("hook", expected);
        console.logBytes32(salt);
        console.logBytes32(keccak256(initCode));

        vm.startBroadcast();
        (bool ok,) = RobinhoodChain.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        require(ok && expected.code.length > 0, "deploy failed");
        hook = FaithfulHook(expected);
        require(hook.treasury() == RobinhoodChain.TREASURY, "wrong treasury");
        console.logBytes32(expected.codehash);
    }
}
