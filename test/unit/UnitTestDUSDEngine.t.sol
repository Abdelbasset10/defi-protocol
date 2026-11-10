// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {DUSDEngine} from "../../src/DUSDEngine.sol";
import {DUSD} from "../../src/DUSD.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDUSDEngine} from "../../script/DeployDUSDEngine.s.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title UnitTestDUSDEngine
 * @author Abdelbasset10
 * @notice Unit tests for DUSDEngine: price conversions, deposits, minting, burning, redeeming,
 *         health factor and liquidation. Expected values are computed from the current feed
 *         prices, so the tests do not depend on fixed prices.
 */
contract UnitTestDUSDEngine is Test {
    DUSDEngine dusdEngine;
    DUSD dusd;
    HelperConfig helperConfig;
    HelperConfig.NetworkConfig config;

    address user = makeAddr("user");
    uint256 constant STARTING_BALANCE = 100e18;

    function setUp() public {
        DeployDUSDEngine deployer = new DeployDUSDEngine();
        (dusd, dusdEngine, helperConfig) = deployer.run();
        config = helperConfig.getActiveNetwork();
        ERC20Mock(config.weth).mint(user, STARTING_BALANCE);
        ERC20Mock(config.btc).mint(user, STARTING_BALANCE);
    }

    function test_mismatchedArraysLengthRevert() public {
        address[] memory tokens = new address[](2);
        tokens[0] = config.weth;
        tokens[1] = config.btc;

        address[] memory feeds = new address[](1);
        feeds[0] = config.weethFeed;

        vm.expectRevert(DUSDEngine.DUSDEngine__LengthOfTokensAndFeedsAreNotTheSame.selector);
        new DUSDEngine(tokens, feeds, address(dusd));
    }

    function test_getUsdValue() public view {
        uint256 ethAmount = 15e18;
        // Read whatever price the feed reports right now (mock or real Chainlink)
        (, int256 price,,,) = AggregatorV3Interface(config.weethFeed).latestRoundData();
        uint8 feedDecimals = AggregatorV3Interface(config.weethFeed).decimals();
        // USD value with 18 decimals: amount (18 dec) * price (feedDecimals) / 10^feedDecimals
        uint256 expectedUsd = (ethAmount * uint256(price)) / (10 ** feedDecimals);

        uint256 actualUsd = dusdEngine.getUsdValue(config.weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function test_getTokenAmountFromUsd() public view {
        uint256 usdAmount = 100e18;
        (, int256 price,,,) = AggregatorV3Interface(config.weethFeed).latestRoundData();
        uint8 feedDecimals = AggregatorV3Interface(config.weethFeed).decimals();
        // token amount (18 dec) = usd (18 dec) * 10^feedDecimals / price
        uint256 expectedWeth = (usdAmount * 10 ** feedDecimals) / uint256(price);

        assertEq(dusdEngine.getTokenAmountFromUsd(config.weth, usdAmount), expectedWeth);
    }

    function test_depositWithZeroReverts() public {
        vm.prank(user);
        vm.expectRevert(DUSDEngine.DUSDEngine__AmountMustBeGraterThanZero.selector);
        dusdEngine.depositCollateral(config.weth, 0);
    }

    function test_depositWithUnImprovedToken() public {
        // LINK token on Sepolia: not registered as collateral in the engine
        address link = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
        vm.prank(user);
        vm.expectRevert(DUSDEngine.DUSDEngine__TokenIsNotAllowed.selector);
        dusdEngine.depositCollateral(link, 1e18);
    }

    function test_depositWorks() public {
        uint256 amountToDeposit = 50e18;
        uint256 userBalanceBefore = ERC20Mock(config.weth).balanceOf(user);
        uint256 dusdEngineBalanceBefore = ERC20Mock(config.weth).balanceOf(address(dusdEngine));
        uint256 userColletralbalanceBefore = dusdEngine.getCollateralBalanceOfUser(user, config.weth);
        vm.startPrank(user);
        ERC20Mock(config.weth).approve(address(dusdEngine), amountToDeposit);
        vm.expectEmit(true, true, false, true, address(dusdEngine));
        emit DUSDEngine.DUSDEngine__UserHasColletralize(user, config.weth, amountToDeposit);
        dusdEngine.depositCollateral(config.weth, amountToDeposit);
        vm.stopPrank();

        uint256 userBalanceAfter = ERC20Mock(config.weth).balanceOf(user);
        uint256 dusdEngineBalanceAfter = ERC20Mock(config.weth).balanceOf(address(dusdEngine));
        uint256 userColletralbalanceAfter = dusdEngine.getCollateralBalanceOfUser(user, config.weth);

        assertEq(userBalanceAfter, userBalanceBefore - amountToDeposit);
        assertEq(dusdEngineBalanceAfter, dusdEngineBalanceBefore + amountToDeposit);
        assertEq(userColletralbalanceAfter, userColletralbalanceBefore + amountToDeposit);
    }

    function test_maxMint() public {
        uint256 amountToDeposit = 10e18;
        vm.startPrank(user);
        ERC20Mock(config.weth).approve(address(dusdEngine), amountToDeposit);
        dusdEngine.depositCollateral(config.weth, amountToDeposit);
        vm.stopPrank();

        uint256 tokentotalPrice = dusdEngine.calculateTokenFeed(config.weth, amountToDeposit);
        uint256 maxDUSDToAmount =
            (tokentotalPrice * dusdEngine.LIQUIDATION_THRESHOLD()) / dusdEngine.LIQUIDATION_PRECISION();
        vm.prank(user);
        dusdEngine.mintDusd(maxDUSDToAmount);

        uint256 userHealthFactor = dusdEngine.getHealthFactor(user);
        assertEq(userHealthFactor, dusdEngine.MIN_HEALTH_FACTOR());
        vm.prank(user);
        vm.expectRevert(DUSDEngine.DUSDEngine__UserHealthFactorNotOk.selector);
        dusdEngine.mintDusd(1);
    }

    function test_maxMinWithMultipleCollaterlas() public {
        uint256 amountToDepositWeth = 10e18;
        uint256 amountToDepositBTC = 2e18;
        vm.startPrank(user);
        ERC20Mock(config.weth).approve(address(dusdEngine), amountToDepositWeth);
        ERC20Mock(config.btc).approve(address(dusdEngine), amountToDepositBTC);
        dusdEngine.depositCollateral(config.weth, amountToDepositWeth);
        dusdEngine.depositCollateral(config.btc, amountToDepositBTC);
        vm.stopPrank();

        uint256 wethPrice = dusdEngine.calculateTokenFeed(config.weth, amountToDepositWeth);
        uint256 btcPrice = dusdEngine.calculateTokenFeed(config.btc, amountToDepositBTC);
        uint256 totalColletralPrice = wethPrice + btcPrice;

        uint256 maxMint =
            (totalColletralPrice * dusdEngine.LIQUIDATION_THRESHOLD()) / dusdEngine.LIQUIDATION_PRECISION();
        vm.prank(user);
        dusdEngine.mintDusd(maxMint);
        uint256 userHealthFactor = dusdEngine.getHealthFactor(user);
        assertEq(userHealthFactor, dusdEngine.MIN_HEALTH_FACTOR());
        vm.prank(user);
        vm.expectRevert(DUSDEngine.DUSDEngine__UserHealthFactorNotOk.selector);
        dusdEngine.mintDusd(1);
    }

    function test_burnDusd() public {
        uint256 amountToDeposit = 10e18;
        vm.startPrank(user);
        ERC20Mock(config.weth).approve(address(dusdEngine), amountToDeposit);
        dusdEngine.depositCollateral(config.weth, amountToDeposit);
        vm.stopPrank();

        uint256 tokentotalPrice = dusdEngine.calculateTokenFeed(config.weth, amountToDeposit);
        uint256 maxDUSDToAmount =
            (tokentotalPrice * dusdEngine.LIQUIDATION_THRESHOLD()) / dusdEngine.LIQUIDATION_PRECISION();

        uint256 userBalanceBeforeMint = ERC20Mock(address(dusd)).balanceOf(user);
        uint256 dusdEngineBalanceBeforeMint = ERC20Mock(address(dusd)).balanceOf(address(dusdEngine));
        uint256 totalSupplyBeforeMint = dusd.totalSupply();

        uint256 amountDUSD;
        amountDUSD = maxDUSDToAmount - 20;
        vm.prank(user);
        dusdEngine.mintDusd(amountDUSD);

        uint256 totalSupplyAfterMint = dusd.totalSupply();
        uint256 userBalanceAftereMint = ERC20Mock(address(dusd)).balanceOf(user);
        uint256 dusdEngineBalanceAftereMint = ERC20Mock(address(dusd)).balanceOf(address(dusdEngine));

        assertEq(userBalanceAftereMint, userBalanceBeforeMint + amountDUSD);
        assertEq(dusdEngineBalanceAftereMint, dusdEngineBalanceBeforeMint);
        assertEq(totalSupplyAfterMint, totalSupplyBeforeMint + amountDUSD);

        uint256 amountToBurn = amountDUSD - 20;
        vm.startPrank(user);
        ERC20Mock(address(dusd)).approve(address(dusdEngine), amountToBurn);
        dusdEngine.burnDUSD(amountToBurn);

        uint256 totalSupplyAfterBurn = dusd.totalSupply();
        uint256 userBalanceAftereBurn = ERC20Mock(address(dusd)).balanceOf(user);
        uint256 dusdEngineBalanceAftereBurn = ERC20Mock(address(dusd)).balanceOf(address(dusdEngine));

        assertEq(userBalanceAftereBurn, userBalanceAftereMint - amountToBurn);
        assertEq(dusdEngineBalanceAftereBurn, dusdEngineBalanceAftereMint);
        assertEq(totalSupplyAfterBurn, totalSupplyAfterMint - amountToBurn);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _wethPrice() internal view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(config.weethFeed).latestRoundData();
        return uint256(price);
    }

    // USD value (18 decimals) of a WETH amount at a given 8-decimal feed price
    function _usdValue(uint256 wethAmount, uint256 price) internal pure returns (uint256) {
        return (wethAmount * price) / 1e8;
    }

    function _maxMintFor(uint256 collateralUsd) internal view returns (uint256) {
        return (collateralUsd * dusdEngine.LIQUIDATION_THRESHOLD()) / dusdEngine.LIQUIDATION_PRECISION();
    }

    function _depositAndMint(address who, uint256 wethAmount, uint256 dusdAmount) internal {
        vm.startPrank(who);
        ERC20Mock(config.weth).approve(address(dusdEngine), wethAmount);
        dusdEngine.depositCollateral(config.weth, wethAmount);
        dusdEngine.mintDusd(dusdAmount);
        vm.stopPrank();
    }

    // Test 6 position: 10 WETH deposited, minted up to health factor 1e18
    function _openMaxMintPosition() internal returns (uint256 collateral, uint256 debt) {
        collateral = 10e18;
        debt = _maxMintFor(_usdValue(collateral, _wethPrice()));
        _depositAndMint(user, collateral, debt);
    }

    // Test 12 scenario: ETH drops by 25% (from $2,000 to $1,500 with the default mock)
    function _crashEthPrice() internal returns (uint256 newPrice) {
        newPrice = (_wethPrice() * 3) / 4;
        MockV3Aggregator(config.weethFeed).updateAnswer(int256(newPrice));
    }

    /*//////////////////////////////////////////////////////////////
                                REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_redeemCollateralBreakingHealthFactorReverts() public {
        _openMaxMintPosition();

        // Health factor is exactly 1e18, so removing even 1 wei of collateral breaks it
        vm.prank(user);
        vm.expectRevert(DUSDEngine.DUSDEngine__UserHealthFactorNotOk.selector);
        dusdEngine.redeemCollateral(config.weth, 1);
    }

    function test_redeemCollateralForDusd() public {
        uint256 collateral = 10e18;
        // Half of the max mint (5,000 DUSD at $2,000)
        uint256 debt = _maxMintFor(_usdValue(collateral, _wethPrice())) / 2;
        _depositAndMint(user, collateral, debt);
        uint256 supplyBefore = dusd.totalSupply();

        vm.startPrank(user);
        dusd.approve(address(dusdEngine), debt);
        dusdEngine.redeemCollateralForDusd(config.weth, collateral, debt);
        vm.stopPrank();

        (uint256 debtAfter, uint256 collateralUsdAfter) = dusdEngine.getAccountInformation(user);
        assertEq(debtAfter, 0);
        assertEq(collateralUsdAfter, 0);
        assertEq(dusdEngine.getCollateralBalanceOfUser(user, config.weth), 0);
        assertEq(ERC20Mock(config.weth).balanceOf(user), STARTING_BALANCE);
        assertEq(dusd.balanceOf(user), 0);
        assertEq(dusd.totalSupply(), supplyBefore - debt);
    }

    /*//////////////////////////////////////////////////////////////
                             HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/

    function test_healthFactorWithNoDebtIsMax() public {
        assertEq(dusdEngine.getHealthFactor(user), type(uint256).max);

        // Still max with collateral but no debt
        vm.startPrank(user);
        ERC20Mock(config.weth).approve(address(dusdEngine), 10e18);
        dusdEngine.depositCollateral(config.weth, 10e18);
        vm.stopPrank();
        assertEq(dusdEngine.getHealthFactor(user), type(uint256).max);
    }

    function test_healthFactorAfterPriceDrop() public {
        (uint256 collateral, uint256 debt) = _openMaxMintPosition();
        uint256 newPrice = _crashEthPrice();

        // $7,500 adjusted collateral / 10,000 debt = 0.75 with the default mock
        uint256 adjustedCollateral = _maxMintFor(_usdValue(collateral, newPrice));
        uint256 expectedHealthFactor = (adjustedCollateral * 1e18) / debt;

        assertEq(dusdEngine.getHealthFactor(user), expectedHealthFactor);
        assertLt(dusdEngine.getHealthFactor(user), dusdEngine.MIN_HEALTH_FACTOR());
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function test_liquidateHealthyUserReverts() public {
        // Health factor exactly 1e18 is still healthy
        (, uint256 debt) = _openMaxMintPosition();

        address liquidator = makeAddr("liquidator");
        vm.prank(liquidator);
        vm.expectRevert(DUSDEngine.DUSDEngine__UserHealthFactorIsOk.selector);
        dusdEngine.liquidate(user, config.weth, debt);
    }

    function test_liquidate() public {
        (uint256 userCollateral, uint256 userDebt) = _openMaxMintPosition();
        uint256 newPrice = _crashEthPrice();
        uint256 healthFactorBefore = dusdEngine.getHealthFactor(user);

        // Liquidator: 20 WETH deposited, covers 30% of the user's debt (3,000 DUSD by default)
        address liquidator = makeAddr("liquidator");
        uint256 liquidatorCollateral = 20e18;
        uint256 debtToCover = (userDebt * 3) / 10;
        ERC20Mock(config.weth).mint(liquidator, liquidatorCollateral);
        _depositAndMint(liquidator, liquidatorCollateral, debtToCover);
        uint256 supplyBefore = dusd.totalSupply();

        vm.startPrank(liquidator);
        dusd.approve(address(dusdEngine), debtToCover);
        dusdEngine.liquidate(user, config.weth, debtToCover);
        vm.stopPrank();

        // 3,000 / 1,500 = 2 WETH, plus a 10% bonus = 2.2 WETH by default
        uint256 wethForDebt = (debtToCover * 1e8) / newPrice;
        uint256 expectedReward = wethForDebt + (wethForDebt * dusdEngine.FEE()) / dusdEngine.LIQUIDATION_PRECISION();

        // Liquidator: deposited all their WETH, so their wallet holds just the reward
        assertEq(ERC20Mock(config.weth).balanceOf(liquidator), expectedReward);
        assertEq(dusd.balanceOf(liquidator), 0);

        // The covered DUSD was burned
        assertEq(dusd.totalSupply(), supplyBefore - debtToCover);

        _assertUserAfterLiquidation(
            userCollateral - expectedReward, userDebt - debtToCover, newPrice, healthFactorBefore
        );
    }

    function _assertUserAfterLiquidation(
        uint256 expectedCollateral,
        uint256 expectedDebt,
        uint256 price,
        uint256 healthFactorBefore
    ) internal view {
        // User: 7.8 WETH and 7,000 debt remain by default
        (uint256 debtAfter, uint256 collateralUsdAfter) = dusdEngine.getAccountInformation(user);
        assertEq(dusdEngine.getCollateralBalanceOfUser(user, config.weth), expectedCollateral);
        assertEq(debtAfter, expectedDebt);
        assertEq(collateralUsdAfter, _usdValue(expectedCollateral, price));

        // About 0.836 by default: improved, but still below 1
        uint256 expectedHealthFactor = (_maxMintFor(_usdValue(expectedCollateral, price)) * 1e18) / expectedDebt;
        assertEq(dusdEngine.getHealthFactor(user), expectedHealthFactor);
        assertGt(dusdEngine.getHealthFactor(user), healthFactorBefore);
    }
}
