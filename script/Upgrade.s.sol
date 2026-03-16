pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {ValidatorEntryUpgradeable} from "../src/ValidatorEntryUpgradeable.sol";

contract Upgrade is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("PROXY_ADDR");

        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Proxy:", proxy);

        vm.startBroadcast(deployerPrivateKey);

        ValidatorEntryUpgradeable newImpl = new ValidatorEntryUpgradeable();
        console.log("New implementation:", address(newImpl));

        ValidatorEntryUpgradeable(payable(proxy)).upgradeToAndCall(
            address(newImpl),
            ""
        );
        console.log("Upgrade complete");

        vm.stopBroadcast();
    }
}
