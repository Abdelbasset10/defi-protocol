// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DUSD (Decentralized USD)
 * @author Abdelbasset10
 * @notice An over-collateralized stablecoin pegged to 1 USD.
 * @dev This contract is only the ERC20 token. All minting and burning is controlled by its owner,
 *      which is expected to be the `DUSDEngine`. The engine enforces the collateral rules.
 *
 *      - Collateral: exogenous (WETH, WBTC)
 *      - Stability mechanism: algorithmic (over-collateralization + liquidations)
 *      - Peg: 1 DUSD = 1 USD
 */
contract DUSD is ERC20Burnable, Ownable {
    /// @notice Thrown when a mint or burn amount is zero.
    error DUSD__AmountMustBeGraterThanZero();
    /// @notice Thrown when minting to the zero address.
    error DUSD__AddressCannotBeZero();
    /// @notice Thrown when burning more than the owner's balance.
    error DUSD__InsufficiantBalance();

    /// @notice Emitted when new DUSD is minted.
    /// @param user The account that called `mint` (the owner).
    /// @param amount The amount of DUSD minted.
    event DUSD__UserHasMinted(address indexed user, uint256 amount);

    /// @notice Emitted when DUSD is burned.
    /// @param user The account whose DUSD was burned (the owner).
    /// @param amount The amount of DUSD burned.
    event DUSD__UserHasBurned(address indexed user, uint256 amount);

    /// @notice The token name.
    string public constant ERC_NAME = "Decentralized USD";
    /// @notice The token symbol.
    string public constant ERC_SYMBOL = "DUSD";

    /// @notice Deploys the token and makes the deployer its owner.
    /// @dev Ownership should be transferred to the `DUSDEngine` right after deployment.
    constructor() ERC20(ERC_NAME, ERC_SYMBOL) Ownable(msg.sender) {}

    /**
     * @notice Mints new DUSD to an account.
     * @dev Only callable by the owner (the engine).
     * @param _to The account that receives the DUSD.
     * @param amount The amount of DUSD to mint (18 decimals).
     */
    function mint(address _to, uint256 amount) public onlyOwner {
        if (_to == address(0)) {
            revert DUSD__AddressCannotBeZero();
        }

        if (amount == 0) {
            revert DUSD__AmountMustBeGraterThanZero();
        }

        _mint(_to, amount);
        emit DUSD__UserHasMinted(msg.sender, amount);
    }

    /**
     * @notice Burns DUSD from the owner's own balance.
     * @dev Only callable by the owner (the engine). The engine first pulls the user's DUSD to itself,
     *      then burns it here.
     * @param amount The amount of DUSD to burn (18 decimals).
     */
    function burn(uint256 amount) public override onlyOwner {
        if (amount == 0) {
            revert DUSD__AmountMustBeGraterThanZero();
        }

        if (balanceOf(msg.sender) < amount) {
            revert DUSD__InsufficiantBalance();
        }

        super.burn(amount);
        emit DUSD__UserHasBurned(msg.sender, amount);
    }
}
