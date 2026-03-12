// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILocking} from "src/interfaces/IGoatLocking.sol";

contract MockLocking is ILocking {
    struct PendingClaim {
        IERC20 token;
        uint256 nativeAmount;
        uint256 tokenAmount;
    }

    mapping(address => address) private _owners;
    mapping(address => PendingClaim) private _pendingClaims;

    address public lastLockCaller;
    address public lastLockValidator;
    uint256 public lastLockValue;
    uint256 public lastLockLength;

    address public lastUnlockCaller;
    address public lastUnlockValidator;
    address public lastUnlockRecipient;
    uint256 public lastUnlockLength;

    receive() external payable {}

    function setOwner(address validator, address owner) external {
        _owners[validator] = owner;
    }

    function owners(address validator) external view override returns (address) {
        return _owners[validator];
    }

    function seedClaim(address validator, IERC20 token, uint256 nativeAmount, uint256 tokenAmount) external payable {
        require(msg.value == nativeAmount, "Invalid native funding");

        PendingClaim storage pendingClaim = _pendingClaims[validator];
        pendingClaim.nativeAmount += nativeAmount;

        if (tokenAmount > 0) {
            if (address(pendingClaim.token) == address(0)) {
                pendingClaim.token = token;
            } else {
                require(address(pendingClaim.token) == address(token), "Token mismatch");
            }

            require(token.transferFrom(msg.sender, address(this), tokenAmount), "Token transfer failed");
            pendingClaim.tokenAmount += tokenAmount;
        }
    }

    function changeValidatorOwner(address validator, address newOwner) external override {
        require(msg.sender == _owners[validator], "Not validator owner");
        _owners[validator] = newOwner;
    }

    function claim(address validator, address recipient) external override {
        require(msg.sender == _owners[validator], "Not validator owner");

        PendingClaim storage pendingClaim = _pendingClaims[validator];

        uint256 nativeAmount = pendingClaim.nativeAmount;
        if (nativeAmount > 0) {
            pendingClaim.nativeAmount = 0;
            (bool success,) = recipient.call{value: nativeAmount}("");
            require(success, "Native transfer failed");
        }

        uint256 tokenAmount = pendingClaim.tokenAmount;
        if (tokenAmount > 0) {
            IERC20 token = pendingClaim.token;
            pendingClaim.tokenAmount = 0;
            pendingClaim.token = IERC20(address(0));
            require(token.transfer(recipient, tokenAmount), "Token transfer failed");
        }
    }

    function lock(address validator, Locking[] calldata values) external payable override {
        require(msg.sender == _owners[validator], "Not validator owner");

        lastLockCaller = msg.sender;
        lastLockValidator = validator;
        lastLockValue = msg.value;
        lastLockLength = values.length;

        for (uint256 i; i < values.length; i++) {
            if (values[i].token == address(0) || values[i].amount == 0) {
                continue;
            }

            require(
                IERC20(values[i].token).transferFrom(msg.sender, address(this), values[i].amount), "Token pull failed"
            );
        }
    }

    function unlock(address validator, address recipient, Locking[] calldata values) external override {
        require(msg.sender == _owners[validator], "Not validator owner");

        lastUnlockCaller = msg.sender;
        lastUnlockValidator = validator;
        lastUnlockRecipient = recipient;
        lastUnlockLength = values.length;
    }

    function create(bytes32[2] calldata, bytes32, bytes32, uint8) external payable override {}

    function creationThreshold() external pure override returns (Locking[] memory thresholds) {
        thresholds = new Locking[](0);
    }

    function getAddressByPubkey(bytes32[2] calldata) external pure override returns (address, address) {
        return (address(0), address(0));
    }

    function reclaim() external override {}
}
