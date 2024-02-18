// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";


contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    ERC20Mock wETH;
    ERC20Mock wBTC;
    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;
    address[] public usersWithCollateralDeposited;
    uint256 public timesDepositIsCalled;
    uint256 public timesMintIsCalled;
    uint256 public timesRedeemIsCalled;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        wETH = ERC20Mock(collateralTokens[0]);
        wBTC = ERC20Mock(collateralTokens[1]);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        console.log("--> depositCollateral -----\n");
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);        
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
        timesDepositIsCalled++;
    }

    function mintDSC(uint256 amountDSC, uint256 senderSeed) public {
        console.log("--> mintDSC -----\n");
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        
        address sender = usersWithCollateralDeposited[senderSeed % usersWithCollateralDeposited.length];
        int256 maxDscToMint = int256(dscEngine.getMaxDSCAllowed(sender));

        if(maxDscToMint < 0){
            return;
        }

        amountDSC = bound(amountDSC, 0, uint256(maxDscToMint));
        if (amountDSC == 0){
            return;
        }
        
        vm.startPrank(sender);
        dscEngine.mintDSC(amountDSC);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral, uint256 senderSeed) public {
        console.log("--> redeemCollateral -----\n");
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = usersWithCollateralDeposited[senderSeed % usersWithCollateralDeposited.length];
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        
        uint256 maxCollateral = dscEngine.getCollateralBalanceOfUser(sender, address(collateral));               
        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        
        if (amountCollateral == 0) {
            return;
        }
        
        if (amountCollateral >= maxCollateral) {
            return;
        }

        uint256 amountDSC = dscEngine.getDSCMinted(sender);
        uint256 healthFactor = dscEngine.getCalculatedHealthFactor(amountDSC, maxCollateral - amountCollateral);

        if (healthFactor < dscEngine.getMinHealthFactor()) {
            return;
        }

        vm.startPrank(sender);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        timesRedeemIsCalled++;
    }
   

    //////////////////////// 
    /// private function////
    //////////////////////// 
    
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return wETH;
        }
        return wBTC;
    }
}
