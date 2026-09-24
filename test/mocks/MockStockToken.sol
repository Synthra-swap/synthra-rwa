// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev TEST ONLY. Models transfers that can become taxed or frozen by an issuer.
contract MockStockToken is ERC20 {
    uint256 public current = 1e18;
    uint256 public pending = 1e18;
    uint256 public effectiveAt;

    function uiMultiplier() external view returns (uint256) {
        return effectiveAt != 0 && block.timestamp >= effectiveAt ? pending : current;
    }

    function newUIMultiplier() external view returns (uint256) {
        return pending;
    }

    function setMultiplier(uint256 nowValue, uint256 nextValue, uint256 when) external {
        current = nowValue;
        pending = nextValue;
        effectiveAt = when;
    }

    function seize(address holder, uint256 amount) external {
        _burn(holder, amount);
    }
    address public blockedRecipient;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }
    bool public taxed;
    bool public frozen;

    constructor() ERC20("Mock Stock Token - no real backing", "MOCK") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setTaxed(bool value) external {
        taxed = value;
    }

    function setFrozen(bool value) external {
        frozen = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!frozen, "issuer freeze");
        require(to == address(0) || to != blockedRecipient, "blocked recipient");
        if (taxed && from != address(0) && to != address(0) && value > 0) {
            super._update(from, address(0), 1);
            value -= 1;
        }
        super._update(from, to, value);
        if (callbackTarget != address(0) && from != address(0) && to != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
    }
}

