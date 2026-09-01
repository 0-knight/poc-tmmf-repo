// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WTGXXGate} from "../../src/gate/WTGXXGate.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";
import {MockComplianceOracle} from "../../src/mocks/MockComplianceOracle.sol";

contract WTGXXGateTest is Test {
    WTGXXGate internal gate;
    MockWTGXX internal token;
    MockKycNFT internal kyc;
    MockComplianceOracle internal oracle;

    address internal registrar = makeAddr("registrar");
    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        kyc = new MockKycNFT(issuer);
        oracle = new MockComplianceOracle(issuer, address(kyc));
        token = new MockWTGXX(registrar, address(oracle), makeAddr("impl"));
        gate = new WTGXXGate(address(token));

        // alice만 KYC NFT를 받습니다.
        vm.prank(issuer);
        kyc.safeMint(alice);
    }

    function test_allows_whitelistedAccount() public view {
        assertTrue(gate.canEnter(alice));
        assertEq(uint256(gate.checkEntry(alice)), uint256(WTGXXGate.Reason.Allowed));
    }

    function test_rejects_accountWithoutKycNft() public view {
        assertFalse(gate.canEnter(stranger));
        assertEq(uint256(gate.checkEntry(stranger)), uint256(WTGXXGate.Reason.NotWhitelisted));
    }

    /// 오라클이 zero 주소에 revert하므로 게이트가 먼저 걸러야 합니다.
    /// 게이트는 revert하지 않고 false를 반환해야 합니다.
    function test_rejects_zeroAddress_withoutReverting() public view {
        assertFalse(gate.canEnter(address(0)));
        assertEq(uint256(gate.checkEntry(address(0))), uint256(WTGXXGate.Reason.ZeroTarget));
    }

    /// 이 컨트랙트의 존재 이유입니다.
    /// 컴플라이언스를 지우면 토큰은 true를 주지만 게이트는 막아야 합니다.
    function test_rejects_whenComplianceRemoved_thoughTokenSaysTrue() public {
        vm.prank(registrar);
        token.setCompliance(address(0));

        // 토큰 단독 판정은 통과합니다. 아무 주소나 통과합니다.
        assertTrue(token.isAddressWhitelisted(address(0), stranger, 0));

        // 게이트는 막습니다.
        assertFalse(gate.canEnter(stranger));
        assertFalse(gate.canEnter(alice));
        assertEq(uint256(gate.checkEntry(alice)), uint256(WTGXXGate.Reason.ComplianceRemoved));
    }

    function test_rejects_whenTokenPaused() public {
        vm.prank(registrar);
        token.pause();

        assertFalse(gate.canEnter(alice));
        assertEq(uint256(gate.checkEntry(alice)), uint256(WTGXXGate.Reason.TokenPaused));
    }

    function test_rejects_whenAccountFrozen() public {
        vm.prank(registrar);
        token.freeze(alice);

        assertFalse(gate.canEnter(alice));
        assertEq(uint256(gate.checkEntry(alice)), uint256(WTGXXGate.Reason.AccountFrozen));
    }

    /// 오라클을 끄면 canTransfer가 전부 false입니다. 컴플라이언스 제거와 결과가 정반대입니다.
    function test_rejects_whenOracleDisabled() public {
        vm.prank(issuer);
        oracle.disableOracle();

        assertFalse(gate.canEnter(alice));
        assertEq(uint256(gate.checkEntry(alice)), uint256(WTGXXGate.Reason.NotWhitelisted));
    }

    /// 컨텍스트를 제거하면 모든 주소가 즉시 비화이트리스트가 됩니다.
    function test_rejects_whenKycContextRemoved() public {
        vm.prank(issuer);
        oracle.removeContractAddress(address(kyc));

        assertFalse(gate.canEnter(alice));
    }

    /// 컨텍스트가 늘면 KYC NFT 없이도 통과하는 주소가 생깁니다.
    function test_allows_viaAdditionalContext() public {
        MockKycNFT second = new MockKycNFT(issuer);
        vm.prank(issuer);
        oracle.addContractAddress(address(second));
        vm.prank(issuer);
        second.safeMint(stranger);

        assertTrue(gate.canEnter(stranger));
    }

    /// 게이트는 어떤 경우에도 revert하지 않아야 합니다. 토큰이 아닌 주소를 물어도 마찬가지입니다.
    function test_neverReverts_onNonTokenAddress() public {
        WTGXXGate broken = new WTGXXGate(makeAddr("notAToken"));
        assertFalse(broken.canEnter(alice));
        assertEq(uint256(broken.checkEntry(alice)), uint256(WTGXXGate.Reason.CallFailed));
    }

    function test_constructor_rejectsZeroToken() public {
        vm.expectRevert(WTGXXGate.ZeroAddress.selector);
        new WTGXXGate(address(0));
    }

    /// 동결이 풀리면 다시 통과합니다. 판정은 상태를 따라갑니다.
    function test_recoversAfterUnfreeze() public {
        vm.prank(registrar);
        token.freeze(alice);
        assertFalse(gate.canEnter(alice));

        vm.prank(registrar);
        token.unfreeze(alice);
        assertTrue(gate.canEnter(alice));
    }
}
