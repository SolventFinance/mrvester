// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "./MrVester.sol";
import "./VestingInstance.sol";

contract MrVestersMarket is AccessControl {
    MrVester public vesting_factory;
    
    constructor( address _vesting_factory ) {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender()); // set admin as the owner
        vesting_factory = MrVester( _vesting_factory );
    }
}

