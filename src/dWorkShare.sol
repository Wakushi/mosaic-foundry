// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// What happens to this contract once the associated artwork is sold?
// All ERC20 share holders will be paid out in proportion to their share holdings
// Then all the supply should be burned

contract dWorkShare is ERC20 {
    uint256 public immutable i_sharePrice;
    address public s_owner;

    constructor(
        address _initialOwner,
        uint256 _shareSupply,
        uint256 _sharePrice,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        _mint(_initialOwner, _shareSupply);
        i_sharePrice = _sharePrice;
    }

    function buyShare(uint256 _amount) external payable {
        
    }
}

