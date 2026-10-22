// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";
import {RepoOpener} from "../../src/repo/RepoOpener.sol";
import {MaturityController} from "../../src/repo/MaturityController.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";
import {FixedRateIRM} from "../../src/irm/FixedRateIRM.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

/// @title ChainCycleTest
/// @notice Wave 4. 사다리 세 칸이 정상으로 돌고 풀린다 — A → B → C → D.
///
/// @dev Wave 3이 두 칸을 세웠고 여기서 세 칸으로 늘립니다. 칸이 하나 더 붙으면서 두
///      가지가 처음 보입니다.
///
///      **1. 스프레드가 없으면 사다리가 무너집니다.**
///
///      Wave 3까지 모든 칸이 같은 금리 모델을 썼습니다. 그러면 중간 참여자는 받는 이자와
///      내는 이자가 같은데, EVK가 볼트마다 이자의 10%를 수수료로 뗍니다
///      (`Initialize.DEFAULT_INTEREST_FEE`). 받는 쪽에서 10%가 깎여 나가고 내는 쪽은
///      전액이니 중간은 **구조적으로 손해**입니다. 칸이 늘수록 쌓입니다.
///
///      그래서 Wave 4에서 `deployRung` 이 칸마다 금리를 받습니다. 아래 칸에서 받는
///      금리가 위 칸에 내는 금리보다 높아야 합니다 — 전통 repo의 매치북이 그렇게
///      돕니다. 여기서는 50% → 40% → 30% 로 두었습니다.
///
///      **2. 풀리는 순서가 강제됩니다.**
///
///      B의 현금은 A에게 나가 있고, B의 지분은 C에게 담보로 잡혀 있습니다. B가 환매하려면
///      먼저 C에게 갚아야 하고, C에게 갚을 현금을 만들려면 A가 갚아야 합니다. 칸이 셋이면
///      그 사슬이 셋입니다 — 꼭대기 D의 현금 회수는 맨 아래 A의 상환에 달려 있습니다.
///
///      코드로 강제한 것이 아니라 **담보 잠금과 볼트 현금에서 저절로 나옵니다.**
contract ChainCycleTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    DeployStack.Rung internal rungC;
    DeployStack.Rung internal rungD;

    MaturityRegistry internal maturities;
    EthereumVaultConnector internal evc;

    address internal vaultA;
    address internal vaultB;
    address internal vaultC;
    address internal vaultD;

    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");
    address internal D = makeAddr("D");

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant SUPPLY = 100e6;
    uint256 internal constant A_BORROWS = 80e6;
    uint256 internal constant B_BORROWS = 80e6;
    uint256 internal constant C_BORROWS = 70e6;
    uint256 internal constant WALLET = 1_000e6;
    uint256 internal constant TERM = 7 days;

    uint256 internal constant RUNG_C_APR = 0.40e18;
    uint256 internal constant RUNG_D_APR = 0.30e18;

    function setUp() public {
        deployScript = new DeployStack();
        d = deployScript.run();
        (vaultA,) = deployScript.deployCollateralVault(d, A);
        vaultB = d.debtVault;

        rungC = deployScript.deployRung(d, vaultB, 0.85e4, 0.90e4, RUNG_C_APR);
        vaultC = rungC.debtVault;
        rungD = deployScript.deployRung(d, vaultC, 0.78e4, 0.85e4, RUNG_D_APR);
        vaultD = rungD.debtVault;

        evc = EthereumVaultConnector(payable(d.evc));
        maturities = MaturityRegistry(d.maturityRegistry);

        MockKycNFT(d.kycNft).safeMint(vaultA);
        MockKycNFT(d.kycNft).safeMint(A);
        MockKycNFT(d.kycNft).safeMint(B);
        MockKycNFT(d.kycNft).safeMint(C);
        MockKycNFT(d.kycNft).safeMint(D);

        MockWTGXX(d.wtgxx).mint(A, COLLATERAL);
        MockUSDC(d.usdc).mint(B, WALLET);
        MockUSDC(d.usdc).mint(C, WALLET);
        MockUSDC(d.usdc).mint(D, WALLET);

        _approveAll(A);
        _approveAll(B);
        _approveAll(C);
        _approveAll(D);

        vm.prank(D);
        IEVault(vaultD).deposit(SUPPLY, D);
        vm.prank(C);
        IEVault(vaultC).deposit(SUPPLY, C);
        vm.prank(B);
        IEVault(vaultB).deposit(SUPPLY, B);

        _open(A, vaultA, COLLATERAL, A_BORROWS, d.repoOpener, B);
        _open(B, vaultB, 0, B_BORROWS, rungC.opener, C);
        _open(C, vaultC, 0, C_BORROWS, rungD.opener, D);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        MockUSDC(d.usdc).approve(vaultB, type(uint256).max);
        MockUSDC(d.usdc).approve(vaultC, type(uint256).max);
        MockUSDC(d.usdc).approve(vaultD, type(uint256).max);
        vm.stopPrank();
    }

    function _open(
        address borrower,
        address collateralVault,
        uint256 collateralAmount,
        uint256 principal,
        address opener,
        address lender
    ) internal {
        vm.startPrank(borrower);
        if (collateralAmount > 0) MockWTGXX(d.wtgxx).approve(collateralVault, type(uint256).max);
        evc.setAccountOperator(borrower, opener, true);
        RepoOpener(opener).open(collateralVault, collateralAmount, principal, maturities.marketMaturity(vaultB), lender);
        vm.stopPrank();
    }

    /// @dev 이자만큼 지갑을 메워 줍니다. 차입자는 원금만 받았으므로 이자는 밖에서 옵니다.
    function _topUp(address who, uint256 amount) internal {
        MockUSDC(d.usdc).mint(who, amount);
    }

    // --- 배선 ---

    /// 사다리는 한 날짜에 끝납니다. 칸마다 만기가 다르면 중간이 받기 전에 내야 합니다.
    function test_threeRungsShareOneMaturity() public view {
        uint256 m = maturities.marketMaturity(vaultB);
        assertEq(maturities.marketMaturity(vaultC), m);
        assertEq(maturities.marketMaturity(vaultD), m);
        assertEq(maturities.maturityOf(A), m);
        assertEq(maturities.maturityOf(B), m);
        assertEq(maturities.maturityOf(C), m);
    }

    /// 칸을 올라갈수록 금리가 내려갑니다. 그 폭이 중간 참여자의 몫입니다.
    function test_ratesDescendUpTheLadder() public view {
        uint256 rateB = FixedRateIRM(IEVault(vaultB).interestRateModel()).ratePerSecond();
        uint256 rateC = FixedRateIRM(IEVault(vaultC).interestRateModel()).ratePerSecond();
        uint256 rateD = FixedRateIRM(IEVault(vaultD).interestRateModel()).ratePerSecond();

        assertGt(rateB, rateC, unicode"V_B가 V_C보다 금리가 낮습니다");
        assertGt(rateC, rateD, unicode"V_C가 V_D보다 금리가 낮습니다");

        // 칸마다 자기 모델입니다. 하나를 바꿔도 다른 칸이 따라 움직이지 않습니다.
        assertTrue(IEVault(vaultC).interestRateModel() != IEVault(vaultB).interestRateModel());
        assertTrue(IEVault(vaultD).interestRateModel() != IEVault(vaultC).interestRateModel());
        assertEq(IEVault(vaultC).interestRateModel(), rungC.irm);
        assertEq(IEVault(vaultD).interestRateModel(), rungD.irm);
    }

    // --- 순서 ---

    /// 담보로 잡힌 지분은 위 칸에 갚기 전까지 꼼짝하지 않습니다.
    function test_pledgedSharesAreLockedUntilTheRungAboveIsRepaid() public {
        skip(TERM);

        // B의 eV_B는 V_C의 담보입니다. 전액 환매도, 담보 여유를 넘는 출금도 안 됩니다.
        uint256 shares = IEVault(vaultB).balanceOf(B);
        vm.prank(B);
        vm.expectRevert();
        IEVault(vaultB).redeem(shares, B, B);

        vm.prank(B);
        vm.expectRevert();
        IEVault(vaultB).withdraw(25e6, B, B);

        // C의 eV_C도 같습니다. 칸이 좁으니(78%) 여유가 더 작습니다.
        vm.prank(C);
        vm.expectRevert();
        IEVault(vaultC).withdraw(30e6, C, C);
    }

    /// 위에 갚아 담보를 풀어도, 볼트에 현금이 없으면 환매가 안 됩니다.
    ///
    /// @dev 잠금과 유동성은 다른 문제입니다. 백서가 "유동성은 가격 문제가 아니다"라고
    ///      적은 지점이며, 칸이 셋이면 그 사슬이 셋으로 늘어납니다.
    function test_unlockedSharesStillNeedCashInTheVault() public {
        skip(TERM);

        // B가 C에게 갚습니다. 이제 eV_B가 풀렸습니다.
        vm.startPrank(B);
        IEVault(vaultC).repay(type(uint256).max, B);
        IEVault(vaultC).disableController();
        vm.stopPrank();

        assertEq(IEVault(vaultC).debtOf(B), 0);

        // 그래도 전액 환매는 안 됩니다. V_B의 현금은 20뿐이고 나머지는 A에게 있습니다.
        uint256 shares = IEVault(vaultB).balanceOf(B);
        vm.prank(B);
        vm.expectRevert();
        IEVault(vaultB).redeem(shares, B, B);

        // 남은 현금만큼은 됩니다.
        uint256 cash = IEVault(vaultB).cash();
        uint256 before = MockUSDC(d.usdc).balanceOf(B);
        vm.prank(B);
        IEVault(vaultB).withdraw(cash, B, B);
        assertEq(MockUSDC(d.usdc).balanceOf(B) - before, cash);
        emit log_named_uint("V_B cash before A repays", cash);
    }

    // --- 정상 종료 ---

    /// 사다리 세 칸이 통째로 풀립니다. 맨 아래의 상환이 꼭대기까지 올라갑니다.
    function test_cycleUnwindsBottomUp() public {
        skip(TERM);

        // 1. A가 갚고 담보를 되찾습니다.
        uint256 debtA = IEVault(vaultB).debtOf(A);
        assertGt(debtA, A_BORROWS, unicode"이자가 붙지 않았습니다");
        _topUp(A, debtA);

        vm.startPrank(A);
        IEVault(vaultB).repay(type(uint256).max, A);
        IEVault(vaultB).disableController();
        IEVault(vaultA).withdraw(COLLATERAL, A, A);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(A), COLLATERAL, unicode"A가 담보를 못 되찾았습니다");
        assertEq(IEVault(vaultB).debtOf(A), 0);

        // 2. B가 C에게 갚고, 풀린 eV_B를 환매합니다. 순서가 반대면 현금이 없습니다.
        uint256 debtB = IEVault(vaultC).debtOf(B);
        uint256 sharesB = IEVault(vaultB).balanceOf(B);
        vm.startPrank(B);
        IEVault(vaultC).repay(type(uint256).max, B);
        IEVault(vaultC).disableController();
        IEVault(vaultB).redeem(sharesB, B, B);
        vm.stopPrank();

        assertEq(IEVault(vaultC).debtOf(B), 0);
        assertEq(IEVault(vaultB).balanceOf(B), 0);

        // 3. C가 D에게 갚고 환매합니다.
        uint256 debtC = IEVault(vaultD).debtOf(C);
        uint256 sharesC = IEVault(vaultC).balanceOf(C);
        vm.startPrank(C);
        IEVault(vaultD).repay(type(uint256).max, C);
        IEVault(vaultD).disableController();
        IEVault(vaultC).redeem(sharesC, C, C);
        vm.stopPrank();

        assertEq(IEVault(vaultD).debtOf(C), 0);
        assertEq(IEVault(vaultC).balanceOf(C), 0);

        // 4. D가 회수합니다. 꼭대기의 현금은 맨 아래 상환이 올라온 것입니다.
        //
        //    지분 수량을 **미리** 읽습니다. `vm.prank` 는 한 번만 쓰이고, 인자 안의
        //    `balanceOf` 가 그 한 번을 먼저 써 버립니다. 그러면 redeem 이 테스트
        //    컨트랙트 권한으로 들어가 E_InsufficientAllowance 로 막힙니다.
        uint256 sharesD = IEVault(vaultD).balanceOf(D);
        vm.prank(D);
        IEVault(vaultD).redeem(sharesD, D, D);
        assertEq(IEVault(vaultD).balanceOf(D), 0);

        emit log_named_uint("A paid     ", debtA);
        emit log_named_uint("B paid     ", debtB);
        emit log_named_uint("C paid     ", debtC);

        // 모든 부채가 0이고, WTGXX는 A에게 돌아갔습니다.
        assertEq(IEVault(vaultB).totalBorrows(), 0);
        assertEq(IEVault(vaultC).totalBorrows(), 0);
        assertEq(IEVault(vaultD).totalBorrows(), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultA), 0);
    }

    /// **칸마다 스프레드가 남습니다.** 중간 둘도 흑자로 끝납니다.
    ///
    /// @dev Wave 3의 금리 한 벌로는 이 테스트가 깨집니다 — 중간이 수수료만큼 적자입니다.
    ///      그래서 `deployRung` 이 칸마다 금리를 받게 바꿨습니다.
    ///
    ///      절대액은 D가 가장 큽니다. 자기 돈을 온전히 댄 유일한 참여자입니다. 투입 대비
    ///      수익률은 로그로 찍어 둡니다 — 단조롭지 않습니다. 금리 폭(10%p)과 순투입(20, 30)과
    ///      볼트 수수료(이자의 10%)가 칸마다 다르게 섞이기 때문입니다. 숫자로 못을 박으면
    ///      금리를 조금만 건드려도 깨지므로 테스트로 고정하지 않습니다.
    function test_everyRungKeepsASpread() public {
        uint256 bNet = WALLET - MockUSDC(d.usdc).balanceOf(B);
        uint256 cNet = WALLET - MockUSDC(d.usdc).balanceOf(C);
        uint256 dNet = WALLET - MockUSDC(d.usdc).balanceOf(D);

        test_cycleUnwindsBottomUp();

        uint256 bEnd = MockUSDC(d.usdc).balanceOf(B);
        uint256 cEnd = MockUSDC(d.usdc).balanceOf(C);
        uint256 dEnd = MockUSDC(d.usdc).balanceOf(D);

        emit log_named_uint("B net capital", bNet);
        emit log_named_uint("C net capital", cNet);
        emit log_named_uint("D net capital", dNet);
        assertGt(bEnd, WALLET, unicode"중간 B가 적자로 끝났습니다");
        assertGt(cEnd, WALLET, unicode"중간 C가 적자로 끝났습니다");
        assertGt(dEnd, WALLET, unicode"꼭대기 D가 적자로 끝났습니다");

        emit log_named_uint("B gain       ", bEnd - WALLET);
        emit log_named_uint("C gain       ", cEnd - WALLET);
        emit log_named_uint("D gain       ", dEnd - WALLET);
        emit log_named_uint("B return bps ", (bEnd - WALLET) * 10_000 / bNet);
        emit log_named_uint("C return bps ", (cEnd - WALLET) * 10_000 / cNet);
        emit log_named_uint("D return bps ", (dEnd - WALLET) * 10_000 / dNet);

        // 절대액은 자기 돈을 온전히 댄 꼭대기가 가장 큽니다.
        assertGt(dEnd - WALLET, bEnd - WALLET, unicode"D의 몫이 B보다 작습니다");
        assertGt(dEnd - WALLET, cEnd - WALLET, unicode"D의 몫이 C보다 작습니다");
    }

    // --- 만기는 칸마다 ---

    /// 칸마다 자기 시계입니다. 하나를 멈춰도 나머지는 돕니다.
    function test_eachRungFreezesItsOwnClock() public {
        skip(TERM);

        MaturityController ctrlB = MaturityController(d.maturityController);
        MaturityController ctrlC = MaturityController(rungC.controller);
        MaturityController ctrlD = MaturityController(rungD.controller);

        // 맨 아래만 닫습니다.
        vm.prank(B);
        ctrlB.closeMarket();

        assertTrue(ctrlB.marketClosed());
        assertFalse(ctrlC.marketClosed(), unicode"아래를 닫았는데 중간도 닫혔습니다");
        assertFalse(ctrlD.marketClosed(), unicode"아래를 닫았는데 꼭대기도 닫혔습니다");

        uint256 aFrozen = IEVault(vaultB).debtOf(A);
        uint256 bRunning = IEVault(vaultC).debtOf(B);
        uint256 cRunning = IEVault(vaultD).debtOf(C);

        skip(1 days);

        assertEq(IEVault(vaultB).debtOf(A), aFrozen, unicode"닫힌 칸의 부채가 자랐습니다");
        assertGt(IEVault(vaultC).debtOf(B), bRunning, unicode"열린 칸의 부채가 멈췄습니다");
        assertGt(IEVault(vaultD).debtOf(C), cRunning, unicode"열린 칸의 부채가 멈췄습니다");

        // 나머지 둘도 각자 닫습니다.
        vm.prank(C);
        ctrlC.closeMarket();
        vm.prank(D);
        ctrlD.closeMarket();

        uint256 bFrozen = IEVault(vaultC).debtOf(B);
        uint256 cFrozen = IEVault(vaultD).debtOf(C);
        skip(1 days);

        assertEq(IEVault(vaultC).debtOf(B), bFrozen);
        assertEq(IEVault(vaultD).debtOf(C), cFrozen);
    }

    /// 닫힌 칸에서도 상환과 환매는 됩니다. 백서 6.1절의 출구 무검사입니다.
    function test_closedRungsStillLetTheCycleFinish() public {
        skip(TERM);

        vm.prank(B);
        MaturityController(d.maturityController).closeMarket();
        vm.prank(C);
        MaturityController(rungC.controller).closeMarket();
        vm.prank(D);
        MaturityController(rungD.controller).closeMarket();

        // 신규 진입은 막혔습니다.
        vm.prank(D);
        vm.expectRevert();
        IEVault(vaultD).deposit(1e6, D);

        // 그런데 사이클은 그대로 끝납니다.
        test_cycleUnwindsBottomUp();
    }
}
