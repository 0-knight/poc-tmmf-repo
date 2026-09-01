// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EVaultTestBase} from "euler-vault-kit/test/unit/evault/EVaultTestBase.t.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EVault} from "evk/EVault/EVault.sol";

import {WTGXXCollateralVault} from "../../src/vault/WTGXXCollateralVault.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

/// @title WTGXXCollateralVaultTest
/// @notice M2 통과 기준. 담보 볼트가 KYC NFT를 받고, 받은 뒤에도 볼트로서 온전한가.
///
/// @dev EVK의 EVaultTestBase를 그대로 씁니다. 실제 GenericFactory와 BeaconProxy를 거쳐
///      배포된 프록시를 상대로 검증하므로, delegatecall 경로와 트레일링 메타데이터가
///      포함된 상태에서의 동작을 봅니다.
contract WTGXXCollateralVaultTest is EVaultTestBase {
    MockKycNFT internal kyc;
    address internal issuer;

    function setUp() public override {
        super.setUp();
        issuer = makeAddr("wisdomtree-issuer");
        kyc = new MockKycNFT(issuer);
    }

    /// @dev Radius 구현을 팩토리에 올리고 프록시를 하나 만듭니다.
    function _deployRadiusVault() internal returns (IEVault vault) {
        address impl = address(new WTGXXCollateralVault(integrations, modules));
        vm.prank(admin);
        factory.setImplementation(impl);

        vault = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(assetTST), address(oracle), unitOfAccount))
        );
        vault.setHookConfig(address(0), 0);
    }

    // --- 대비 증명 ---

    /// EVault 원본 프록시는 KYC NFT를 받지 못합니다. Layer 1이 성립하지 않습니다.
    function test_stockEVault_cannotReceiveKycNft() public {
        vm.prank(issuer);
        vm.expectRevert(MockKycNFT.NonReceiverImplementer.selector);
        kyc.safeMint(address(eTST));

        assertEq(kyc.balanceOf(address(eTST)), 0);
    }

    /// Radius 볼트는 받습니다. 이것이 M2의 통과 조건입니다.
    function test_radiusVault_receivesKycNft() public {
        IEVault vault = _deployRadiusVault();

        vm.prank(issuer);
        kyc.safeMint(address(vault));

        assertEq(kyc.balanceOf(address(vault)), 1);
    }

    /// 프록시가 붙이는 트레일링 메타데이터가 있어도 매직값이 정확히 나와야 합니다.
    function test_radiusVault_returnsCorrectMagicValue() public {
        IEVault vault = _deployRadiusVault();

        (bool ok, bytes memory ret) = address(vault)
            .call(
                abi.encodeWithSignature(
                    "onERC721Received(address,address,uint256,bytes)",
                    address(this),
                    address(0),
                    uint256(7),
                    hex"deadbeef"
                )
            );

        assertTrue(ok, unicode"프록시를 거친 호출이 실패했습니다");
        assertEq(abi.decode(ret, (bytes4)), bytes4(0x150b7a02));
    }

    // --- 회귀 확인 ---

    /// 볼트 기능이 그대로여야 합니다. 상속만 했으므로 당연하지만 확인합니다.
    function test_radiusVault_retainsDepositAndWithdraw() public {
        IEVault vault = _deployRadiusVault();

        address depositor = makeAddr("depositor");
        assetTST.mint(depositor, 100e18);

        vm.startPrank(depositor);
        assetTST.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, depositor);

        assertEq(vault.balanceOf(depositor), 100e18);
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.asset(), address(assetTST));

        vault.withdraw(40e18, depositor, depositor);
        vm.stopPrank();

        assertEq(assetTST.balanceOf(depositor), 40e18);
        assertEq(vault.totalAssets(), 60e18);
    }

    /// NFT를 받은 뒤에도 볼트 회계가 흔들리지 않아야 합니다.
    function test_radiusVault_unaffectedByReceivingNft() public {
        IEVault vault = _deployRadiusVault();

        address depositor = makeAddr("depositor");
        assetTST.mint(depositor, 100e18);

        vm.startPrank(depositor);
        assetTST.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, depositor);
        vm.stopPrank();

        uint256 sharesBefore = vault.balanceOf(depositor);
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(issuer);
        kyc.safeMint(address(vault));

        assertEq(vault.balanceOf(depositor), sharesBefore);
        assertEq(vault.totalAssets(), assetsBefore);
    }

    /// 여러 번 받아도 됩니다. 컨텍스트가 늘어나는 경우에 대비합니다.
    function test_radiusVault_acceptsMultipleNfts() public {
        IEVault vault = _deployRadiusVault();

        vm.startPrank(issuer);
        kyc.safeMint(address(vault));
        kyc.safeMint(address(vault));
        vm.stopPrank();

        assertEq(kyc.balanceOf(address(vault)), 2);
    }

    // --- 크기 ---

    /// EVault가 이미 한계에 근접해 있습니다. 여유를 명시적으로 고정합니다.
    /// 이 테스트가 깨지면 볼트에 더는 로직을 얹을 수 없다는 신호입니다.
    function test_radiusVault_fitsInContractSizeLimit() public {
        address impl = address(new WTGXXCollateralVault(integrations, modules));
        uint256 size = impl.code.length;

        assertLt(size, 24576, unicode"컨트랙트 크기 한계 초과");
        assertGt(24576 - size, 500, unicode"여유가 500바이트 미만입니다");

        emit log_named_uint("radius vault size", size);
        emit log_named_uint("headroom", 24576 - size);
    }
}
