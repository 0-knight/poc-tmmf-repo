// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {ParticipantRegistry} from "../../src/registry/ParticipantRegistry.sol";
import {WTGXXGate} from "../../src/gate/WTGXXGate.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";
import {MockComplianceOracle} from "../../src/mocks/MockComplianceOracle.sol";

/// @dev 항상 revert하는 게이트. 규약을 어기는 구현체가 들어왔을 때를 흉내냅니다.
contract RevertingGate {
    function canEnter(address) external pure returns (bool) {
        revert("nope");
    }
}

/// @dev 불린이 아닌 것을 돌려주는 게이트. 짧은 반환 데이터를 흉내냅니다.
contract GarbageGate {
    fallback() external {
        assembly {
            return(0, 4)
        }
    }
}

contract ParticipantRegistryTest is Test {
    MockKycNFT internal kyc;
    MockComplianceOracle internal compliance;
    MockWTGXX internal wtgxx;
    WTGXXGate internal gate;
    ParticipantRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        kyc = new MockKycNFT(address(this));
        compliance = new MockComplianceOracle(address(this), address(kyc));
        wtgxx = new MockWTGXX(address(this), address(compliance), address(0xDEAD));
        gate = new WTGXXGate(address(wtgxx));
        registry = new ParticipantRegistry(address(gate), admin);
    }

    function test_constructor_rejectsZeroAdmin() public {
        vm.expectRevert(ParticipantRegistry.E_ZeroAddress.selector);
        new ParticipantRegistry(address(gate), address(0));
    }

    /// 게이트 없이도 만들 수 있습니다. 승인 목록만으로 판정합니다.
    function test_constructor_allowsZeroGate() public {
        ParticipantRegistry bare = new ParticipantRegistry(address(0), admin);

        assertFalse(bare.isEligible(alice));
        (bool answered,) = bare.gateSays(alice);
        assertFalse(answered);

        vm.prank(admin);
        bare.setApproved(alice, true);
        assertTrue(bare.isEligible(alice));
    }

    // --- 게이트 경로 ---

    function test_gatePathAllowsWhitelisted() public {
        kyc.safeMint(alice);

        (bool answered, bool allowed) = registry.gateSays(alice);
        assertTrue(answered);
        assertTrue(allowed);
        assertTrue(registry.isEligible(alice));
        assertFalse(registry.isEligibleOnlyByApproval(alice));
    }

    function test_gatePathRejectsUnknown() public view {
        assertFalse(registry.isEligible(bob));
    }

    function test_zeroAddressNeverEligible() public {
        vm.prank(admin);
        vm.expectRevert(ParticipantRegistry.E_ZeroAddress.selector);
        registry.setApproved(address(0), true);

        assertFalse(registry.isEligible(address(0)));
    }

    function test_frozenAccountRejected() public {
        kyc.safeMint(alice);
        assertTrue(registry.isEligible(alice));

        wtgxx.freeze(alice);
        assertFalse(registry.isEligible(alice));
    }

    // --- 승인 목록 경로 ---

    function test_approvalOverridesGateRejection() public {
        assertFalse(registry.isEligible(alice));

        vm.prank(admin);
        registry.setApproved(alice, true);

        assertTrue(registry.isEligible(alice));
        assertTrue(registry.isEligibleOnlyByApproval(alice), unicode"승인 경로 표시가 켜지지 않았습니다");
    }

    /// 게이트가 이미 허용하는 주소는 승인 경로로 집계되지 않습니다. 감시 신호가 흐려집니다.
    function test_approvalNotFlaggedWhenGateAlsoAllows() public {
        kyc.safeMint(alice);
        vm.prank(admin);
        registry.setApproved(alice, true);

        assertTrue(registry.isEligible(alice));
        assertFalse(registry.isEligibleOnlyByApproval(alice));
    }

    function test_approvalRevocable() public {
        vm.startPrank(admin);
        registry.setApproved(alice, true);
        assertTrue(registry.isEligible(alice));
        registry.setApproved(alice, false);
        vm.stopPrank();

        assertFalse(registry.isEligible(alice));
    }

    function test_setApprovedRejectsNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(ParticipantRegistry.E_NotAdmin.selector);
        registry.setApproved(alice, true);
    }

    // --- 컴플라이언스가 사라진 경우. 백서 6.2절 ---

    /// 컴플라이언스가 제거되면 게이트는 답은 하지만 모두를 거부합니다.
    /// 그 상태에서 승인 목록이 유일한 통로입니다.
    function test_complianceRemoved_gateAnswersButRejects() public {
        kyc.safeMint(alice);
        assertTrue(registry.isEligible(alice));

        wtgxx.setCompliance(address(0));

        (bool answered, bool allowed) = registry.gateSays(alice);
        assertTrue(answered, unicode"게이트가 답하지 못했습니다");
        assertFalse(allowed);
        assertFalse(registry.isEligible(alice));

        vm.prank(admin);
        registry.setApproved(alice, true);
        assertTrue(registry.isEligible(alice));
    }

    // --- 절대 revert하지 않는다 ---

    /// 게이트가 규약을 어기고 revert해도 레지스트리는 멈추지 않습니다.
    function test_neverRevertsWhenGateReverts() public {
        ParticipantRegistry r = new ParticipantRegistry(address(new RevertingGate()), admin);

        (bool answered,) = r.gateSays(alice);
        assertFalse(answered, unicode"revert한 게이트가 답한 것으로 집계됐습니다");
        assertFalse(r.isEligible(alice));

        vm.prank(admin);
        r.setApproved(alice, true);
        assertTrue(r.isEligible(alice));
    }

    /// 반환 데이터가 32바이트보다 짧으면 답하지 않은 것으로 봅니다.
    function test_neverRevertsWhenGateReturnsGarbage() public {
        ParticipantRegistry r = new ParticipantRegistry(address(new GarbageGate()), admin);

        (bool answered,) = r.gateSays(alice);
        assertFalse(answered);
        assertFalse(r.isEligible(alice));
    }

    /// 컨트랙트가 아닌 주소를 게이트로 넣어도 조용히 거부합니다.
    function test_neverRevertsWhenGateIsNotAContract() public {
        ParticipantRegistry r = new ParticipantRegistry(makeAddr("not-a-contract"), admin);

        (bool answered,) = r.gateSays(alice);
        assertFalse(answered);
        assertFalse(r.isEligible(alice));
    }
}
