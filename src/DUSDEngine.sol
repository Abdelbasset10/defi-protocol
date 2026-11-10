// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {DUSD} from "./DUSD.sol";

/**
 * @title DUSDEngine
 * @author Abdelbasset10
 * @notice The core of the DUSD system. Users deposit collateral (WETH, WBTC), mint DUSD against it,
 *         burn DUSD to repay their debt and redeem their collateral. Unhealthy positions can be
 *         liquidated by anyone for a 10% bonus.
 * @dev The system must always be over-collateralized: the USD value of all collateral must be
 *      greater than or equal to the total DUSD minted.
 *
 *      Each user must keep a health factor of at least `MIN_HEALTH_FACTOR` (1e18). With a
 *      `LIQUIDATION_THRESHOLD` of 50%, this means every 1 USD of debt needs 2 USD of collateral.
 *
 *      All USD values use 18 decimals. Price feeds are assumed to return prices with 8 decimals
 *      and collateral tokens are assumed to have 18 decimals.
 */
contract DUSDEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the constructor receives a different number of tokens and price feeds.
    error DUSDEngine__LengthOfTokensAndFeedsAreNotTheSame();
    /// @notice Thrown when a token is not accepted as collateral.
    error DUSDEngine__TokenIsNotAllowed();
    /// @notice Thrown when an amount is zero.
    error DUSDEngine__AmountMustBeGraterThanZero();
    /// @notice Thrown when an ERC20 transfer returns false.
    error DUSDEngine__TransferFailed();
    /// @notice Thrown when an action would leave a user's health factor below `MIN_HEALTH_FACTOR`.
    error DUSDEngine__UserHealthFactorNotOk();
    /// @notice Thrown when redeeming more collateral than the user has deposited.
    error DUSDEngine__InsuffiantBalance();
    /// @notice Thrown when trying to liquidate a user whose health factor is still healthy.
    error DUSDEngine__UserHealthFactorIsOk();
    /// @notice Thrown when a liquidation does not improve the user's health factor.
    error DUSDEngine__UserHealthFactorDidntImproved();
    /// @notice Thrown when burning more DUSD than the user owes.
    error DUSDEngine__AmountExceedsDebt();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits collateral.
    /// @param user The user who deposited.
    /// @param token The collateral token.
    /// @param amount The amount of collateral deposited.
    event DUSDEngine__UserHasColletralize(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a user mints DUSD.
    /// @param user The user who minted.
    /// @param amount The amount of DUSD minted.
    event DUSDEngine__UserMinted(address indexed user, uint256 amount);

    /// @notice Emitted when collateral is redeemed, either by its owner or by a liquidator.
    /// @param exectuer The account that receives the collateral.
    /// @param onBehalfOf The account whose collateral is removed.
    /// @param token The collateral token.
    /// @param amount The amount of collateral redeemed.
    event DUSDEngine__UserRedeemed(
        address indexed exectuer, address indexed onBehalfOf, address indexed token, uint256 amount
    );

    /// @notice Emitted when DUSD debt is repaid and burned, either by the user or by a liquidator.
    /// @param executer The account that pays the DUSD.
    /// @param oneBehlafOf The account whose debt is reduced.
    /// @param amount The amount of DUSD burned.
    event DUSDEngine__UserBurned(address indexed executer, address indexed oneBehlafOf, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                           CONSTANTS & STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Scales an 8-decimal Chainlink price up to 18 decimals.
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    /// @notice Precision used for USD values and the health factor (18 decimals).
    uint256 public constant PRECISION = 1e18;
    /// @notice The lowest health factor a user can have without being liquidatable (1.0).
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    /// @notice Percentage of collateral value that counts toward backing debt (50% = 200% collateralized).
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    /// @notice Denominator for `LIQUIDATION_THRESHOLD` and `FEE`.
    uint256 public constant LIQUIDATION_PRECISION = 100;
    /// @notice Liquidation bonus paid to liquidators, in percent (10%).
    uint256 public constant FEE = 10;

    /// @dev The DUSD token. This engine must be its owner.
    address private immutable i_dusd;
    /// @dev Collateral token => Chainlink USD price feed. A zero feed means the token is not allowed.
    mapping(address token => address feed) private s_tokenToFeed;
    /// @dev User => collateral token => amount deposited.
    mapping(address user => mapping(address token => uint256 amount)) private s_userToColletrals;
    /// @dev User => DUSD debt (amount minted and not yet burned).
    mapping(address user => uint256 amount) private s_usertoMints;
    /// @dev List of all accepted collateral tokens.
    address[] private s_allowedTokens;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets up the accepted collateral tokens, their price feeds and the DUSD token.
     * @param tokens The collateral token addresses.
     * @param feeds The Chainlink USD price feed for each token, in the same order as `tokens`.
     * @param _dusd The DUSD token address.
     */
    constructor(address[] memory tokens, address[] memory feeds, address _dusd) {
        if (tokens.length != feeds.length) {
            revert DUSDEngine__LengthOfTokensAndFeedsAreNotTheSame();
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            s_tokenToFeed[tokens[i]] = feeds[i];
            s_allowedTokens.push(tokens[i]);
        }
        i_dusd = _dusd;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts if `token` is not an accepted collateral token.
    modifier isAllowedToken(address token) {
        if (s_tokenToFeed[token] == address(0)) {
            revert DUSDEngine__TokenIsNotAllowed();
        }
        _;
    }

    /// @dev Reverts if `amount` is zero.
    modifier isAmountGraterThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DUSDEngine__AmountMustBeGraterThanZero();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           PRICE & HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the USD value of an amount of a collateral token.
     * @param token The collateral token.
     * @param amount The token amount (18 decimals).
     * @return The USD value (18 decimals).
     */
    function calculateTokenFeed(address token, uint256 amount) public view returns (uint256) {
        address tokenFeed = s_tokenToFeed[token];
        (, int256 price,,,) = AggregatorV3Interface(tokenFeed).latestRoundData();
        uint256 totalPrice = (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
        return totalPrice;
    }

    /**
     * @notice Returns a user's health factor.
     * @dev health factor = (collateral value in USD * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION) * 1e18 / debt.
     *      Below `MIN_HEALTH_FACTOR` (1e18), the user can be liquidated.
     * @param user The user to check.
     * @return The health factor (18 decimals), or `type(uint256).max` if the user has no debt.
     */
    function calculateUserHealthFactor(address user) public view returns (uint256) {
        uint256 usersDUSD = s_usertoMints[user];
        uint256 userColletrals;
        for (uint256 i = 0; i < s_allowedTokens.length; i++) {
            userColletrals += calculateTokenFeed(s_allowedTokens[i], s_userToColletrals[user][s_allowedTokens[i]]);
        }

        if (usersDUSD == 0) {
            return type(uint256).max;
        }

        uint256 colletralsTheshold = (userColletrals * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        uint256 healthFactor = (colletralsTheshold * PRECISION) / usersDUSD;
        return healthFactor;
    }

    /// @dev Reverts with `DUSDEngine__UserHealthFactorNotOk` if `user`'s health factor is below the minimum.
    function _revertIfHealthFactorNotOk(address user) private view {
        uint256 healthFactor = calculateUserHealthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DUSDEngine__UserHealthFactorNotOk();
        }
    }

    /**
     * @notice Returns how many collateral tokens a USD amount is worth.
     * @param token The collateral token.
     * @param amount The USD amount (18 decimals).
     * @return The token amount (18 decimals).
     */
    function calculateTokensAmountBasedOnPrice(address token, uint256 amount) public view returns (uint256) {
        address tokenFeed = s_tokenToFeed[token];
        (, int256 price,,,) = AggregatorV3Interface(tokenFeed).latestRoundData();
        uint256 totalTokensAmount = (amount * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
        return totalTokensAmount;
    }

    /*//////////////////////////////////////////////////////////////
                               COLLATERAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Records the deposit for `msg.sender` and pulls the tokens into the engine.
    function _depositCollateral(address token, uint256 amount) private {
        s_userToColletrals[msg.sender][token] += amount;
        emit DUSDEngine__UserHasColletralize(msg.sender, token, amount);
        bool status = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!status) {
            revert DUSDEngine__TransferFailed();
        }
    }

    /**
     * @notice Deposits collateral into the engine.
     * @dev The caller must first approve the engine to spend `amount` of `token`.
     * @param token The collateral token to deposit.
     * @param amount The amount to deposit.
     */
    function depositCollateral(address token, uint256 amount)
        public
        isAllowedToken(token)
        isAmountGraterThanZero(amount)
        nonReentrant
    {
        _depositCollateral(token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    /// @dev Adds `amount` to `msg.sender`'s debt, checks the health factor, then mints the DUSD.
    function _mintDusd(uint256 amount) private {
        s_usertoMints[msg.sender] += amount;
        emit DUSDEngine__UserMinted(msg.sender, amount);
        _revertIfHealthFactorNotOk(msg.sender);
        DUSD(i_dusd).mint(msg.sender, amount);
    }

    /**
     * @notice Mints DUSD against the caller's deposited collateral.
     * @dev Reverts if the caller's health factor would drop below `MIN_HEALTH_FACTOR`.
     * @param amount The amount of DUSD to mint (18 decimals).
     */
    function mintDusd(uint256 amount) public isAmountGraterThanZero(amount) nonReentrant {
        _mintDusd(amount);
    }

    /**
     * @notice Deposits collateral and mints DUSD in one transaction.
     * @dev The caller must first approve the engine to spend `tokenAmount` of `token`.
     * @param token The collateral token to deposit.
     * @param tokenAmount The amount of collateral to deposit.
     * @param mintAmount The amount of DUSD to mint.
     */
    function depositCollateralAndMintDusd(address token, uint256 tokenAmount, uint256 mintAmount)
        public
        isAllowedToken(token)
        isAmountGraterThanZero(tokenAmount)
        isAmountGraterThanZero(mintAmount)
        nonReentrant
    {
        _depositCollateral(token, tokenAmount);
        _mintDusd(mintAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                 REDEEM
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Removes collateral from `onBehalfOf` and sends it to `executer`.
     * @param executer The account that receives the collateral.
     * @param onBehalfOf The account whose collateral is removed.
     * @param token The collateral token.
     * @param amount The amount to redeem.
     * @param doWeCheckRevert Whether to check `onBehalfOf`'s health factor. Liquidations skip this
     *        because the user is already unhealthy; they check that the health factor improved instead.
     */
    function _redeemCollateral(
        address executer,
        address onBehalfOf,
        address token,
        uint256 amount,
        bool doWeCheckRevert
    ) private {
        if (s_userToColletrals[onBehalfOf][token] < amount) {
            revert DUSDEngine__InsuffiantBalance();
        }
        s_userToColletrals[onBehalfOf][token] -= amount;
        emit DUSDEngine__UserRedeemed(executer, onBehalfOf, token, amount);
        if (doWeCheckRevert) {
            _revertIfHealthFactorNotOk(onBehalfOf);
        }
        bool status = IERC20(token).transfer(executer, amount);
        if (!status) {
            revert DUSDEngine__TransferFailed();
        }
    }

    /**
     * @notice Withdraws deposited collateral.
     * @dev Reverts if the caller's health factor would drop below `MIN_HEALTH_FACTOR`.
     * @param token The collateral token to withdraw.
     * @param amount The amount to withdraw.
     */
    function redeemCollateral(address token, uint256 amount)
        public
        isAllowedToken(token)
        isAmountGraterThanZero(amount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, token, amount, true);
    }

    /*//////////////////////////////////////////////////////////////
                                  BURN
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Reduces `onBehalfOf`'s debt, pulls the DUSD from `executer` and burns it.
     * @param executer The account that pays the DUSD. Must have approved the engine.
     * @param onBehalfOf The account whose debt is reduced.
     * @param amount The amount of DUSD to burn.
     */
    function _brunDUSD(address executer, address onBehalfOf, uint256 amount) private {
        if (s_usertoMints[onBehalfOf] < amount) {
            revert DUSDEngine__AmountExceedsDebt();
        }
        s_usertoMints[onBehalfOf] -= amount;
        emit DUSDEngine__UserBurned(executer, onBehalfOf, amount);
        bool status = IERC20(i_dusd).transferFrom(executer, address(this), amount);
        if (!status) {
            revert DUSDEngine__TransferFailed();
        }
        DUSD(i_dusd).burn(amount);
    }

    /**
     * @notice Repays DUSD debt by burning the caller's DUSD.
     * @dev The caller must first approve the engine to spend `amount` of DUSD.
     * @param amount The amount of DUSD to burn.
     */
    function burnDUSD(uint256 amount) public isAmountGraterThanZero(amount) nonReentrant {
        _brunDUSD(msg.sender, msg.sender, amount);
    }

    /**
     * @notice Burns DUSD and withdraws collateral in one transaction.
     * @dev The DUSD is burned first, so the health factor is checked after the debt is reduced.
     *      The caller must first approve the engine to spend `dusdAmount` of DUSD.
     * @param token The collateral token to withdraw.
     * @param tokenAmount The amount of collateral to withdraw.
     * @param dusdAmount The amount of DUSD to burn.
     */
    function redeemCollateralForDusd(address token, uint256 tokenAmount, uint256 dusdAmount)
        public
        isAllowedToken(token)
        isAmountGraterThanZero(tokenAmount)
        isAmountGraterThanZero(dusdAmount)
        nonReentrant
    {
        _brunDUSD(msg.sender, msg.sender, dusdAmount);
        _redeemCollateral(msg.sender, msg.sender, token, tokenAmount, true);
    }

    /*//////////////////////////////////////////////////////////////
                               LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Liquidates part of an unhealthy position. The caller repays some of the user's DUSD
     *         debt and receives the same value in collateral plus a 10% bonus.
     * @dev Example: covering 3,000 DUSD when ETH is $1,500 pays out 2 WETH + 0.2 WETH bonus.
     *      If the user does not have enough collateral to pay the full bonus, the liquidator gets
     *      all of the user's collateral in that token.
     *
     *      Reverts if the user is healthy, if the user's health factor does not improve, or if the
     *      liquidator's own health factor ends up below the minimum.
     *
     *      The caller must first approve the engine to spend `amountToLiquidate` of DUSD.
     * @param user The unhealthy user to liquidate.
     * @param tokenColletral The collateral token to receive.
     * @param amountToLiquidate The amount of the user's DUSD debt to cover.
     */
    function liquidate(address user, address tokenColletral, uint256 amountToLiquidate)
        public
        isAllowedToken(tokenColletral)
        isAmountGraterThanZero(amountToLiquidate)
        nonReentrant
    {
        uint256 userHealthFactorBefore = calculateUserHealthFactor(user);
        if (userHealthFactorBefore >= MIN_HEALTH_FACTOR) {
            revert DUSDEngine__UserHealthFactorIsOk();
        }
        uint256 colletralsAmount = calculateTokensAmountBasedOnPrice(tokenColletral, amountToLiquidate);
        uint256 colletralsToRedeem = colletralsAmount + ((colletralsAmount * FEE) / LIQUIDATION_PRECISION);
        uint256 userColletralBalance = s_userToColletrals[user][tokenColletral];
        if (colletralsToRedeem > userColletralBalance) {
            colletralsToRedeem = userColletralBalance;
        }
        _brunDUSD(msg.sender, user, amountToLiquidate);
        _redeemCollateral(msg.sender, user, tokenColletral, colletralsToRedeem, false);
        _revertIfHealthFactorNotOk(msg.sender);
        uint256 userHealthFactorAfer = calculateUserHealthFactor(user);
        if (userHealthFactorAfer <= userHealthFactorBefore) {
            revert DUSDEngine__UserHealthFactorDidntImproved();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns a user's health factor.
     * @param user The user to check.
     * @return The health factor (18 decimals), or `type(uint256).max` if the user has no debt.
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return calculateUserHealthFactor(user);
    }

    /**
     * @notice Returns a user's debt and the USD value of their collateral.
     * @param user The user to check.
     * @return totalDusdMinted The user's DUSD debt.
     * @return collateralValueInUsd The USD value of all the user's collateral (18 decimals).
     */
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDusdMinted, uint256 collateralValueInUsd)
    {
        totalDusdMinted = s_usertoMints[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice Returns the total USD value of a user's collateral across all accepted tokens.
     * @param user The user to check.
     * @return totalCollateralValueInUsd The USD value (18 decimals).
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_allowedTokens.length; i++) {
            address token = s_allowedTokens[i];
            totalCollateralValueInUsd += calculateTokenFeed(token, s_userToColletrals[user][token]);
        }
    }

    /**
     * @notice Returns the USD value of an amount of a collateral token.
     * @param token The collateral token.
     * @param amount The token amount (18 decimals).
     * @return The USD value (18 decimals).
     */
    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return calculateTokenFeed(token, amount);
    }

    /**
     * @notice Returns how many collateral tokens a USD amount is worth.
     * @param token The collateral token.
     * @param usdAmount The USD amount (18 decimals).
     * @return The token amount (18 decimals).
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmount) external view returns (uint256) {
        return calculateTokensAmountBasedOnPrice(token, usdAmount);
    }

    /**
     * @notice Returns how much of a collateral token a user has deposited.
     * @param user The user to check.
     * @param token The collateral token.
     * @return The deposited amount.
     */
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_userToColletrals[user][token];
    }

    /**
     * @notice Returns all accepted collateral tokens.
     * @return The collateral token addresses.
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_allowedTokens;
    }

    /**
     * @notice Returns the price feed used for a collateral token.
     * @param token The collateral token.
     * @return The Chainlink USD price feed address, or the zero address if the token is not accepted.
     */
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_tokenToFeed[token];
    }

    /**
     * @notice Returns a user's DUSD debt.
     * @param user The user to check.
     * @return The amount of DUSD the user has minted and not yet repaid.
     */
    function getUserDUSD(address user)  external view returns(uint256) {
        return s_usertoMints[user];
    }
}
