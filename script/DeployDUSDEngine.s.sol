// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {DUSD} from "../src/DUSD.sol";
import {DUSDEngine} from "../src/DUSDEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/**
 * @title DeployDUSDEngine
 * @author Abdelbasset10
 * @notice Deploys the DUSD token and the DUSDEngine, then makes the engine the owner of DUSD.
 */
contract DeployDUSDEngine is Script {
    DUSD dusd;
    DUSDEngine dusdEngine;

    /**
     * @notice Runs the deployment.
     * @return The deployed DUSD token.
     * @return The deployed DUSDEngine.
     * @return The HelperConfig used, so tests can read the network addresses.
     */
    function run() external returns (DUSD, DUSDEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveNetwork();

        address[] memory tokens = new address[](2);
        tokens[0] = config.weth;
        tokens[1] = config.btc;

        address[] memory feeds = new address[](2);
        feeds[0] = config.weethFeed;
        feeds[1] = config.btcFeed;
        vm.startBroadcast(config.deployer);
        dusd = new DUSD();
        dusdEngine = new DUSDEngine(tokens, feeds, address(dusd));
        dusd.transferOwnership(address(dusdEngine));
        vm.stopBroadcast();
        return (dusd, dusdEngine, helperConfig);
    }
}
