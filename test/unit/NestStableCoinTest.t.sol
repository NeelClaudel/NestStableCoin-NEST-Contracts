// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {NestStableCoin} from "../../src/NestStableCoin.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DecentralizedStablecoinTest is StdCheats, Test {
    NestStableCoin nest;

    function setUp() public {
        nest = new NestStableCoin();
    }

    function testMustMintMoreThanZero() public {
        vm.prank(nest.owner());
        vm.expectRevert();
        nest.mint(address(this), 0);
    }

    function testMustBurnMoreThanZero() public {
        vm.startPrank(nest.owner());
        nest.mint(address(this), 100);
        vm.expectRevert();
        nest.burn(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanYouHave() public {
        vm.startPrank(nest.owner());
        nest.mint(address(this), 100);
        vm.expectRevert();
        nest.burn(101);
        vm.stopPrank();
    }

    function testCantMintToZeroAddress() public {
        vm.startPrank(nest.owner());
        vm.expectRevert();
        nest.mint(address(0), 100);
        vm.stopPrank();
    }
}
