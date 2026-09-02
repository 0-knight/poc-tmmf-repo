// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";
import {RepoOpener} from "../../src/repo/RepoOpener.sol";
import {WTGXXGate} from "../../src/gate/WTGXXGate.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

/// @title RepoScenarioTest
/// @notice M5. 게이트와 만기를 강제한 상태에서 개시부터 정상 종료까지.
///
/// @dev 지금까지의 테스트는 borrow를 직접 불렀습니다. 게이트를 만들어두고 부르지 않았으니
///      백서 6장이 코드로 성립하지 않는 상태였습니다. RepoOpener를 유일한 개시 경로로 두어
///      게이트 통과와 만기 기록을 강제합니다.
///
///      종료 경로는 RepoOpener를 거치지 않습니다. 백서 6.1절이 출구 무검사를 요구하며,
///      차입자는 부채 볼트와 담보 볼트를 직접 호출해 상환하고 인출합니다.
contract RepoScenarioTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    RepoOpener internal opener;
    EthereumVaultConnector internal evc;

    address internal vault;
    address internal hook;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant PRINCIPAL = 80e6;
    uint256 internal constant TERM = 7 days;

    function setUp() public {
        deployScript = new DeployStack();
        d = deployScript.run();
        (vault, hook) = deployScript.deployCollateralVault(d, borrower);

        evc = EthereumVaultConnector(payable(d.evc));
        opener = RepoOpener(d.repoOpener);

        // 대여자 자금 공급.
        MockUSDC(d.usdc).mint(lender, 1_000e6);
        vm.startPrank(lender);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).deposit(1_000e6, lender);
        vm.stopPrank();

        // 온보딩: 볼트와 참여자 화이트리스트.
        MockKycNFT(d.kycNft).safeMint(vault);
        MockKycNFT(d.kycNft).safeMint(borrower);
        MockKycNFT(d.kycNft).safeMint(lender);

        MockWTGXX(d.wtgxx).mint(borrower, COLLATERAL);
    }

    /// @dev 차입자 쪽 준비. approve 와 operator 등록.
    function _prepareBorrower() internal {
        vm.startPrank(borrower);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        evc.setAccountOperator(borrower, address(opener), true);
        vm.stopPrank();
    }

    function _open() internal returns (uint256 maturity) {
        _prepareBorrower();
        maturity = block.timestamp + TERM;

        vm.prank(borrower);
        opener.open(vault, COLLATERAL, PRINCIPAL, maturity, lender);
    }

    // --- 개시 ---

    function test_open_succeeds() public {
        uint256 maturity = _open();

        assertEq(MockUSDC(d.usdc).balanceOf(borrower), PRINCIPAL);
        assertEq(IEVault(vault).balanceOf(borrower), COLLATERAL);
        assertEq(IEVault(d.debtVault).debtOf(borrower), PRINCIPAL);
        assertEq(MaturityRegistry(d.maturityRegistry).maturityOf(borrower), maturity);
    }

    /// operator 등록 없이는 열 수 없습니다.
    function test_open_requiresOperator() public {
        vm.prank(borrower);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(RepoOpener.E_NotOperator.selector, borrower));
        opener.open(vault, COLLATERAL, PRINCIPAL, block.timestamp + TERM, lender);
    }

    /// 화이트리스트 없는 차입자는 막힙니다. 백서 6.1절.
    function test_open_rejectsUnwhitelistedBorrower() public {
        _prepareBorrower();

        // 컴플라이언스 오라클에서 차입자 자격을 없앱니다.
        MockWTGXX(d.wtgxx).freeze(borrower);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(RepoOpener.E_BorrowerNotEligible.selector, borrower));
        opener.open(vault, COLLATERAL, PRINCIPAL, block.timestamp + TERM, lender);
    }

    /// 대여자도 검사합니다. 백서 3.5절 — 청산 시 담보를 직접 받아야 하므로.
    function test_open_rejectsUnwhitelistedLender() public {
        _prepareBorrower();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(RepoOpener.E_LenderNotEligible.selector, stranger));
        opener.open(vault, COLLATERAL, PRINCIPAL, block.timestamp + TERM, stranger);
    }

    /// 컴플라이언스가 제거되면 토큰은 통과시키지만 게이트가 막습니다.
    function test_open_rejectsWhenComplianceRemoved() public {
        _prepareBorrower();
        MockWTGXX(d.wtgxx).setCompliance(address(0));

        assertTrue(MockWTGXX(d.wtgxx).isAddressWhitelisted(address(0), borrower, 0));

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(RepoOpener.E_BorrowerNotEligible.selector, borrower));
        opener.open(vault, COLLATERAL, PRINCIPAL, block.timestamp + TERM, lender);
    }

    /// 과거 만기는 거부합니다.
    function test_open_rejectsPastMaturity() public {
        _prepareBorrower();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(RepoOpener.E_MaturityNotInFuture.selector, block.timestamp));
        opener.open(vault, COLLATERAL, PRINCIPAL, block.timestamp, lender);
    }

    /// 담보 자산이 다른 볼트는 거부합니다. 임의 볼트 주입을 막습니다.
    function test_open_rejectsWrongVault() public {
        _prepareBorrower();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(RepoOpener.E_VaultMismatch.selector, d.wtgxx, d.usdc));
        opener.open(d.debtVault, COLLATERAL, PRINCIPAL, block.timestamp + TERM, lender);
    }

    /// 개시가 실패하면 만기 기록도 남지 않아야 합니다. 원자성 확인.
    function test_open_atomicOnFailure() public {
        _prepareBorrower();

        // 담보 대비 과도한 차입으로 실패시킵니다.
        vm.prank(borrower);
        vm.expectRevert();
        opener.open(vault, COLLATERAL, 200e6, block.timestamp + TERM, lender);

        assertEq(MaturityRegistry(d.maturityRegistry).maturityOf(borrower), 0);
        assertEq(IEVault(vault).balanceOf(borrower), 0);
    }

    // --- S3 담보 잠김 ---

    /// PoC의 핵심 판정. 부채가 있는 동안 담보가 나가지 못합니다.
    function test_collateralLockedWhileDebtOutstanding() public {
        _open();

        vm.prank(borrower);
        vm.expectRevert();
        IEVault(vault).withdraw(30e18, borrower, borrower);

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), 0);
    }

    /// 전액 인출도 막힙니다.
    function test_fullWithdrawBlocked() public {
        _open();

        vm.prank(borrower);
        vm.expectRevert();
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
    }

    // --- S5 정상 종료 ---

    /// 종료 경로는 RepoOpener를 거치지 않습니다. 백서 6.1절 출구 무검사.
    function test_repayAndWithdraw() public {
        _open();
        skip(TERM);

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        assertGt(debt, PRINCIPAL, unicode"이자가 붙지 않았습니다");
        MockUSDC(d.usdc).mint(borrower, debt - PRINCIPAL);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        evc.disableController(d.debtVault);

        // 잠겼던 것과 같은 호출이 이제 통과합니다.
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL);
        assertEq(IEVault(d.debtVault).debtOf(borrower), 0);
    }

    /// 화이트리스트에서 빠져도 상환과 인출은 통과해야 합니다.
    /// 그렇지 않으면 접근 통제가 아니라 수탁입니다. 백서 6.1절.
    function test_exitWorksEvenAfterLosingEligibility() public {
        _open();
        skip(TERM);

        // 개시 후 자격을 잃습니다.
        MockWTGXX(d.wtgxx).setCompliance(address(0));
        assertFalse(WTGXXGate(d.gate).canEnter(borrower));

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        MockUSDC(d.usdc).mint(borrower, debt - PRINCIPAL);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        evc.disableController(d.debtVault);
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL);
    }

    /// 대여자는 원금과 이자를 회수합니다.
    function test_lenderRecoversPrincipalAndInterest() public {
        _open();
        skip(TERM);

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        MockUSDC(d.usdc).mint(borrower, debt - PRINCIPAL);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        vm.stopPrank();

        uint256 shares = IEVault(d.debtVault).balanceOf(lender);
        vm.prank(lender);
        IEVault(d.debtVault).redeem(shares, lender, lender);

        assertGt(MockUSDC(d.usdc).balanceOf(lender), 1_000e6, unicode"대여자가 이자를 못 받았습니다");
    }

    /// 상환 전에는 operator를 취소해도 담보가 잠긴 채입니다.
    /// 컨트롤러는 부채 볼트가 갖고 있으며 opener와 무관합니다.
    function test_revokingOperatorDoesNotFreeCollateral() public {
        _open();

        vm.prank(borrower);
        evc.setAccountOperator(borrower, address(opener), false);

        vm.prank(borrower);
        vm.expectRevert();
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
    }

    // --- M7. 만기 후 이자 누적 ---

    /// 백서 4.4절은 만기에 부채가 멈춰야 한다고 합니다. EVK는 계속 누적합니다.
    /// 초과분을 숫자로 기록해 프로덕션에서 4.4절을 그대로 갈지 정하는 근거로 씁니다.
    ///
    /// @dev EVK 부채는 IRM으로 초당 복리 누적되며 만기 개념이 없습니다. 부채가 계속 자라면
    ///      담보 부족 경로가 연체 경로보다 먼저 발동해 두 청산 사유가 경합합니다. 백서가
    ///      부채를 만기에 고정한 이유입니다.
    function test_debtKeepsAccruingPastMaturity() public {
        _open();

        skip(TERM);
        uint256 debtAtMaturity = IEVault(d.debtVault).debtOf(borrower);

        skip(1 days);
        uint256 debtOneDayLate = IEVault(d.debtVault).debtOf(borrower);

        uint256 excess = debtOneDayLate - debtAtMaturity;

        emit log_named_uint("principal            ", PRINCIPAL);
        emit log_named_uint("debt at maturity     ", debtAtMaturity);
        emit log_named_uint("debt 1 day late      ", debtOneDayLate);
        emit log_named_uint("excess accrual       ", excess);

        assertGt(excess, 0, unicode"만기 후 이자가 멈췄습니다");

        // 하루치는 7일치의 대략 1/7 이어야 합니다. 크게 벗어나면 IRM 설정 오류입니다.
        uint256 sevenDayInterest = debtAtMaturity - PRINCIPAL;
        assertApproxEqRel(excess * 7, sevenDayInterest, 0.05e18);
    }

    /// 8일째 상환도 정상 동작합니다. 초과 이자를 함께 냅니다.
    function test_repayOneDayLate() public {
        _open();
        skip(TERM + 1 days);

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        MockUSDC(d.usdc).mint(borrower, debt - PRINCIPAL);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        evc.disableController(d.debtVault);
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL);
        assertEq(IEVault(d.debtVault).debtOf(borrower), 0);
    }

    // --- 만기 ---

    function test_maturityRecordedAndDefaultDetected() public {
        _open();

        assertFalse(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));
        skip(TERM + 1);
        assertTrue(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));
    }
}
