// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/** 
 * @title VestingInstance
 * @dev Implements a vesting instance contract 
 */
contract VestingInstance is AccessControl {
    // roles
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    bytes32 public constant BENEFICIARY_ROLE = keccak256("BENEFICIARY_ROLE");
    
    // constants
    uint public constant MAX_TIME_TO_CLAIM = 208 weeks; //4 years
    uint public constant MAX_VEST_TIME = 520 weeks; //10 years
    uint public constant MAX_DELAY = 208 weeks; //4 years
    uint public constant MAX_CLIFF = 208 weeks; //4 years
    uint public constant MAX_PERIODS = 52 weeks; //1 year in seconds
   
    // addresses
    address public beneficiary;  // the address or contract that recieves vested tokens
    address public return_funds; // used to refund funds that are unclaimed
    address public token_address; // address of token to be vested
    
    // vesting parameters
    uint public delay;   // delay before vesting starts, from time of vesting instance creation
    uint public cliff; // vesting cliff
    uint public period_time; // vesting period time 
    uint public num_periods; // number of vesting periods
    uint public vesting_start_time; // vesting start time (not inclusive of the delay) i.e. when vesting instance was created
    uint public num_to_vest; // number of tokens to vest
    uint public time_to_claim; // max time available to claim vested tokens after all tokens have vested, max is MAX_TIME_TO_CLAIM 

    // calculated paramteres - computed as needed and not guaranteed to be accurate at all times
    uint private vesting_end_time; // calcualted value for when the vesting ends
    uint public claimed; // number of tokens claimed
    uint private claimable; // number of tokens claimable - only calculated occasionally
    
    // contract state variables
    bool public complete; // flag to indicate whether this vesting instance is done vesting
    bool public paused; // flag to indicate whether this vesting instance is done vesting
    uint public paused_timestamp; // when was the contract paused
    uint private pause_delay; // vesting delay
    bool private initialized; // flag to indicate whether this struct has been initialized
    
    /**
     * @dev Constructor 
     */
    constructor( address _beneficiary, 
                 address _return_funds,
                 address _token_address,
                 address _controller,
                 uint _delay,
                 uint _cliff,
                 uint _period_time,
                 uint _num_periods,
                 uint _num_to_vest,
                 uint _time_to_claim ) {
        // set roles
        _setupRole( DEFAULT_ADMIN_ROLE, _msgSender() ); // set admin as the owner
        grantRole( CONTROLLER_ROLE, _controller ); // set the controller
        grantRole( BENEFICIARY_ROLE, _beneficiary ); // set the controller

        // check min/max period time
        require( _period_time > 0, "Period time can't be zero." );
        require( _period_time < MAX_VEST_TIME, "Period time can't be greater than max vesting time." );
        // ensure number of periods > 0, < max
        require( _num_periods > 0, "Number of vesting periods can't be zero." );
        require( _num_periods <= MAX_PERIODS, "Number of vesting periods can't be more than the number of seconds in a year." );
        // ensure delay is less than max delay
        require( _delay <= MAX_DELAY, "Delay can't be this long." );
        // ensure cliff is less than period_time*num_periods and less than max delay
        require( _cliff <= MAX_CLIFF, "Cliff can't be this long." ) ;
        require( _cliff < (_delay + _period_time*_num_periods), "Cliff can't be beyond vesting time." );
        // ensure num to vest is sensible 
        require( _num_to_vest > 0, "Must vest more than zero tokens." );
        // ensure time to claim is less than max
        require( _time_to_claim > 0, "Cannnot allow zero time to claim tokens." );
        require( _time_to_claim <= MAX_TIME_TO_CLAIM, "Time to claim tokens too large." );
        
        beneficiary = _beneficiary; 
        return_funds = _return_funds;
        token_address = _token_address;
        
        delay = _delay;
        cliff = _cliff;
        period_time = _period_time;
        num_periods = _num_periods;
        vesting_start_time = block.timestamp;
        num_to_vest = _num_to_vest;
        time_to_claim = _time_to_claim;
        
        claimed = 0;
        claimable = 0;
        pause_delay = 0;
        
        complete = false;
        paused = false;
        initialized = true;
        
        vesting_end_time = calc_end_timestamp();
        require( vesting_end_time >  block.timestamp, "Vesting period exceeeds allowable limits." );
        claimable = calc_claimable();
        complete = is_complete();
    }
    
    /**
     * @dev The beneficiary can swap another beneficary in their stead.
     */
    function swap_beneficiary( address _new_beneficiary ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require( _new_beneficiary != beneficiary, "Must provide new beneficiary" );
        
        grantRole( BENEFICIARY_ROLE, _new_beneficiary); // make the new beneficiary the beneficiary
        revokeRole( BENEFICIARY_ROLE, beneficiary ); // revoke beneficiary rights from the old beneficiary
        
        beneficiary = _new_beneficiary;
    }
    
    /**
     * @dev Pause the vesting of tokens. Vesting resumes only when resume function is called. 
     * Can only be called by the controller.
    */
    function pause_vesting() public onlyRole(CONTROLLER_ROLE) {
        paused_timestamp = block.timestamp;
        paused = true;
    }
    
    /**
     * @dev Resume vesting tokens.
     * Can only be called by the controller
    */
    function resume_vesting() public onlyRole(CONTROLLER_ROLE)  {
        require( paused, "Can only unpause if the vesting is paused" );
        pause_delay += paused_delay();
        paused = false;
        vesting_end_time = calc_end_timestamp();
    }
    
    /**
     * @dev Claim tokens. 
     * Can only be called by the beneficiary.
    */
    function claim() public onlyRole(BENEFICIARY_ROLE) {
        // check contract state
        require( initialized, "This vesting contract has not been initialized. This should never happen." );
        require( !complete, "This vesting contract has completed vesting." );
    
        ERC20 token = ERC20(token_address);
        claimable = calc_claimable();
        
        require( claimable > 0, "There are no tokens to claim." );
        require( claimed < num_to_vest, "Cannot claim more tokens than available in the vesting contract" );
        
        token.transfer( beneficiary, claimable );
        claimed += claimable;
        claimable = 0;
        
        complete = is_complete(); // check if the vesting is complete
    }
    
    /**
     * @dev Calcualte how many tokens are claimable based on vesting pamareters.
    */
    function calc_claimable() public view returns(uint) {
        // calculate how many tokens the user can claim
        uint vesting_time = calc_vesting_time(); // how much vesting time has passed
        uint periods_passed = vesting_time/period_time; // how many vesting periods have passed
        uint tokens_per_period = num_to_vest/num_periods;
        uint total_claimable = tokens_per_period*periods_passed;
        
        if( periods_passed >= num_periods ) { // if more periods have passed than the total vesting periods then everything is claimable
            total_claimable = num_to_vest;
        }
        
        require( total_claimable >= claimed, "Total claimable must be greater than or equal to that already claimed. This should never happen." );
        
        return (total_claimable - claimed);
    }
    
    /** 
     * @dev Calcualte how much time the tokens have been vesting, net of delays and pauses. 
     */
    function calc_vesting_time() public view returns(uint) {
        uint additional_delay = paused_delay();
        if( block.timestamp <= (vesting_start_time + delay + pause_delay + cliff + additional_delay) )
            return 0;
        return block.timestamp - vesting_start_time - delay - pause_delay + additional_delay;
    }
    
    /**
     * @dev Calculate when the vesting contract completes vesting. 
     */
    function calc_end_timestamp() public view returns(uint) {
        return (vesting_start_time + delay + pause_delay + period_time*num_periods + paused_delay());
    }
    
    /**
     * @dev If the contract is paused calcualte how long it has been paused.
     */
    function paused_delay() internal view returns(uint) {
        if( paused ) {
            require( block.timestamp > paused_timestamp, "Some kind of fuckery is going on." );
            return (block.timestamp - paused_timestamp); 
        }
        return 0;
    }
    
    /**
     * @dev Check if the contract is compelte. The contract is complete when all tokens have been claimed and when the current time is past the vesting end time.
     */
    function is_complete() public view returns(bool) {
        // check if all tokens have vested and if all tokens have been claimed
        if( (claimed >= num_to_vest) && (block.timestamp >= calc_end_timestamp()) )
            return true;
        return false;
    }
    
    /**
     * @dev Check whether the contract has sufficient funds remaining to satisfy the vesting contract.
     */
    function sufficient_funds() public view returns(bool) {
        ERC20 token = ERC20( token_address );
        uint balance = token.balanceOf( address(this) );
        require( num_to_vest >= claimed, "Number of tokens claimed in this contract exceeds the number set to vest." );
        if( balance >= (num_to_vest - claimed) )
            return true;
        return false;
    }
    
    /**
     * @dev Refund tokens if the vesting period has lapsed.
     */
     function refund() public onlyRole(DEFAULT_ADMIN_ROLE) {
         // check if the vesting period has lapsed
         require( block.timestamp > (calc_end_timestamp() + time_to_claim), "The vesting contract has not yet lapsed." );
         // calcualte the number of tokens remaining to be claimed and refund those tokens
         ERC20 token = ERC20( token_address );
         claimable = calc_claimable();
         token.transfer( return_funds, claimable );
         claimed += claimable;
         claimable = 0;
         complete = is_complete();
     }
}




