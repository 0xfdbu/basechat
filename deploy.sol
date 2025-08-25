// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "./BaseChat.sol";

contract DeployBaseChat is Script {
    function run() external {
        vm.startBroadcast();

        BaseChat impl = new BaseChat();
        ProxyAdmin admin = new ProxyAdmin(msg.sender); // Pass msg.sender as the initial owner
        bytes memory data = abi.encodeWithSelector(BaseChat.initialize.selector);

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            address(admin),
            data
        );

        console.log("Proxy address:", address(proxy));
        console.log("Implementation address:", address(impl));

        vm.stopBroadcast();
    }
}
