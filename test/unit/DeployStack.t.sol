// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";
import {CollateralVaultFactory} from "../../src/vault/CollateralVaultFactory.sol";
import {FixedRateIRM} from "../../src/irm/FixedRateIRM.sol";
import {WTGXXGate} from "../../src/gate/WTGXXGate.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";
import {CollateralVaultHook} from "../../src/vault/CollateralVaultHook.sol";

/// @title DeployStackTest
/// @notice M4 통과 기준. 스택 전체가 배포되고, 배선이 맞고, 실제로 대출이 열리는가.
///
/// @dev 단위 테스트는 컨트랙트를 하나씩 봤습니다. 이 테스트는 배포 스크립트가 만든
///      구성으로 개시부터 상환까지 돌려봅니다. 생성자 인자 순서나 배포 순서 의존성처럼
///      단위 테스트에서 드러나지 않는 문제가 여기서 잡힙니다.
contract DeployStackTest is Test {
    DeployStack internal deployer;
    DeployStack.Deployment internal d;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal stranger = makeAddr("stranger");

    address internal vault;
    address internal hook;

    function setUp() public {
        deployer = new DeployStack();
        d = deployer.run();

        // 목업 경로에서는 배포자가 발행 권한을 갖습니다.
        // 스크립트가 broadcast 없이 돌았으므로 이 테스트 컨트랙트가 배포자입니다.
        (vault, hook) = deployer.deployCollateralVault(d, borrower);
    }

    // --- 배선 ---

    function test_debtVaultConfigured() public view {
        IEVault debtVault = IEVault(d.debtVault);

        assertEq(debtVault.asset(), d.usdc);
        assertEq(debtVault.oracle(), d.router);
        assertEq(debtVault.unitOfAccount(), d.usdc);
        assertEq(debtVault.interestRateModel(), d.irm);
        assertEq(debtVault.configFlags(), 1, unicode"부실채권 사회화가 켜져 있습니다");
    }

    function test_collateralVaultConfigured() public view {
        IEVault v = IEVault(vault);

        assertEq(v.asset(), d.wtgxx);
        assertEq(v.oracle(), d.router, unicode"오라클 자리에 라우터가 아닌 것이 들어갔습니다");
        assertEq(v.unitOfAccount(), d.usdc);

        // 두 LTV가 벌어져 있어야 합니다. 같으면 한도까지 빌린 계정이 곧바로 청산 대상입니다.
        assertEq(IEVault(d.debtVault).LTVBorrow(vault), 0.92e4, unicode"개시 한도가 92%가 아닙니다");
        assertEq(IEVault(d.debtVault).LTVLiquidation(vault), 0.95e4, unicode"청산선이 95%가 아닙니다");
        assertLt(
            IEVault(d.debtVault).LTVBorrow(vault),
            IEVault(d.debtVault).LTVLiquidation(vault),
            unicode"두 LTV가 한 점에 붙어 있습니다"
        );
    }

    /// 청산 파라미터를 배포 스크립트가 못 박아야 합니다. EVK 기본값에 기대지 않습니다.
    function test_liquidationParamsConfigured() public view {
        IEVault debtVault = IEVault(d.debtVault);

        assertEq(debtVault.maxLiquidationDiscount(), 0.02e4, unicode"청산 할인 한도가 2%가 아닙니다");
        assertEq(debtVault.liquidationCoolOffTime(), 0, unicode"청산 쿨오프가 0이 아닙니다");
    }

    /// 주소를 배포 전에 알 수 있어야 합니다. 백서 2.2절.
    function test_vaultAddressWasPredictable() public view {
        address predicted = CollateralVaultFactory(d.collateralVaultFactory).computeAddress(borrower, d.wtgxx);
        assertEq(vault, predicted);
    }

    function test_routerResolvesCollateralVault() public view {
        uint256 out = EulerRouter(d.router).getQuote(100e18, vault, d.usdc);
        assertEq(out, 100e6, unicode"라우터가 볼트를 해석하지 못했습니다");
    }

    // --- 게이트와 만기 ---

    /// 게이트는 KYC NFT 발행 전에 거부해야 합니다.
    function test_gateRejectsBeforeKycNft() public view {
        assertFalse(WTGXXGate(d.gate).canEnter(borrower));
    }

    function test_gateAllowsAfterKycNft() public {
        MockKycNFT(d.kycNft).safeMint(borrower);
        assertTrue(WTGXXGate(d.gate).canEnter(borrower));
    }

    /// 배포 시점에 시장의 만기가 공표돼 있어야 합니다. 백서 3.1절.
    function test_marketMaturityPublished() public view {
        MaturityRegistry reg = MaturityRegistry(d.maturityRegistry);

        assertEq(reg.marketMaturity(d.debtVault), block.timestamp + 7 days);
        assertFalse(reg.isMarketMatured(d.debtVault));
    }

    function test_marketMaturesAfterTerm() public {
        MaturityRegistry reg = MaturityRegistry(d.maturityRegistry);

        skip(7 days);
        assertTrue(reg.isMarketMatured(d.debtVault), unicode"만기가 지났는데 시장이 살아 있습니다");
    }

    /// 열지 않은 시장은 만기가 0입니다. 미개설과 만기 경과를 구분해야 합니다.
    function test_unopenedMarketHasNoMaturity() public view {
        MaturityRegistry reg = MaturityRegistry(d.maturityRegistry);

        assertEq(reg.marketMaturity(vault), 0);
        assertFalse(reg.isMarketMatured(vault));
    }

    function test_maturityRegistryUsable() public {
        uint256 maturity = block.timestamp + 7 days;
        vm.prank(borrower);
        MaturityRegistry(d.maturityRegistry).setMaturity(borrower, maturity);

        assertFalse(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));
        skip(7 days + 1);
        assertTrue(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));
    }

    // --- 훅이 붙어 있는가 ---

    /// 볼트와 타인 모두 화이트리스트인 상태에서도 훅이 막아야 합니다.
    /// 화이트리스트로 막히면 훅을 검증한 것이 아닙니다.
    function test_hookBlocksStrangerDeposit() public {
        MockKycNFT(d.kycNft).safeMint(vault);
        MockKycNFT(d.kycNft).safeMint(stranger);
        MockWTGXX(d.wtgxx).mint(stranger, 10e18);

        vm.startPrank(stranger);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultHook.E_DepositorNotOwner.selector, stranger));
        IEVault(vault).deposit(10e18, stranger);
        vm.stopPrank();
    }

    function test_hookBlocksShareTransfer() public {
        _fundAndDeposit(100e18);

        vm.prank(borrower);
        vm.expectRevert(CollateralVaultHook.E_ShareTransferDisabled.selector);
        IEVault(vault).transfer(stranger, 1e18);
    }

    // --- 전체 흐름 ---

    /// 개시부터 상환까지 배포된 구성 그대로 돌아야 합니다.
    function test_openAndRepay() public {
        _fundLender(1_000e6);
        _fundAndDeposit(100e18);

        EthereumVaultConnector evc = EthereumVaultConnector(payable(d.evc));

        vm.startPrank(borrower);
        evc.enableCollateral(borrower, vault);
        evc.enableController(borrower, d.debtVault);
        IEVault(d.debtVault).borrow(80e6, borrower);
        vm.stopPrank();

        assertEq(MockUSDC(d.usdc).balanceOf(borrower), 80e6);

        // 부채가 있는 동안 담보가 잠깁니다.
        vm.prank(borrower);
        vm.expectRevert();
        IEVault(vault).withdraw(30e18, borrower, borrower);

        skip(7 days);

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        assertGt(debt, 80e6, unicode"이자가 붙지 않았습니다");

        // 이자만큼 더 채워 상환합니다.
        MockUSDC(d.usdc).mint(borrower, debt - 80e6);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        evc.disableController(d.debtVault);

        // 같은 호출이 이제 통과합니다.
        IEVault(vault).withdraw(100e18, borrower, borrower);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), 100e18);
        assertEq(IEVault(d.debtVault).debtOf(borrower), 0);
    }

    /// 고정 금리가 실제로 적용되는지 확인합니다.
    function test_fixedRateApplied() public view {
        uint256 secondsPerYear = 365.2425 days;
        uint256 expected = (0.5e18 * 1e9) / secondsPerYear;
        assertEq(FixedRateIRM(d.irm).ratePerSecond(), expected);
    }

    // --- 헬퍼 ---

    function _fundLender(uint256 amount) internal {
        MockUSDC(d.usdc).mint(lender, amount);
        vm.startPrank(lender);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).deposit(amount, lender);
        vm.stopPrank();
    }

    function _fundAndDeposit(uint256 amount) internal {
        // 볼트가 WTGXX를 받으려면 화이트리스트여야 합니다.
        MockKycNFT(d.kycNft).safeMint(vault);
        MockKycNFT(d.kycNft).safeMint(borrower);
        MockWTGXX(d.wtgxx).mint(borrower, amount);

        vm.startPrank(borrower);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        IEVault(vault).deposit(amount, borrower);
        vm.stopPrank();
    }
}
