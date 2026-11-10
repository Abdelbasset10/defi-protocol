// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title AggregatorV3Interface
 * @notice Minimal interface for Chainlink price feeds, with only the functions the engine uses.
 */
interface AggregatorV3Interface {
    /// @notice Returns the number of decimals in the price (8 for Chainlink USD pairs).
    function decimals() external view returns (uint8);

    /**
     * @notice Returns the latest price round.
     * @return roundId The round ID.
     * @return answer The price.
     * @return startedAt When the round started.
     * @return updatedAt When the price was last updated.
     * @return answeredInRound The round in which the answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
