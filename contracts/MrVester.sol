// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "./VestingInstance.sol";

/** 
 * @title MrVester
 * @dev Implements a vesting controller contract 
 */
contract MrVester is AccessControl {
   
   // roles
   bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    struct AllowedToken {
        uint min_quantity; // minimum number of tokens to vest
        uint max_quantity; // maximum number of tokens to vest
        bool allowed;
    }
    
    // state storage variables
    VestingInstance[] private vesting_instances;
    mapping( address => VestingInstance[] ) private beneficiary_vinstances; // mapping of beneficiaries to vesting instances
    mapping( address => VestingInstance[] ) private controller_vinstances;  // mapping of controllers to their vesting instances
    mapping( address => AllowedToken ) private allowed_tokens; // list of allowed tokens with parameters, useful to prevent spam attacks
    
    /** 
     * @dev Create a new MrVester instance and assign the sender as the admin
    */
    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender()); // set admin as the owner
    }
    
    /** 
     * @dev Enable an ERC20 token for vesting contract creation.
    */
    function set_allowed_token( address _token, uint _min, uint _max ) public onlyRole(MANAGER_ROLE) {
        allowed_tokens[_token] = AllowedToken(_min,_max,true);
    }
    
    /** 
     * @dev Disable an ERC20 token vesting contract creation.
    */
    function remove_allowed_token( address _token ) public onlyRole(MANAGER_ROLE) {
        allowed_tokens[_token].allowed = false;
    }
    
    /** 
     * @dev Create a vesting instance and transfer funds into the vesting contract.
    */
    function create_vesting_instance( address _beneficiary, 
                                      address _token_address,
                                      address _controller,
                                      uint _delay,
                                      uint _cliff,
                                      uint _period_time,
                                      uint _num_periods,
                                      uint _num_to_vest,
                                      uint _time_to_claim
                                      ) public {
        // ensure this token is allowed and the vesting amount is in range
        require( allowed_tokens[_token_address].allowed, "This token is not allowed to be used." );
        require( allowed_tokens[_token_address].min_quantity <= _num_to_vest, "The vesting amount is below the minimum tokens allowed for a vesting contract." );
        require( allowed_tokens[_token_address].max_quantity >= _num_to_vest, "The vesting amount is above the maximum tokens allowed for a vesting contract." );
        
        // ensure we have permission and sufficient funds to transfer ERC20 funds
        ERC20 token = ERC20( _token_address );
        uint allowance = token.allowance( _msgSender(), address(this) );
        require( allowance >= _num_to_vest, "Insufficient allowance to create vesting instance." );
        require( token.balanceOf( _msgSender() ) >= _num_to_vest, "Insufficient balance to create vesting instance." );
        
        // create vesting instance and set parameters 
        VestingInstance new_instance = new VestingInstance( _beneficiary, 
                                                            _msgSender(),
                                                            _token_address,
                                                            _controller,
                                                            _delay,
                                                            _cliff,
                                                            _period_time,
                                                            _num_periods,
                                                            _num_to_vest,
                                                            _time_to_claim );
        
        //insert new vesting contract instance
        vesting_instances.push( new_instance );

        // add controller reference
        controller_vinstances[_controller].push( new_instance );
        
        // add beneficiary reference 
        beneficiary_vinstances[_beneficiary].push( new_instance );
        
        // transfer funds from source to this contract
        token.transferFrom( _msgSender(), address(new_instance), _num_to_vest );
    }
    
    /**
     * @dev Add a controller to the vesting contract. Only an existing controller of the contract can do this.
     */
    function add_controller( address _vesting_instance, address _controller ) public {
        VestingInstance instance = VestingInstance(_vesting_instance);
        require( instance.hasRole(instance.CONTROLLER_ROLE(), _msgSender()), "Only an existing controller can add another controller." );
        if( !instance.hasRole(instance.CONTROLLER_ROLE(), _controller) )  {
            controller_vinstances[_controller].push( instance );
            instance.grantRole(instance.CONTROLLER_ROLE(), _controller);
        }
    }
    
    /**
     * @dev Remove a controller from a vesting contrat. Only an existing controller of the contract can do this.
     */
    function remove_controller( address _vesting_instance, address _controller ) public {
        VestingInstance instance = VestingInstance(_vesting_instance);
        require( instance.hasRole(instance.CONTROLLER_ROLE(), _msgSender()), "Only an existing controller can add another controller." );
        if( instance.hasRole(instance.CONTROLLER_ROLE(), _controller) )  {
            instance.revokeRole(instance.CONTROLLER_ROLE(), _controller);
            // TODO remove instance from controller_vinstances list
                // search for the index of this controller
        }
    }

    /** 
     * @dev Swap the beneficiary of the vesting contract
     */
     function swap_beneficiary( address _vesting_instance, address _new_beneficiary ) public {
         VestingInstance instance = VestingInstance(_vesting_instance);
         require( _new_beneficiary != instance.beneficiary(), "Must provide a different beneficiary than the existing one." );
         if( instance.hasRole(instance.BENEFICIARY_ROLE(), _msgSender()) ) { // only the beneficiary can swap to a new beneficiary
             instance.swap_beneficiary( _new_beneficiary );
             beneficiary_vinstances[_new_beneficiary].push( instance );
             // find index 
             uint index = 0;
             bool found = false;
             uint length = beneficiary_vinstances[_new_beneficiary].length;
             address old_beneficiary =  _msgSender();
             for( uint i = 0; i < length; i++ ) {
                 if( address(beneficiary_vinstances[old_beneficiary][i]) == _vesting_instance ) {
                    index = i;
                    found = true;
                    break;
                 }
             }
             if( found ){
                 /*
                         for (uint i = index; i<array.length-1; i++){
                            array[i] = array[i+1];
                        }
                        delete array[array.length-1];
                        array.length--;
                        return array;
                        */
             }
        }
     }

    /** 
     * @dev Get the instances controlled by this controller.
    */
    function get_controlled_instances( address _controller ) public view returns( VestingInstance[] memory ) {
        return controller_vinstances[_controller];
    }
    
    /** 
     * @dev Get the vesting instances for this beneficiary.
    */
    function get_beneficiary_instances( address _beneficiary ) public view returns( VestingInstance[] memory ) {
        return beneficiary_vinstances[_beneficiary];
    }
    
    /** 
     * @dev Clean up expired vested tokens and refund them back.
    */
    function refund( VestingInstance _instance ) public onlyRole(MANAGER_ROLE) {
        _instance.refund();
    }
    
    function refund() public onlyRole(MANAGER_ROLE) {
        uint length = vesting_instances.length;
        for( uint i = 0; i < length; i++ )
            vesting_instances[i].refund();
    }
}





