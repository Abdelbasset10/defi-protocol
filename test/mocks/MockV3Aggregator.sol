// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockV3Aggregator
 * @notice A mock Chainlink price feed for local testing. Anyone can set the price.
 */
contract MockV3Aggregator is AggregatorV3Interface {
    /// @notice Number of decimals in the price.
    uint8 public immutable decimals;
    /// @notice The current price.
    int256 public latestAnswer;
    /// @notice When the price was last updated.
    uint256 public latestTimestamp;
    /// @notice The current round ID. Increases on every update.
    uint80 public latestRound;

    /**
     * @param _decimals Number of decimals in the price.
     * @param _initialAnswer The starting price.
     */
    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        updateAnswer(_initialAnswer);
    }

    /**
     * @notice Sets a new price and starts a new round.
     * @param _answer The new price.
     */
    function updateAnswer(int256 _answer) public {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        latestRound++;
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (latestRound, latestAnswer, latestTimestamp, latestTimestamp, latestRound);
    }
}
