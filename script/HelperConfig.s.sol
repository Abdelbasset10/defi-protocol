// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
import {Script} from "forge-std/Script.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

/**
 * @title HelperConfig
 * @author Abdelbasset10
 * @notice Provides the collateral token and price feed addresses for the current network.
 * @dev On Sepolia it returns the real addresses. On any other chain (Anvil, tests) it deploys
 *      mock tokens and mock price feeds.
 */
contract HelperConfig is Script {
    /// @notice Decimals used by the mock price feeds (same as Chainlink USD pairs).
    uint8 public constant FEED_DECIMALS = 8;
    /// @notice Starting ETH/USD price of the mock feed ($2,000).
    int256 public constant ETH_USD_PRICE = 2000e8;
    /// @notice Starting BTC/USD price of the mock feed ($60,000).
    int256 public constant BTC_USD_PRICE = 60000e8;
    /// @notice Amount of each mock token minted to the deployer.
    uint256 public constant INITIAL_BALANCE = 1000e18;
    /// @notice Chain ID of the Sepolia testnet.
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    /// @notice Private key of Anvil's default account #0. Public and only valid on a local chain.
    uint256 public constant ANVIL_DEFAULT_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /**
     * @notice The addresses needed to deploy the engine on a network.
     * @param weth The WETH collateral token.
     * @param btc The WBTC collateral token.
     * @param weethFeed The ETH/USD price feed.
     * @param btcFeed The BTC/USD price feed.
     * @param deployer The account that deploys the contracts.
     */
    struct NetworkConfig {
        address weth;
        address btc;
        address weethFeed;
        address btcFeed;
        address deployer;
    }

    /// @dev The configuration for the current chain, set in the constructor.
    NetworkConfig activeNetwork;

    /// @notice Picks the configuration for the current chain.
    constructor() {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeNetwork = getSepoliaConfig();
        } else {
            activeNetwork = getOrCreateAnvilConfig();
        }
    }

    /// @notice Returns the configuration for the current chain.
    function getActiveNetwork() public view returns (NetworkConfig memory) {
        return activeNetwork;
    }

    /**
     * @notice Returns the Sepolia configuration.
     * @dev Requires the `SEPOLIA_WBTC` and `DEPLOYER_ADDRESS` environment variables.
     */
    function getSepoliaConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            // WETH9 on Sepolia (18 decimals)
            weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
            // Sepolia has no canonical WBTC: set this to the 18-decimal token you deployed
            btc: vm.envAddress("SEPOLIA_WBTC"),
            // Chainlink ETH/USD (8 decimals)
            weethFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            // Chainlink BTC/USD (8 decimals)
            btcFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            deployer: vm.envAddress("DEPLOYER_ADDRESS")
        });
    }

    /**
     * @notice Returns the local configuration, deploying mock tokens and price feeds the first time.
     * @dev Mints `INITIAL_BALANCE` of each mock token to Anvil's default account.
     */
    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetwork.weth != address(0)) {
            return activeNetwork;
        }

        address deployer = vm.addr(ANVIL_DEFAULT_KEY);

        vm.startBroadcast(ANVIL_DEFAULT_KEY);
        ERC20Mock weth = new ERC20Mock();
        ERC20Mock btc = new ERC20Mock();
        MockV3Aggregator wethFeed = new MockV3Aggregator(FEED_DECIMALS, ETH_USD_PRICE);
        MockV3Aggregator btcFeed = new MockV3Aggregator(FEED_DECIMALS, BTC_USD_PRICE);
        weth.mint(deployer, INITIAL_BALANCE);
        btc.mint(deployer, INITIAL_BALANCE);
        vm.stopBroadcast();

        activeNetwork = NetworkConfig({
            weth: address(weth),
            btc: address(btc),
            weethFeed: address(wethFeed),
            btcFeed: address(btcFeed),
            deployer: deployer
        });
        return activeNetwork;
    }
}
