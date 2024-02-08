# A Decentralized Stable Coin (DSC) with Solidity

[![Static Badge](https://img.shields.io/badge/0.8.20-blue?logo=solidity&label=%7C%20Solidity)](https://docs.soliditylang.org/en/v0.8.20/)


[![GitHub Tag](https://img.shields.io/github/v/tag/ArnaudSene/solidity-foundry-dsc)
](https://github.com/ArnaudSene/solidity-foundry-dsc/actions/workflows/test.yml/releases/latest) 

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/ArnaudSene/solidity-foundry-dsc/test.yml?logo=githubactions&logoColor=white&label=%7C%20build)](https://github.com/ArnaudSene/solidity-foundry-dsc/actions/workflows/test.yml) 

[![Dynamic JSON Badge]()](https://github.com/ArnaudSene/solidity-foundry-dsc/actions/workflows/test.yml/actions/workflows/01-test.yml) 

---

## Summary

---




1. Relative stability: Anchored or Pegged -> should be always worth $1.00
   1. Chainlink price feed
   2. Set a function to exchange ETH & BTC -> $$$
2. Stability mechanism (minting): Algorithmic (Decentralized)
   1. People can only mint the stablecoin with enough collateral (coded)
3. Collateral: Exogenous (Crypto)
   1. wETH 
      1. wrapped ETH
      2. wETH is the ERC-20 tradable version of ETH
      3. wETH is pegged to the price of ETH at a 1:1 ratio
   2. wBTC
      1. wrapped BTC
      2. wBTC token was built using Ethereum’s ERC-20 token standard to provide bitcoin liquidity
      3. wBTC is bitcoin that has been converted for use on the Ethereum ecosystem. 
      4. wBTC is an Ethereum token that’s backed one-to-one by bitcoin (BTC), which means that one wBTC is always equal to one bitcoin.



## Notes
###### Contract deployment 

1. Create a DSC instance 
   1. ERC20 burnable (mint, burn functions)
2. Create DSC Engine instance with
   1. wETH and wBTC token addresses
   2. wETC and wBTC prices feeds in USD (provided by Chainlink)
   3. DSC address
3. Transfer DCS's ownership to DCS Engine address

###### Deposit and Mint stable coin
1. User deposit a collateral
   1. collateral address (wETH or wBTC)
   2. amount of the collateral to deposit (> 0)
2. Mint stable coin
   1. amount of stable coin to mint
   2. verify that the health factor is not broken
      1. get the total DCS minted for the user TotMint
      2. get the collateral value in USD Colusd
      3. health factor = ( ( (Colusd * Threshold) / 100 ) * 1e18 ) / TotMint
         1. with Threshol = 50
         2. health factor must be > 1


###### Redeem and Burn stable coin
1. User redeems a collateral
   1. collateral address (wETH or wBTC)
   2. amount of the collateral to redeem
2. Burn stable coin
   1. amount of stable coin to burn

## Resources
[AAVE - Health Factor](https://docs.aave.com/risk/asset-risk/risk-parameters#health-factor)
