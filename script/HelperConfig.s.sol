// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mock/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title HelperConfig
 * @author 
 * @notice 
 * Chainlink Data Feed Addresses can be found: 
 *  https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1
 * 
 * Wrapped Ether (WETH)
 *  https://sepolia.etherscan.io/address/0xdd13e55209fd76afe204dbda4007c227904f0a81#code
 * Wrapped Bitcoin (WBTC)
 *  https://sepolia.etherscan.io/address/0x8f3cf7ad23cd3cadbd9735aff958023239c6a063
 * 
 * On Sepolia Testnet
 * ETH / USD: 0x694AA1769357215DE4FAC081bf1f309aDC325306
 * BTC / USD: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43
 * WETH: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81
 * WBTC: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063
 * 
 */

contract HelperConfig is Script {
    struct NetworkConfig {
        address wETHPriceFeedInUSD;
        address wBTCPriceFeedInUSD;
        address wETH;
        address wBTC;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_PRICE_USD = 2000e8;
    int256 public constant BTC_PRICE_USD = 1000e8;
    uint256 public constant ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaNetworkConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilNetworkConfig();
        }
    }

    function getSepoliaNetworkConfig() public view returns(NetworkConfig memory) {
        return NetworkConfig({
            wETHPriceFeedInUSD: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wBTCPriceFeedInUSD: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            wETH: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wBTC: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilNetworkConfig() public returns(NetworkConfig memory) {
        if(activeNetworkConfig.wETHPriceFeedInUSD != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        // ETH
        MockV3Aggregator ETCPriceFeedInUSD = new MockV3Aggregator(
            DECIMALS,
            ETH_PRICE_USD
        );
        ERC20Mock wETCMock = new ERC20Mock();
        wETCMock.mint(msg.sender, 1000e8);

        // BTC
        MockV3Aggregator BTCPriceFeedInUSD = new MockV3Aggregator(
            DECIMALS,
            BTC_PRICE_USD
        );
        ERC20Mock wBTCMock = new ERC20Mock();
        wBTCMock.mint(msg.sender, 1000e8);
        vm.stopBroadcast();

        return NetworkConfig({
            wETHPriceFeedInUSD: address(ETCPriceFeedInUSD),
            wBTCPriceFeedInUSD: address(BTCPriceFeedInUSD),
            wETH: address(wETCMock),
            wBTC: address(wBTCMock),
            deployerKey: ANVIL_PRIVATE_KEY
        });
    }

}