// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {DUSDEngine} from "../../src/DUSDEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title HandlerInvariant
 * @author Abdelbasset10
 * @notice Handler for the invariant tests. The fuzzer calls these functions instead of calling the
 *         engine directly, so every call is made by a known user with valid amounts.
 * @dev Calls that cannot succeed (nothing to deposit, burn or redeem, or an amount that would break
 *      the health factor) are skipped, so the tests can run with `fail_on_revert = true`.
 */
contract HandlerInvariant is Test {
    /// @notice The engine under test.
    address public immutable i_dusdEngine;
    /// @notice The DUSD token.
    address public immutable i_dusd;

    /// @dev The users the fuzzer acts as.
    address[] users;

    /**
     * @param dusdEngine The engine under test.
     * @param _dusd The DUSD token.
     * @param _users The users the fuzzer acts as. They must already hold collateral tokens.
     */
    constructor(address dusdEngine,address _dusd, address[] memory _users) {
        i_dusdEngine = dusdEngine;
        users = _users;
        i_dusd = _dusd;
    }

    /**
     * @notice Deposits a random amount of a random collateral token for a random user.
     * @param tokenSeed Picks the token and the user.
     * @param amount Bounded to the user's token balance.
     */
    function depositColletral(uint256 tokenSeed, uint256 amount) public {
        address[] memory allowedTokens = DUSDEngine(i_dusdEngine).getCollateralTokens();
        uint256 tokensNumber = allowedTokens.length;
        address token = allowedTokens[tokenSeed % tokensNumber];
        uint256 usersLength = users.length;
        address user = users[tokenSeed % usersLength];
        uint256 balance = ERC20Mock(token).balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.startPrank(user);
        ERC20Mock(token).approve(i_dusdEngine, amount);
        DUSDEngine(i_dusdEngine).depositCollateral(token, amount);
        vm.stopPrank();
    }

    /**
     * @notice Mints DUSD for a random user, up to what their collateral allows.
     * @param amount Picks the user, then is bounded to the most they can mint.
     */
    function mintDUSD(uint256 amount) public {
        uint256 usersLength = users.length;
        address user = users[amount % usersLength];
        // Most the user can still mint while keeping health factor >= 1
        (uint256 debt, uint256 collateralUsd) = DUSDEngine(i_dusdEngine).getAccountInformation(user);
        uint256 maxDebt = (collateralUsd * DUSDEngine(i_dusdEngine).LIQUIDATION_THRESHOLD())
            / DUSDEngine(i_dusdEngine).LIQUIDATION_PRECISION();
        if (maxDebt <= debt) return;
        amount = bound(amount, 1, maxDebt - debt);
        vm.prank(user);
        DUSDEngine(i_dusdEngine).mintDusd(amount);
    }

    /**
     * @notice Redeems collateral for a random user, without breaking their health factor.
     * @param tokenSeed Picks the token and the user.
     * @param amount Bounded to the most the user can withdraw.
     */
    function redeemCollateral(uint256 tokenSeed, uint256 amount) public {
        address[] memory allowedTokens = DUSDEngine(i_dusdEngine).getCollateralTokens();
        uint256 tokensNumber = allowedTokens.length;
        address token = allowedTokens[tokenSeed % tokensNumber];
        uint256 usersLength = users.length;
        address user = users[tokenSeed % usersLength];
        uint256 maxRedeem = _maxRedeemable(user, token);
        if (maxRedeem == 0) return;
        amount = bound(amount, 1, maxRedeem);
        vm.prank(user);
        DUSDEngine(i_dusdEngine).redeemCollateral(token, amount);
    }

    /// @dev Returns the most of `token` that `user` can withdraw while keeping a health factor >= 1.
    function _maxRedeemable(address user, address token) internal view returns (uint256) {
        DUSDEngine engine = DUSDEngine(i_dusdEngine);
        uint256 balance = engine.getCollateralBalanceOfUser(user, token);
        (uint256 debt, uint256 collateralUsd) = engine.getAccountInformation(user);
        if (debt == 0) return balance;

        // Collateral (in USD) that must stay locked to back the debt
        uint256 requiredUsd = (debt * engine.LIQUIDATION_PRECISION()) / engine.LIQUIDATION_THRESHOLD();
        if (collateralUsd <= requiredUsd) return 0;
        uint256 excessTokens = engine.getTokenAmountFromUsd(token, collateralUsd - requiredUsd);
        // Leave 1 wei of margin for rounding in the USD conversions
        if (excessTokens <= 1) return 0;
        excessTokens -= 1;
        return excessTokens < balance ? excessTokens : balance;
    }

    /**
     * @notice Burns DUSD for a random user, up to their debt.
     * @param amount Picks the user, then is bounded to their debt.
     */
    function burnDUSD(uint256 amount) public {
        uint256 usersLength = users.length;
        address user = users[amount % usersLength];
        uint256 debt = DUSDEngine(i_dusdEngine).getUserDUSD(user);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        vm.startPrank(user);
        ERC20Mock(i_dusd).approve(i_dusdEngine, amount);
        DUSDEngine(i_dusdEngine).burnDUSD(amount);
        vm.stopPrank();
    }

    /// @notice Deposits collateral, then mints DUSD.
    function depositColletralAndMintDUSD(uint256 tokenSeed, uint256 amount,uint256 amountDUSD) public {
        depositColletral(tokenSeed,amount);
        mintDUSD(amountDUSD);
    }

    /// @notice Burns DUSD, then redeems collateral.
    function redeemCollateralAndBurnDUSD(uint256 tokenSeed, uint256 amount,uint256 amountToBurn) public {
        burnDUSD(amountToBurn);
        redeemCollateral(tokenSeed, amount);
    }

}
