pragma solidity 0.4.15;

import {Owned} from "./Owned.sol";
import {SafeMath} from "./SafeMath.sol";
import {ATSTokenInterface} from "./ATSTokenInterface.sol";
import {ERC20} from "./ERC20.sol";
import {ContractInterfaceImplementer} from "./ContractInterfaceImplementer.sol";
import {ATSTokenRecipient} from "./ATSTokenRecipient.sol";
import {ATSTokenSender} from "./ATSTokenSender.sol";
import {ATSTokenBridgeInterface} from "./ATSTokenBridgeInterface.sol";

contract ATSTokenBase is Owned, ATSTokenInterface, ERC20, ContractInterfaceImplementer, ATSTokenBridgeInterface {
    using SafeMath for uint128;

    /* -- Constants -- */
    address constant internal zeroAddress = 0x0000000000000000000000000000000000000000000000000000000000000000;

    /* -- ATS Contract State -- */
    string internal tokenName;
    string internal tokenSymbol;
    uint128 internal tokenGranularity;
    uint128 internal tokenTotalSupply;

    mapping(address => uint128) internal balances;
    mapping(address => mapping(address => bool)) internal authorized;

    // for ERC20
    mapping(address => mapping(address => uint128)) internal allowed;

    // for Token Bridge
    address internal relay;

    /* -- Constructor -- */
    //
    /// @notice Constructor to create a ReferenceToken
    /// @param _name Name of the new token.
    /// @param _symbol Symbol of the new token.
    /// @param _granularity Minimum transferable chunk.
    /// @param _totalSupply of the new token. This can only be set once
    function ATSTokenBase(
        string _name,
        string _symbol,
        uint128 _granularity,
        uint128 _totalSupply
    ) public {
        require(_granularity >= 1);
        tokenName = _name;
        tokenSymbol = _symbol;
        tokenTotalSupply = _totalSupply;
        tokenGranularity = _granularity;

        // register onto CIR
        setInterfaceImplementation("ATSTokenInterface", this);

        //emit events for total tokens created for this contract address
        Created(tokenTotalSupply, this);
    }
    /*-- ERC777 Interface Implementation --*/
    //
    /// @return the name of the token
    function name() public constant returns (string) {return tokenName;}

    /// @return the symbol of the token
    function symbol() public constant returns (string) {return tokenSymbol;}

    /// @return the granularity of the token
    function granularity() public constant returns (uint128) {return tokenGranularity;}

    /// @return the total supply of the token
    function totalSupply() public constant returns (uint128) {return tokenTotalSupply;}

    /// @return the liquid supply of the token after subtracting frozen tokens
    function liquidSupply() public constant returns (uint128) {
        return tokenTotalSupply.sub(balanceOf(this));
    }

    /// @notice Return the account balance of some account
    /// @param _tokenHolder Address for which the balance is returned
    /// @return the balance of `_tokenAddress`.
    function balanceOf(address _tokenHolder) public constant returns (uint128) {return balances[_tokenHolder];}

    /// @notice Send `_amount` of tokens to address `_to` passing `_userData` to the recipient
    /// @param _to The address of the recipient
    /// @param _amount The number of tokens to be sent
    function send(address _to, uint128 _amount, bytes _userData) public {
        doSend(msg.sender, msg.sender, _to, _amount, _userData, "", true);
    }

    /// @notice Authorize a third party `_operator` to manage (send) `msg.sender`'s tokens.
    /// @param _operator The operator that wants to be Authorized
    function authorizeOperator(address _operator) public {
        require(_operator != msg.sender);
        authorized[_operator][msg.sender] = true;
        AuthorizedOperator(_operator, msg.sender);
    }

    /// @notice Revoke a third party `_operator`'s rights to manage (send) `msg.sender`'s tokens.
    /// @param _operator The operator that wants to be Revoked
    function revokeOperator(address _operator) public {
        require(_operator != msg.sender);
        authorized[_operator][msg.sender] = false;
        RevokedOperator(_operator, msg.sender);
    }

    /// @notice Check whether the `_operator` address is allowed to manage the tokens held by `_tokenHolder` address.
    /// @param _operator address to check if it has the right to manage the tokens
    /// @param _tokenHolder address which holds the tokens to be managed
    /// @return `true` if `_operator` is authorized for `_tokenHolder`
    function isOperatorFor(address _operator, address _tokenHolder) public constant returns (bool) {
        return (_operator == _tokenHolder || authorized[_operator][_tokenHolder]);
    }

    /// @notice Send `_amount` of tokens on behalf of the address `from` to the address `to`.
    /// @param _from The address holding the tokens being sent
    /// @param _to The address of the recipient
    /// @param _amount The number of tokens to be sent
    /// @param _userData Data generated by the user to be sent to the recipient
    /// @param _operatorData Data generated by the operator to be sent to the recipient
    function operatorSend(address _from, address _to, uint128 _amount, bytes _userData, bytes _operatorData) public {
        require(isOperatorFor(msg.sender, _from));
        doSend(msg.sender, _from, _to, _amount, _userData, _operatorData, true);
    }

    function burn(uint128 _amount, bytes _holderData) public {
        doBurn(msg.sender, msg.sender, _amount, _holderData, "");
    }

    function operatorBurn(address _tokenHolder, uint128 _amount, bytes _holderData, bytes _operatorData) public {
        require(isOperatorFor(msg.sender, _tokenHolder));
        doBurn(msg.sender, _tokenHolder, _amount, _holderData, _operatorData);
    }

    /*--Helper Functions --*/

    /// @notice Internal function that ensures `_amount` is multiple of the granularity
    /// @param _amount The quantity that want's to be checked
    function requireMultiple(uint128 _amount) internal constant {
        require(_amount.div(tokenGranularity).mul(tokenGranularity) == _amount);
    }

    /// @notice Check whether an address is a regular address or not.
    /// @param _addr Address of the contract that has to be checked
    /// @return `true` if `_addr` is a regular address (not a contract)
    ///
    /// Ideally, we should propose a better system that extcodesize
    /// TODO: CHANGE ME, going to require a resolution on best approach
    /// Given that we won't be able to detect code size.
    ///
    /// @param _addr The address to be checked
    /// @return `true` if the contract is a regular address, `false` otherwise
    function isRegularAddress(address _addr) internal constant returns (bool) {
        //        if (_addr == 0) { return false; }
        //        uint size;
        //        assembly { size := extcodesize(_addr) }
        //        return size == 0;
        return _addr != 0x0;
    }

    /// @notice Helper function actually performing the sending of tokens.
    /// @param _operator The address performing the send
    /// @param _from The address holding the tokens being sent
    /// @param _to The address of the recipient
    /// @param _amount The number of tokens to be sent
    /// @param _userData Data generated by the user to be passed to the recipient
    /// @param _operatorData Data generated by the operator to be passed to the recipient
    /// @param _preventLocking `true` if you want this function to throw when tokens are sent to a contract not
    ///  implementing `erc777_tokenHolder`.
    ///  ERC777 native Send functions MUST set this parameter to `true`, and backwards compatible ERC20 transfer
    ///  functions SHOULD set this parameter to `false`.
    function doSend(
        address _operator,
        address _from,
        address _to,
        uint128 _amount,
        bytes _userData,
        bytes _operatorData,
        bool _preventLocking
    )
    internal
    {
        requireMultiple(_amount);

        callSender(_operator, _from, _to, _amount, _userData, _operatorData);

        // forbid sending to 0x0 (=burning)
        require(_to != address(0));
        // ensure enough funds
        require(balances[_from] >= _amount);

        balances[_from] = balances[_from].sub(_amount);
        balances[_to] = balances[_to].add(_amount);

        callRecipient(_operator, _from, _to, _amount, _userData, _operatorData, _preventLocking);

        Sent(_operator, _from, _to, _amount, _userData, _operatorData);
    }

    /// @notice Helper function actually performing the burning of tokens.
    /// @param _operator The address performing the burn
    /// @param _tokenHolder The address holding the tokens being burn
    /// @param _amount The number of tokens to be burnt
    /// @param _holderData Data generated by the token holder
    /// @param _operatorData Data generated by the operator
    function doBurn(address _operator, address _tokenHolder, uint128 _amount, bytes _holderData, bytes _operatorData)
    internal
    {
        requireMultiple(_amount);
        require(balanceOf(_tokenHolder) >= _amount);

        balances[_tokenHolder] = balances[_tokenHolder].sub(_amount);
        tokenTotalSupply = tokenTotalSupply.sub(_amount);

        callSender(_operator, _tokenHolder, 0x0, _amount, _holderData, _operatorData);
        Burned(_operator, _tokenHolder, _amount, _holderData, _operatorData);
    }

    /// @notice Helper function that checks for ERC777TokensRecipient on the recipient and calls it.
    ///  May throw according to `_preventLocking`
    /// @param _operator The address performing the send or mint
    /// @param _from The address holding the tokens being sent
    /// @param _to The address of the recipient
    /// @param _amount The number of tokens to be sent
    /// @param _userData Data generated by the user to be passed to the recipient
    /// @param _operatorData Data generated by the operator to be passed to the recipient
    /// @param _preventLocking `true` if you want this function to throw when tokens are sent to a contract not
    ///  implementing `ERC777TokensRecipient`.
    ///  ERC777 native Send functions MUST set this parameter to `true`, and backwards compatible ERC20 transfer
    ///  functions SHOULD set this parameter to `false`.
    function callRecipient(
        address _operator,
        address _from,
        address _to,
        uint128 _amount,
        bytes _userData,
        bytes _operatorData,
        bool _preventLocking
    )
    internal
    {
        address recipientImplementation = interfaceAddr(_to, "ATSTokenRecipient");
        if (recipientImplementation != 0) {
            ATSTokenRecipient(recipientImplementation)
            .tokensReceived(_operator, _from, _to, _amount, _userData, _operatorData);
        } else if (_preventLocking) {
            require(isRegularAddress(_to));
        }
    }

    /// @notice Helper function that checks for ERC777TokensSender on the sender and calls it.
    ///  May throw according to `_preventLocking`
    /// @param _from The address holding the tokens being sent
    /// @param _to The address of the recipient
    /// @param _amount The amount of tokens to be sent
    /// @param _userData Data generated by the user to be passed to the recipient
    /// @param _operatorData Data generated by the operator to be passed to the recipient
    ///  implementing `ERC777TokensSender`.
    ///  ERC777 native Send functions MUST set this parameter to `true`, and backwards compatible ERC20 transfer
    ///  functions SHOULD set this parameter to `false`.
    function callSender(
        address _operator,
        address _from,
        address _to,
        uint128 _amount,
        bytes _userData,
        bytes _operatorData
    )
    internal
    {
        address senderImplementation = interfaceAddr(_from, "ATSTokenSender");
        if (senderImplementation == 0) {return;}
        ATSTokenSender(senderImplementation)
        .tokensToSend(_operator, _from, _to, _amount, _userData, _operatorData);
    }

    /*--ERC20 Functionality --*/

    function decimals() public constant returns (uint8) {
        return uint8(18);
    }

    /// @param _to The address of the recipient
    /// @param _amount The number of tokens to be transferred
    /// @return `true`, if the transfer can't be done, it should fail.
    function transfer(address _to, uint128 _amount) public returns (bool success) {
        doSend(msg.sender, msg.sender, _to, _amount, "", "", false);
        return true;
    }

    /// @param _from The address holding the tokens being transferred
    /// @param _to The address of the recipient
    /// @param _amount The number of tokens to be transferred
    /// @return `true`, if the transfer can't be done, it should fail.
    function transferFrom(address _from, address _to, uint128 _amount) public returns (bool success) {
        require(_amount <= allowed[_from][msg.sender]);

        allowed[_from][msg.sender] = allowed[_from][msg.sender].sub(_amount);
        doSend(msg.sender, _from, _to, _amount, "", "", false);
        return true;
    }

    ///  `msg.sender` approves `_spender` to spend `_amount` tokens on its behalf.
    /// @param _spender The address of the account able to transfer the tokens
    /// @param _amount The number of tokens to be approved for transfer
    /// @return `true`, if the approve can't be done, it should fail.
    function approve(address _spender, uint128 _amount) public returns (bool success) {
        allowed[msg.sender][_spender] = _amount;
        Approval(msg.sender, _spender, _amount);
        return true;
    }

    ///  This function makes it easy to read the `allowed[]` map
    /// @param _owner The address of the account that owns the token
    /// @param _spender The address of the account able to transfer the tokens
    /// @return Amount of remaining tokens of _owner that _spender is allowed
    ///  to spend
    function allowance(address _owner, address _spender) public constant returns (uint128 remaining) {
        return allowed[_owner][_spender];
    }

    /*--ATS Token Bridge Functionality --*/

    /// @notice thaw is called to release token from the frozen supply
    function thaw(bytes32 _foreignNetworkId, address _recipient, uint128 _amount, bytes _foreignData) public {
        require(msg.sender == relay);
        require(_amount <= balances[this]);
        requireMultiple(_amount);

        balances[_recipient] = balances[_recipient].add(_amount);
        balances[this] = balances[this].sub(_amount);

        Thaw(_foreignNetworkId, _recipient, _amount, _foreignData);
    }

    /// @notice Returns the relay/bridge address for the given implementer
    function registry() public constant returns (address) {
        return relay;
    }

    /// @notice Interface for a user to execute a `freeze`, which essentially
    /// is a functionality that locks the token in the contract address
    ///
    /// @dev function is called by local user to `freeze` tokens thereby
    /// transferring them to another network.
    function freeze(bytes32 _foreignNetworkId, bytes32 _foreignRecipient, uint128 _amount, bytes _localData) public
    onlyNotOwner {
        requireMultiple(_amount);
        require(_amount <= balances[msg.sender]);

        balances[this] = balances[this].add(_amount);
        balances[msg.sender] = balances[msg.sender].sub(_amount);

        Freeze(_foreignNetworkId, _foreignRecipient, _amount, _localData);
    }

    /// @notice function for a token contract to set the registry
    function setRegistry(address _registry) public onlyOwner {
        relay = _registry;

        RegistrySet(_registry);
    }
}
