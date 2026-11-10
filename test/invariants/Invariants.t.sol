// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test,console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {DUSDEngine} from "../../src/DUSDEngine.sol";
import {DUSD} from "../../src/DUSD.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDUSDEngine} from "../../script/DeployDUSDEngine.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {HandlerInvariant} from "./HandlerInvariant.t.sol";

/**
 * @title Invariants
 * @author Abdelbasset10
 * @notice Stateful fuzz tests for the DUSD system. Three users with WETH and WBTC interact with the
 *         engine through `HandlerInvariant`, and the invariants are checked after every call.
 */
contract Invariants is StdInvariant, Test {
    DUSDEngine dusdEngine;
    DUSD dusd;
    HelperConfig helperConfig;
    HelperConfig.NetworkConfig config;
    HandlerInvariant handlerInvariant;

    address[] users = new address[](3);
    uint256 constant STARTING_BALANCE = 100e18;

    function setUp() public {
        DeployDUSDEngine deployer = new DeployDUSDEngine();
        (dusd, dusdEngine, helperConfig) = deployer.run();
        config = helperConfig.getActiveNetwork();

        for (uint256 i = 0; i < users.length; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i + 1)));
            ERC20Mock(config.weth).mint(users[i], STARTING_BALANCE);
            ERC20Mock(config.btc).mint(users[i], STARTING_BALANCE);
        }
        handlerInvariant = new HandlerInvariant(address(dusdEngine),address(dusd),users);
        targetContract(address(handlerInvariant));
    }

    /// @notice The USD value of all collateral must always be at least the total DUSD debt.
    function invariant_ProtocolHasAlwaysMoreColletralValuesThanDUSD() view public {
        console.log("HEelllo");
        uint256 allColletralAmounts;
        uint256 allDUSDMinted;

        for(uint256 i=0;i<users.length;i++){
            allColletralAmounts += dusdEngine.getAccountCollateralValue(users[i]);
        }

        for(uint256 i=0;i<users.length;i++){
            allDUSDMinted += dusdEngine.getUserDUSD(users[i]);
        }

        console.log("allColletralAmounts : ",allColletralAmounts);
        console.log("allDUSDMinted : ",allDUSDMinted);
        assert(allColletralAmounts >= allDUSDMinted);

        
    }
}
