// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address wETH;
//     address wBTC;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dscEngine, config) = deployer.run();
//         (,, wETH, wBTC,) = config.activeNetworkConfig();
//         targetContract(address(dscEngine));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
//         //get the value of all the collateral in the protocol
//         //compare it to all the debt (dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWETHDeposited = IERC20(wETH).balanceOf(address(dscEngine));
//         uint256 totalBTCDeposited = IERC20(wBTC).balanceOf(address(dscEngine));

//         uint256 wETHValue = dscEngine.getTokenValueInUSD(wETH, totalWETHDeposited);
//         uint256 wBTCValue = dscEngine.getTokenValueInUSD(wBTC, totalBTCDeposited);

//         console.log("weth: ", wETH);
//         console.log("wbtc: ", wBTC);
//         console.log("total supply: ", totalSupply);

//         assert(wETHValue + wBTCValue >= totalSupply);
//     }
// }
