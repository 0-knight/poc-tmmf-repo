// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";

contract MaturityRegistryTest is Test {
    MaturityRegistry internal registry;

    address internal registrar = makeAddr("registrar");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant TERM = 7 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        registry = new MaturityRegistry(registrar);
    }

    function test_setMaturity_byAccount() public {
        uint256 maturity = block.timestamp + TERM;
        vm.prank(alice);
        registry.setMaturity(alice, maturity);
        assertEq(registry.maturityOf(alice), maturity);
    }

    function test_setMaturity_byRegistrar() public {
        uint256 maturity = block.timestamp + TERM;
        vm.prank(registrar);
        registry.setMaturity(alice, maturity);
        assertEq(registry.maturityOf(alice), maturity);
    }

    function test_setMaturity_rejectsThirdParty() public {
        vm.prank(bob);
        vm.expectRevert(MaturityRegistry.NotAuthorized.selector);
        registry.setMaturity(alice, block.timestamp + TERM);
    }

    function test_setMaturity_rejectsOverwrite() public {
        uint256 first = block.timestamp + TERM;
        vm.startPrank(alice);
        registry.setMaturity(alice, first);
        vm.expectRevert(abi.encodeWithSelector(MaturityRegistry.AlreadySet.selector, alice, first));
        registry.setMaturity(alice, first + 1 days);
        vm.stopPrank();
    }

    function test_setMaturity_rejectsPast() public {
        uint256 past = block.timestamp;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaturityRegistry.MaturityInPast.selector, past, block.timestamp));
        registry.setMaturity(alice, past);
    }

    /// 만기 전에는 디폴트가 아닙니다.
    function test_isDefaulted_falseBeforeMaturity() public {
        vm.prank(alice);
        registry.setMaturity(alice, block.timestamp + TERM);

        vm.warp(block.timestamp + TERM - 1);
        assertFalse(registry.isDefaulted(alice));
    }

    /// 만기 시각 정각에도 아직 아닙니다. 지나야 합니다.
    function test_isDefaulted_falseAtExactMaturity() public {
        uint256 maturity = block.timestamp + TERM;
        vm.prank(alice);
        registry.setMaturity(alice, maturity);

        vm.warp(maturity);
        assertFalse(registry.isDefaulted(alice));
    }

    function test_isDefaulted_trueAfterMaturity() public {
        uint256 maturity = block.timestamp + TERM;
        vm.prank(alice);
        registry.setMaturity(alice, maturity);

        vm.warp(maturity + 1);
        assertTrue(registry.isDefaulted(alice));
    }

    /// 기록이 없는 계정은 만기가 지날 수 없습니다.
    function test_isDefaulted_falseWhenUnset() public {
        vm.warp(block.timestamp + 365 days);
        assertFalse(registry.isDefaulted(bob));
    }

    function test_timeToMaturity() public {
        uint256 maturity = block.timestamp + TERM;
        vm.prank(alice);
        registry.setMaturity(alice, maturity);

        assertEq(registry.timeToMaturity(alice), TERM);
        vm.warp(maturity - 100);
        assertEq(registry.timeToMaturity(alice), 100);
        vm.warp(maturity + 1);
        assertEq(registry.timeToMaturity(alice), 0);
        assertEq(registry.timeToMaturity(bob), 0);
    }

    function test_clearMaturity_allowsNewTerm() public {
        vm.startPrank(alice);
        registry.setMaturity(alice, block.timestamp + TERM);
        registry.clearMaturity(alice);
        assertEq(registry.maturityOf(alice), 0);

        uint256 second = block.timestamp + 30 days;
        registry.setMaturity(alice, second);
        assertEq(registry.maturityOf(alice), second);
        vm.stopPrank();
    }

    function test_clearMaturity_rejectsUnset() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaturityRegistry.NotSet.selector, alice));
        registry.clearMaturity(alice);
    }

    function test_clearMaturity_rejectsThirdParty() public {
        vm.prank(alice);
        registry.setMaturity(alice, block.timestamp + TERM);

        vm.prank(bob);
        vm.expectRevert(MaturityRegistry.NotAuthorized.selector);
        registry.clearMaturity(alice);
    }

    /// 레지스트리는 청산을 강제하지 않습니다. 기록이 있어도 다른 계정에 영향이 없습니다.
    function test_recordsAreIndependentPerAccount() public {
        vm.prank(alice);
        registry.setMaturity(alice, block.timestamp + TERM);

        vm.warp(block.timestamp + TERM + 1);
        assertTrue(registry.isDefaulted(alice));
        assertFalse(registry.isDefaulted(bob));
    }

    function test_constructor_rejectsZeroRegistrar() public {
        vm.expectRevert(MaturityRegistry.ZeroAddress.selector);
        new MaturityRegistry(address(0));
    }
}
