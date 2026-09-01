// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";
import {MockComplianceOracle} from "../../src/mocks/MockComplianceOracle.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// onERC721Received가 없는 컨트랙트. EVK 원본 볼트를 대신합니다.
contract NonReceiver {}

/// onERC721Received를 구현한 컨트랙트. M2 포크 후의 볼트를 대신합니다.
contract GoodReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// 잘못된 매직값을 돌려주는 컨트랙트.
contract BadReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

contract MocksTest is Test {
    MockWTGXX internal token;
    MockUSDC internal usdc;
    MockKycNFT internal kyc;
    MockComplianceOracle internal oracle;

    address internal registrar = makeAddr("registrar");
    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        kyc = new MockKycNFT(issuer);
        oracle = new MockComplianceOracle(issuer, address(kyc));
        token = new MockWTGXX(registrar, address(oracle), makeAddr("impl"));
        usdc = new MockUSDC();

        vm.startPrank(issuer);
        kyc.safeMint(alice);
        kyc.safeMint(bob);
        vm.stopPrank();

        vm.prank(registrar);
        token.mint(alice, 1_000e18);
    }

    // --- decimals ---

    function test_decimals_matchRealDeployment() public view {
        assertEq(token.decimals(), 18);
        assertEq(usdc.decimals(), 6);
    }

    // --- 화이트리스트는 to만 봅니다 ---

    function test_whitelist_checksDestinationOnly() public {
        // alice(화이트리스트) -> stranger(비화이트리스트): 막힘
        vm.prank(alice);
        vm.expectRevert(MockWTGXX.AddressNotWhitelisted.selector);
        token.transfer(stranger, 1e18);

        // alice -> bob: 통과
        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }

    /// from은 판정에 쓰이지 않습니다. 인자를 바꿔도 결과가 같습니다.
    function test_whitelist_ignoresFromAndAmount() public view {
        assertTrue(token.isAddressWhitelisted(address(0), alice, 0));
        assertTrue(token.isAddressWhitelisted(stranger, alice, type(uint256).max));
        assertFalse(token.isAddressWhitelisted(alice, stranger, 0));
    }

    /// 컴플라이언스가 0이면 검사를 건너뛰고 무조건 통과합니다.
    function test_whitelist_skippedWhenComplianceRemoved() public {
        vm.prank(registrar);
        token.setCompliance(address(0));

        assertTrue(token.isAddressWhitelisted(address(0), stranger, 0));

        vm.prank(alice);
        token.transfer(stranger, 1e18);
        assertEq(token.balanceOf(stranger), 1e18);
    }

    // --- 동결은 세 주소를 다 봅니다 ---

    function test_freeze_blocksSender() public {
        vm.prank(registrar);
        token.freeze(alice);

        vm.prank(alice);
        vm.expectRevert(MockWTGXX.FrozenAccount.selector);
        token.transfer(bob, 1e18);
    }

    function test_freeze_blocksRecipient() public {
        vm.prank(registrar);
        token.freeze(bob);

        vm.prank(alice);
        vm.expectRevert(MockWTGXX.FrozenAccount.selector);
        token.transfer(bob, 1e18);
    }

    /// transferFrom은 from, msg.sender, to 셋 다 봅니다.
    function test_freeze_transferFrom_blocksSpender() public {
        vm.prank(alice);
        token.approve(stranger, 10e18);

        vm.prank(registrar);
        token.freeze(stranger);

        vm.prank(stranger);
        vm.expectRevert(MockWTGXX.FrozenAccount.selector);
        token.transferFrom(alice, bob, 1e18);
    }

    function test_freeze_transferFrom_blocksFrom() public {
        vm.prank(alice);
        token.approve(stranger, 10e18);

        vm.prank(registrar);
        token.freeze(alice);

        vm.prank(stranger);
        vm.expectRevert(MockWTGXX.FrozenAccount.selector);
        token.transferFrom(alice, bob, 1e18);
    }

    // --- 자기 자신에게 전송 불가 ---

    function test_transfer_toSelf_reverts() public {
        vm.prank(alice);
        vm.expectRevert(MockWTGXX.CannotTransferToYourself.selector);
        token.transfer(alice, 1e18);
    }

    /// 값이 0이면 자기 전송도 통과합니다. 실물 _transfer의 조건이 value > 0입니다.
    function test_transfer_toSelfZeroValue_passes() public {
        vm.prank(alice);
        token.transfer(alice, 0);
    }

    // --- 일시정지 ---

    function test_pause_blocksTransfers() public {
        vm.prank(registrar);
        token.pause();

        vm.prank(alice);
        vm.expectRevert(MockWTGXX.ContractPaused.selector);
        token.transfer(bob, 1e18);
    }

    // --- 배치는 전부 아니면 전무 ---

    function test_batchTransfer_allOrNothing() public {
        address[] memory toList = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        toList[0] = bob;
        toList[1] = stranger; // 비화이트리스트
        amounts[0] = 1e18;
        amounts[1] = 1e18;

        vm.prank(alice);
        vm.expectRevert(MockWTGXX.AddressNotWhitelisted.selector);
        token.batchTransfer(toList, amounts);

        // 첫 행도 반영되지 않았습니다.
        assertEq(token.balanceOf(bob), 0);
    }

    function test_batchTransfer_succeedsWhenAllValid() public {
        address[] memory toList = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        toList[0] = bob;
        toList[1] = bob;
        amounts[0] = 1e18;
        amounts[1] = 2e18;

        vm.prank(alice);
        token.batchTransfer(toList, amounts);
        assertEq(token.balanceOf(bob), 3e18);
    }

    // --- 이슈어 경로 ---

    /// burn은 allowance가 필요 없습니다.
    function test_burn_needsNoAllowance() public {
        assertEq(token.allowance(alice, registrar), 0);

        vm.prank(registrar);
        token.burn(alice, 100e18);
        assertEq(token.balanceOf(alice), 900e18);
    }

    function test_burn_rejectsNonRegistrar() public {
        vm.prank(alice);
        vm.expectRevert(MockWTGXX.NotRegistrar.selector);
        token.burn(alice, 1e18);
    }

    function test_mint_rejectsZeroValue() public {
        vm.prank(registrar);
        vm.expectRevert(MockWTGXX.InvalidValue.selector);
        token.mint(alice, 0);
    }

    /// clawback은 목적지 화이트리스트가 필수입니다.
    function test_clawback_requiresWhitelistedDestination() public {
        vm.prank(registrar);
        vm.expectRevert(MockWTGXX.AddressNotWhitelisted.selector);
        token.clawback(alice, stranger, 10e18);

        vm.prank(registrar);
        token.clawback(alice, bob, 10e18);
        assertEq(token.balanceOf(bob), 10e18);
    }

    // --- KYC NFT: 소울바운드 + safeMint ---

    /// M2가 필요한 이유입니다. onERC721Received가 없으면 safeMint가 실패합니다.
    function test_safeMint_revertsForNonReceiverContract() public {
        NonReceiver vault = new NonReceiver();

        vm.prank(issuer);
        vm.expectRevert(MockKycNFT.NonReceiverImplementer.selector);
        kyc.safeMint(address(vault));

        assertEq(kyc.balanceOf(address(vault)), 0);
    }

    /// 포크 후 볼트가 이렇게 동작해야 합니다.
    function test_safeMint_succeedsForReceiverContract() public {
        GoodReceiver vault = new GoodReceiver();

        vm.prank(issuer);
        kyc.safeMint(address(vault));

        assertEq(kyc.balanceOf(address(vault)), 1);
    }

    function test_safeMint_revertsOnWrongMagicValue() public {
        BadReceiver vault = new BadReceiver();

        vm.prank(issuer);
        vm.expectRevert(MockKycNFT.NonReceiverImplementer.selector);
        kyc.safeMint(address(vault));
    }

    function test_safeMint_toEoaNeedsNoCallback() public {
        address eoa = makeAddr("eoa");
        vm.prank(issuer);
        kyc.safeMint(eoa);
        assertEq(kyc.balanceOf(eoa), 1);
    }

    function test_kyc_transfersAlwaysRevert() public {
        vm.prank(alice);
        vm.expectRevert(MockKycNFT.NotTransferable.selector);
        kyc.transferFrom(alice, bob, 1);

        vm.prank(alice);
        vm.expectRevert(MockKycNFT.NotTransferable.selector);
        kyc.approve(bob, 1);
    }

    function test_kyc_onlyMinterCanMint() public {
        vm.prank(alice);
        vm.expectRevert(MockKycNFT.NotMinter.selector);
        kyc.safeMint(stranger);
    }

    // --- 오라클 ---

    function test_oracle_revertsOnZeroDestination() public {
        vm.expectRevert(MockComplianceOracle.OracleZeroAddressNotAllowed.selector);
        oracle.canTransfer(alice, address(0), 1e18);
    }

    /// 비활성일 때는 revert가 아니라 false입니다. zero 주소여도 false입니다.
    function test_oracle_disabledReturnsFalseNotRevert() public {
        vm.prank(issuer);
        oracle.disableOracle();

        assertFalse(oracle.canTransfer(alice, alice, 1e18));
        assertFalse(oracle.canTransfer(alice, address(0), 1e18));
    }

    function test_oracle_maxContextsIsTen() public view {
        assertEq(oracle.getMaxContexts(), 10);
        assertEq(oracle.getContractAddresses().length, 1);
    }

    // --- USDC ---

    function test_usdc_freeMinting() public {
        usdc.mint(alice, 1_000e6);
        assertEq(usdc.balanceOf(alice), 1_000e6);

        vm.prank(alice);
        usdc.transfer(bob, 400e6);
        assertEq(usdc.balanceOf(bob), 400e6);
    }

    function test_usdc_transferFromRespectsAllowance() public {
        usdc.mint(alice, 100e6);
        vm.prank(alice);
        usdc.approve(bob, 40e6);

        vm.prank(bob);
        vm.expectRevert(MockERC20.InsufficientAllowance.selector);
        usdc.transferFrom(alice, bob, 50e6);

        vm.prank(bob);
        usdc.transferFrom(alice, bob, 40e6);
        assertEq(usdc.balanceOf(bob), 40e6);
    }
}
