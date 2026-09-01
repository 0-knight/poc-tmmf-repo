// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EVaultTestBase} from "euler-vault-kit/test/unit/evault/EVaultTestBase.t.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {TestERC20} from "euler-vault-kit/test/mocks/TestERC20.sol";
import {IRMTestFixed} from "euler-vault-kit/test/mocks/IRMTestFixed.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {IHookTarget} from "evk/interfaces/IHookTarget.sol";

import {CollateralVaultFactory} from "../../src/vault/CollateralVaultFactory.sol";
import {CollateralVaultHook} from "../../src/vault/CollateralVaultHook.sol";
import {WTGXXCollateralVault} from "../../src/vault/WTGXXCollateralVault.sol";
import {FixedOneToOneOracle} from "../../src/oracle/FixedOneToOneOracle.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

/// @title CollateralVaultFactoryTest
/// @notice M3 통과 기준. 볼트 주소가 예측 가능하고, 훅이 share 전송과 타인 예치를 막는가.
contract CollateralVaultFactoryTest is EVaultTestBase {
    // 담보 볼트에 훅으로 걸 연산. 전송과 예치 계열만 가로챕니다.
    // 출금은 걸지 않습니다. 백서 6.1절 출구 무검사.
    uint32 internal constant HOOKED_OPS = 1 << 0 // OP_DEPOSIT
        | 1 << 1 // OP_MINT
        | 1 << 4 // OP_TRANSFER
        | 1 << 5; // OP_SKIM

    TestERC20 internal wtgxx;
    TestERC20 internal usdc;

    EulerRouter internal router;
    FixedOneToOneOracle internal adapter;
    CollateralVaultFactory internal vaultFactory;
    MockKycNFT internal kyc;

    address internal governor = makeAddr("radius-governor");
    address internal issuer = makeAddr("wisdomtree-issuer");
    address internal borrower = makeAddr("borrower");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();

        wtgxx = new TestERC20("Mock WTGXX", "WTGXX", 18, false);
        usdc = new TestERC20("Mock USDC", "USDC", 6, false);
        kyc = new MockKycNFT(issuer);

        router = new EulerRouter(address(evc), governor);
        adapter = new FixedOneToOneOracle(address(wtgxx), 18, address(usdc), 6);
        vm.prank(governor);
        router.govSetConfig(address(wtgxx), address(usdc), address(adapter));

        address impl = address(new WTGXXCollateralVault(integrations, modules));
        vaultFactory = new CollateralVaultFactory(impl, address(router), address(usdc));
    }

    /// @dev borrower의 서브계정 주소. 하위 1바이트를 XOR합니다.
    function _sub(address primary, uint8 id) internal pure returns (address) {
        return address(uint160(uint160(primary) ^ id));
    }

    // --- 주소 예측 ---

    /// 사전 계산과 실제 배포가 일치해야 합니다. 백서 2.2절 독립 검증의 전제입니다.
    function test_addressMatchesPrediction() public {
        address predicted = vaultFactory.computeAddress(borrower, address(wtgxx));
        assertEq(predicted.code.length, 0, unicode"아직 배포되지 않아야 합니다");

        address actual = vaultFactory.deploy(borrower, address(wtgxx));
        assertEq(actual, predicted, unicode"예측 주소와 실제가 다릅니다");
    }

    /// 배포 순서가 주소를 바꾸면 안 됩니다. nonce 기반이면 여기서 깨집니다.
    function test_addressIndependentOfDeploymentOrder() public {
        address predicted = vaultFactory.computeAddress(borrower, address(wtgxx));

        // 다른 차입자를 먼저 배포합니다.
        vaultFactory.deploy(stranger, address(wtgxx));
        address actual = vaultFactory.deploy(borrower, address(wtgxx));

        assertEq(actual, predicted, unicode"배포 순서가 주소를 바꿨습니다");
    }

    /// 자산이 다르면 다른 볼트가 됩니다. salt에 자산이 들어간 이유입니다.
    function test_differentAssetGivesDifferentVault() public {
        address vaultA = vaultFactory.deploy(borrower, address(wtgxx));
        address vaultB = vaultFactory.deploy(borrower, address(usdc));

        assertTrue(vaultA != vaultB);
        assertEq(vaultFactory.vaultOf(borrower, address(wtgxx)), vaultA);
        assertEq(vaultFactory.vaultOf(borrower, address(usdc)), vaultB);
    }

    function test_cannotDeployTwiceForSamePair() public {
        address vault = vaultFactory.deploy(borrower, address(wtgxx));

        vm.expectRevert(
            abi.encodeWithSelector(CollateralVaultFactory.E_AlreadyDeployed.selector, borrower, address(wtgxx), vault)
        );
        vaultFactory.deploy(borrower, address(wtgxx));
    }

    /// 제3자가 대신 배포해도 주소가 같습니다. Radius 백엔드 온보딩 경로입니다.
    function test_anyoneCanDeployWithSameResult() public {
        address predicted = vaultFactory.computeAddress(borrower, address(wtgxx));

        vm.prank(stranger);
        address actual = vaultFactory.deploy(borrower, address(wtgxx));

        assertEq(actual, predicted);
    }

    /// 구현 교체 경로가 없어야 합니다. 백서 2.2절 불변 볼트.
    function test_implementationIsImmutable() public view {
        // setImplementation 계열 함수가 없다는 것을 셀렉터로 확인합니다.
        (bool ok,) = address(vaultFactory).staticcall(abi.encodeWithSignature("setImplementation(address)"));
        assertFalse(ok, unicode"구현 교체 함수가 존재합니다");
    }

    // --- 볼트로서의 동작 ---

    function test_deployedVaultWorksAndReceivesKycNft() public {
        IEVault vault = IEVault(vaultFactory.deploy(borrower, address(wtgxx)));

        assertEq(vault.asset(), address(wtgxx));
        assertEq(vault.oracle(), address(router));
        assertEq(vault.unitOfAccount(), address(usdc));

        vm.prank(issuer);
        kyc.safeMint(address(vault));
        assertEq(kyc.balanceOf(address(vault)), 1);
    }

    /// GenericFactory 레지스트리에 없어도 담보로 인정돼야 합니다.
    function test_vaultAcceptedAsCollateralDespiteBeingUnregistered() public {
        address vault = vaultFactory.deploy(borrower, address(wtgxx));

        assertFalse(factory.isProxy(vault), unicode"팩토리에 등록되어 있으면 안 됩니다");

        eTST2.setLTV(vault, 0.9e4, 0.9e4, 0);
        assertEq(eTST2.LTVBorrow(vault), 0.9e4);
    }

    // --- 훅 ---

    function _deployWithHook() internal returns (IEVault vault, CollateralVaultHook hook) {
        vault = IEVault(vaultFactory.deploy(borrower, address(wtgxx)));
        hook = new CollateralVaultHook(address(evc), borrower);
        vault.setHookConfig(address(hook), HOOKED_OPS);
    }

    function test_hookIdentifiesItself() public {
        CollateralVaultHook hook = new CollateralVaultHook(address(evc), borrower);
        assertEq(hook.isHookTarget(), IHookTarget.isHookTarget.selector);
    }

    /// 소유자는 예치할 수 있습니다.
    function test_ownerCanDeposit() public {
        (IEVault vault,) = _deployWithHook();

        wtgxx.mint(borrower, 100e18);
        vm.startPrank(borrower);
        wtgxx.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, borrower);
        vm.stopPrank();

        assertEq(vault.balanceOf(borrower), 100e18);
    }

    /// 서브계정도 예치할 수 있어야 합니다.
    /// 계정당 컨트롤러가 하나뿐이라 여러 대여자와 동시 거래하려면 필요합니다(백서 7.1절).
    function test_subAccountCanDeposit() public {
        (IEVault vault,) = _deployWithHook();
        address sub = _sub(borrower, 1);

        wtgxx.mint(sub, 50e18);
        vm.startPrank(sub);
        wtgxx.approve(address(vault), type(uint256).max);
        vault.deposit(50e18, sub);
        vm.stopPrank();

        assertEq(vault.balanceOf(sub), 50e18);
    }

    /// 타인은 예치할 수 없습니다. 볼트가 투자자 한 명 전용이어야 합니다(백서 2.2절).
    function test_strangerCannotDeposit() public {
        (IEVault vault,) = _deployWithHook();

        wtgxx.mint(stranger, 10e18);
        vm.startPrank(stranger);
        wtgxx.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultHook.E_DepositorNotOwner.selector, stranger));
        vault.deposit(10e18, stranger);
        vm.stopPrank();
    }

    /// share 전송은 막힙니다. 백서 2.1절이 거부한 래퍼 토큰이 생기지 않게 합니다.
    function test_shareTransferBlocked() public {
        (IEVault vault,) = _deployWithHook();

        wtgxx.mint(borrower, 100e18);
        vm.startPrank(borrower);
        wtgxx.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, borrower);

        vm.expectRevert(CollateralVaultHook.E_ShareTransferDisabled.selector);
        vault.transfer(stranger, 10e18);
        vm.stopPrank();
    }

    function test_shareTransferFromBlocked() public {
        (IEVault vault,) = _deployWithHook();

        wtgxx.mint(borrower, 100e18);
        vm.startPrank(borrower);
        wtgxx.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, borrower);
        vault.approve(stranger, type(uint256).max);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(CollateralVaultHook.E_ShareTransferDisabled.selector);
        vault.transferFrom(borrower, stranger, 10e18);
    }

    /// 서브계정 사이의 share 이동도 막힙니다. 예외를 두지 않습니다.
    function test_shareTransferBlockedEvenBetweenSubAccounts() public {
        (IEVault vault,) = _deployWithHook();

        wtgxx.mint(borrower, 100e18);
        vm.startPrank(borrower);
        wtgxx.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, borrower);

        vm.expectRevert(CollateralVaultHook.E_ShareTransferDisabled.selector);
        vault.transfer(_sub(borrower, 1), 10e18);
        vm.stopPrank();
    }

    /// 출금은 훅에 걸리지 않습니다. 백서 6.1절 출구 무검사.
    function test_withdrawNotHooked() public {
        (IEVault vault,) = _deployWithHook();

        wtgxx.mint(borrower, 100e18);
        vm.startPrank(borrower);
        wtgxx.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, borrower);
        vault.withdraw(40e18, borrower, borrower);
        vm.stopPrank();

        assertEq(wtgxx.balanceOf(borrower), 40e18);
    }

    function test_hookConstructorRejectsZero() public {
        vm.expectRevert(CollateralVaultHook.E_ZeroAddress.selector);
        new CollateralVaultHook(address(0), borrower);

        vm.expectRevert(CollateralVaultHook.E_ZeroAddress.selector);
        new CollateralVaultHook(address(evc), address(0));
    }
}
