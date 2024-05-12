//SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test, console} from 'forge-std/Test.sol';
import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {DeployDSC} from '../../script/DeployDSC.s.sol';
import {DSCEngine} from '../../src/DSCEngine.sol';
import {DecentralizedStableCoin} from '../../src/DecentralizedStableCoin.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Handler} from './Handler.t.sol';

contract OpenInvarriantsTest is StdInvariant, Test{

  DeployDSC deployer;
  DSCEngine dsce;
  DecentralizedStableCoin dsc;
  HelperConfig config;
  address weth;
  address wbtc;
  Handler handler;

  function setUp() external {
    deployer = new DeployDSC();
    (dsc, dsce, config) = deployer.run();
    (,,weth, wbtc, ) = config.activeNetworkConfig();
    // targetContract(address(dsce));
    handler = new Handler(dsce, dsc);
    targetContract(address(handler));
    // Don't call redeemcollateral, unless there is collateral to redeem

  }

  function invariant_protocolMustHaveMoreValueThanTotalSupply() public view{
    /// Get the value of all the collateral in the protocol
    // compare it to all the debt(dsc)
    uint256 totaSupply = dsc.totalSupply();
    uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
    uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

    uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
    uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

    console.log("weth value", wethValue);
    console.log("wbtc value", wbtcValue);
    console.log("total supply", totaSupply);
    console.log('Times mint called:', handler.timesMintIsCalled());
    assert(wethValue + wbtcValue >= totaSupply);
  }

  function invarriant_getTestShouldNotRevert() public view {
    dsce.getLiquidationBonus();
    dsce.getPrecision();
  }
}

// Have our invariant aka properties
// What are our invariants?
// 1. The total supply of DSC shhould be less than the total value
// of collateral
// 2. Getter view functions should never revert
