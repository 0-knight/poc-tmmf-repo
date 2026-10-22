// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";
import {RepoOpener} from "../../src/repo/RepoOpener.sol";
import {MaturityController} from "../../src/repo/MaturityController.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";
import {FixedRateIRM} from "../../src/irm/FixedRateIRM.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

interface ILiquidationCall {
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function repay(uint256 amount, address receiver) external returns (uint256);
}

/// @title MaturityControllerTest
/// @notice Wave 1. 백서 4.4절이 EVK에 있다.
///
/// @dev M6까지는 이 파일의 반대를 증명하는 테스트가 있었습니다 — 만기가 지나도 포지션이
///      건전하고, 거버너가 손으로 `setLTV(담보, 0.7, 0.7, 0)`을 불러야 비로소 청산이
///      열렸습니다. 그래서 성립하는 문장은 "만기가 지나면 청산된다"가 아니라 "거버너가
///      마음먹으면 청산된다"였습니다.
///
///      여기서 확인하는 것 넷.
///
///        1. 만기 전에는 아무도 발동할 수 없다
///        2. 만기 후에는 누구나 발동할 수 있다 — 권한 검사가 없다
///        3. 발동하면 부채가 멈추고, 신규 진입이 막히고, 청산선이 선형으로 내려간다
///        4. 관리자가 되돌릴 수 없다
contract MaturityControllerTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    MaturityController internal controller;
    RepoOpener internal opener;
    EthereumVaultConnector internal evc;

    address internal vault;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant PRINCIPAL = 80e6;
    uint256 internal constant TERM = 7 days;

    uint16 internal constant BORROW_LTV = 0.92e4;
    uint16 internal constant LIQUIDATION_LTV = 0.95e4;

    function setUp() public {
        deployScript = new DeployStack();
        d = deployScript.run();
        (vault,) = deployScript.deployCollateralVault(d, borrower);

        evc = EthereumVaultConnector(payable(d.evc));
        opener = RepoOpener(d.repoOpener);
        controller = MaturityController(d.maturityController);

        // Wave 2부터 부채 볼트 입금에 자격 검사가 붙습니다. 화이트리스트를 먼저 깔아야
        // 대여자가 자금을 넣을 수 있습니다 — 순서가 뒤바뀌면 setUp 이 되돌아갑니다.
        MockKycNFT(d.kycNft).safeMint(vault);
        MockKycNFT(d.kycNft).safeMint(borrower);
        MockKycNFT(d.kycNft).safeMint(lender);

        MockUSDC(d.usdc).mint(lender, 2_000e6);
        vm.startPrank(lender);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).deposit(1_000e6, lender);
        vm.stopPrank();

        MockWTGXX(d.wtgxx).mint(borrower, COLLATERAL);
    }

    function _maturity() internal view returns (uint256) {
        return MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault);
    }

    /// @dev 통지 창 안에서는 그 계약의 상대방만 부도를 선언할 수 있습니다. Wave 2.5.
    function _trigger() internal {
        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);
    }

    function _open(uint256 principal) internal {
        vm.startPrank(borrower);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        evc.setAccountOperator(borrower, address(opener), true);
        opener.open(vault, COLLATERAL, principal, _maturity(), lender);
        vm.stopPrank();
    }

    /// @dev 청산이 처음 열리는 경과 초를 이분 탐색으로 찾습니다.
    ///
    ///      발동 후에는 부채가 멈추고 청산선만 단조 감소하므로 "청산 가능"이 시간에 대해
    ///      단조입니다. 그래서 이분 탐색이 성립합니다.
    ///
    ///      초 단위로 긁지 않는 이유가 하나 더 있습니다. EVK는 청산선을 bp 단위 정수로
    ///      깎으므로(LTVConfig.getLTV) 실수 기준 교차점보다 최대 한 bp 계단만큼 일찍
    ///      열립니다. 하루 사다리에서 한 계단은 약 9초입니다. 이론식에 ±몇 초를 더해
    ///      단정하면 그 계단에 걸려 깨집니다.
    function _firstLiquidatableElapsed() internal returns (uint256) {
        uint256 startedAt = controller.rampStartedAt(vault);
        require(startedAt != 0, "ramp not started");

        uint256 lo = 0;
        uint256 hi = controller.rampDuration();

        vm.warp(startedAt + hi);
        (uint256 maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        require(maxRepay > 0, "not liquidatable even at ramp end");

        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            vm.warp(startedAt + mid);
            (maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
            if (maxRepay > 0) hi = mid;
            else lo = mid;
        }

        vm.warp(startedAt + hi);
        return hi;
    }

    /// @dev 청산 할인을 bp로. 담보 1e18 = 가치 1e6 이므로 share를 1e12로 나눕니다.
    function _discountBps() internal view returns (uint256) {
        (uint256 maxRepay, uint256 maxYield) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        if (maxRepay == 0) return type(uint256).max;
        uint256 yieldValue = maxYield / 1e12;
        if (yieldValue <= maxRepay) return 0;
        return (yieldValue - maxRepay) * 10_000 / yieldValue;
    }

    // --- 1. 만기 전에는 아무도 발동할 수 없다 ---

    function test_triggerRejectedBeforeMaturity() public {
        _open(PRINCIPAL);

        assertFalse(controller.canTrigger(vault, borrower, lender));
        vm.expectRevert(
            abi.encodeWithSelector(MaturityController.E_NotYetMatured.selector, _maturity(), block.timestamp)
        );
        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);
    }

    /// 만기 1초 전에도 안 됩니다.
    function test_triggerRejectedOneSecondBeforeMaturity() public {
        _open(PRINCIPAL);
        vm.warp(_maturity() - 1);

        assertFalse(controller.canTrigger(vault, borrower, lender));
        vm.expectRevert();
        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);
    }

    /// 만기 정각에는 됩니다. 시장은 정각에 닫힙니다.
    function test_triggerAllowedAtExactMaturity() public {
        _open(PRINCIPAL);
        vm.warp(_maturity());

        assertTrue(controller.canTrigger(vault, borrower, lender));
        _trigger();
        assertTrue(controller.marketClosed());
    }

    // --- 2. 만기 후에는 누구나 ---

    /// 통지 창이 지나면 권한 검사가 사라집니다. 아무 주소나 발동합니다.
    /// @dev 창 안의 거부는 NoticeWindow.t.sol 이 봅니다.
    function test_anyoneCanTriggerAfterNoticeWindow() public {
        _open(PRINCIPAL);
        skip(TERM + controller.noticeWindow());

        vm.prank(stranger);
        controller.triggerMaturity(vault, borrower);

        assertEq(controller.rampStartedAt(vault), block.timestamp);
        assertTrue(controller.marketClosed());
    }

    function test_triggerIsOnceOnly() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();

        assertFalse(controller.canTrigger(vault, borrower, lender));
        vm.expectRevert(abi.encodeWithSelector(MaturityController.E_RampAlreadyStarted.selector, vault));
        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);
    }

    /// 설정되지 않은 담보는 거부합니다. 사다리의 출발점이 없습니다.
    function test_triggerRejectsUnconfiguredCollateral() public {
        skip(TERM);
        vm.expectRevert(abi.encodeWithSelector(MaturityController.E_CollateralNotConfigured.selector, d.usdc));
        controller.triggerMaturity(d.usdc, borrower);
    }

    function test_closeMarketWithoutCollateral() public {
        skip(TERM);
        vm.prank(stranger);
        controller.closeMarket();

        assertTrue(controller.marketClosed());
        vm.expectRevert(MaturityController.E_MarketAlreadyClosed.selector);
        controller.closeMarket();
    }

    // --- 3. 발동하면 무엇이 바뀌는가 ---

    /// 백서 4.4절. 연체 이자가 없습니다.
    function test_debtStopsAtMaturity() public {
        _open(PRINCIPAL);
        skip(TERM);

        uint256 debtAtMaturity = IEVault(d.debtVault).debtOf(borrower);
        assertGt(debtAtMaturity, PRINCIPAL, unicode"만기까지의 이자가 붙지 않았습니다");

        _trigger();
        assertEq(IEVault(d.debtVault).interestRateModel(), d.zeroRateIrm);
        assertEq(FixedRateIRM(d.zeroRateIrm).ratePerSecond(), 0);

        skip(30 days);
        assertEq(
            IEVault(d.debtVault).debtOf(borrower), debtAtMaturity, unicode"만기 후에 부채가 자랐습니다"
        );
    }

    /// 발동 전까지는 그대로 자랍니다. 멈추는 것은 자동이 아니라 호출입니다.
    /// @dev 대여자가 먼저 부를 동기를 갖지만, 아무도 부르지 않으면 EVK 기본 동작이 남습니다.
    function test_debtKeepsGrowingUntilTriggered() public {
        _open(PRINCIPAL);
        skip(TERM);

        uint256 atMaturity = IEVault(d.debtVault).debtOf(borrower);
        skip(1 days);
        assertGt(IEVault(d.debtVault).debtOf(borrower), atMaturity);
    }

    /// 만기까지의 이자는 소급해서 지워지지 않습니다.
    /// @dev setInterestRateModel 이 먼저 updateVault() 로 확정합니다.
    function test_triggerDoesNotErasePastInterest() public {
        _open(PRINCIPAL);
        skip(TERM);

        uint256 before = IEVault(d.debtVault).debtOf(borrower);
        _trigger();

        assertEq(IEVault(d.debtVault).debtOf(borrower), before);
        assertGt(IEVault(d.debtVault).debtOf(borrower), PRINCIPAL);
    }

    /// 신규 진입이 막힙니다. 입금·발행·차입만.
    function test_newEntryBlockedAfterTrigger() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();

        (address hookTarget, uint32 hookedOps) = IEVault(d.debtVault).hookConfig();
        assertEq(hookTarget, address(0), unicode"훅 대상이 0 주소가 아니면 연산이 비활성화되지 않습니다");
        assertEq(hookedOps, controller.CLOSED_OPS());
        assertEq(controller.CLOSED_OPS(), (1 << 0) | (1 << 1) | (1 << 5) | (1 << 6));

        // 자격 있는 대여자도 더는 넣을 수 없습니다. 자격 검사가 아니라 비활성화입니다.
        MockUSDC(d.usdc).mint(lender, 100e6);
        vm.startPrank(lender);
        vm.expectRevert();
        IEVault(d.debtVault).deposit(100e6, lender);
        vm.stopPrank();
    }

    /// 출구는 열려 있어야 합니다. 백서 6.1절. 상환도 인출도 환매도 막히지 않습니다.
    function test_exitStaysOpenAfterTrigger() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        MockUSDC(d.usdc).mint(borrower, debt - PRINCIPAL);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        IEVault(d.debtVault).disableController();
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL);
        assertEq(IEVault(d.debtVault).debtOf(borrower), 0);

        // 대여자도 나갑니다.
        uint256 shares = IEVault(d.debtVault).balanceOf(lender);
        vm.prank(lender);
        IEVault(d.debtVault).redeem(shares, lender, lender);
        assertGt(MockUSDC(d.usdc).balanceOf(lender), 1_000e6);
    }

    // --- 사다리 ---

    /// 사다리는 개시 한도에서 출발합니다. 상수가 아니라 볼트에서 읽은 값입니다.
    function test_rampStartsAtBorrowLtv() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();

        assertEq(IEVault(d.debtVault).LTVBorrow(vault), 0, unicode"개시 한도가 0으로 닫히지 않았습니다");
        assertEq(IEVault(d.debtVault).LTVLiquidation(vault), BORROW_LTV, unicode"사다리 출발점이 개시 한도가 아닙니다");

        (,, uint16 initialLiquidationLTV, uint48 targetTimestamp, uint32 ramp) =
            IEVault(d.debtVault).LTVFull(vault);
        assertEq(initialLiquidationLTV, BORROW_LTV);
        assertEq(ramp, controller.rampDuration());
        assertEq(targetTimestamp, block.timestamp + controller.rampDuration());
    }

    /// 선형으로 내려갑니다. 절반 지점에서 절반입니다.
    function test_rampIsLinear() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();

        uint32 ramp = controller.rampDuration();

        skip(ramp / 4);
        assertApproxEqAbs(IEVault(d.debtVault).LTVLiquidation(vault), uint16(BORROW_LTV * 3 / 4), 2);

        skip(ramp / 4);
        assertApproxEqAbs(IEVault(d.debtVault).LTVLiquidation(vault), uint16(BORROW_LTV / 2), 2);

        skip(ramp / 2);
        assertEq(IEVault(d.debtVault).LTVLiquidation(vault), 0, unicode"사다리가 0에 닿지 않았습니다");
    }

    /// LTV가 0이어도 담보 자격은 남습니다. 남지 않으면 청산이 불가해집니다.
    /// @dev LTVConfig.isRecognizedCollateral 은 targetTimestamp != 0 만 봅니다.
    function test_collateralStillRecognizedAtZeroLtv() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();
        skip(controller.rampDuration() + 1);

        assertEq(IEVault(d.debtVault).LTVLiquidation(vault), 0);

        (,,, uint48 targetTimestamp,) = IEVault(d.debtVault).LTVFull(vault);
        assertGt(targetTimestamp, 0, unicode"담보 자격이 사라졌습니다");

        (uint256 maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertGt(maxRepay, 0, unicode"LTV 0에서 청산이 불가합니다");
    }

    // --- 백서 4.4절의 핵심: 종이 울릴 때 할인 0 ---

    /// 한도까지 끌어 쓴 포지션은 만기 직후 청산 대상이고 할인이 0에서 시작합니다.
    ///
    /// @dev 백서 4.4절이 말하는 경우가 이것입니다. 개시 한도 92% 바로 아래까지 빌렸으므로
    ///      사다리가 출발하는 순간 조정담보와 부채가 거의 같고, 조금만 지나면 조정담보가
    ///      부채 아래로 내려갑니다. 할인은 `1 - 조정담보/부채` 이므로 0에서 출발합니다.
    ///
    ///      "조금"이 1초가 아닌 이유는 만기까지 붙은 이자입니다. 91e6을 빌렸지만 7일 뒤
    ///      부채는 약 91.9e6 이고 사다리 출발점은 92e6 이라, 그 0.1e6 의 틈이 먼저
    ///      메워져야 합니다. 그 틈이 얼마인지를 숫자로 남깁니다.
    function test_fullyDrawnIsLiquidatableRightAfterMaturity() public {
        _open(91e6);
        skip(TERM);
        _trigger();

        uint256 opensAt = _firstLiquidatableElapsed();
        uint32 ramp = controller.rampDuration();

        emit log_named_uint("debt at maturity      ", IEVault(d.debtVault).debtOf(borrower));
        emit log_named_uint("ramp duration (s)     ", ramp);
        emit log_named_uint("liquidation opens (s) ", opensAt);
        emit log_named_uint("  as bp of ramp       ", opensAt * 10_000 / ramp);
        emit log_named_uint("discount there (bps)  ", _discountBps());

        // 사다리의 1% 안에서 열려야 합니다. 한도를 다 쓴 포지션에 유예는 없습니다.
        assertLt(opensAt, ramp / 100, unicode"한도까지 쓴 포지션에 유예가 생겼습니다");

        // 그 순간의 할인은 0에 붙어 있어야 합니다. 백서 4.4절.
        assertLt(_discountBps(), 20, unicode"종이 울릴 때 할인이 0에서 시작하지 않습니다");
    }

    /// 여유를 남긴 차입자는 그 여유가 먼저 소진됩니다. 담보가 많을수록 유예가 깁니다.
    ///
    /// @dev 사다리의 두 시계 중 첫 번째를 숫자로 남깁니다. 프로덕션에서 rampDuration 을
    ///      정할 근거입니다. 이론식과 비교하되 bp 계단만큼의 오차를 허용합니다.
    function test_underdrawnGetsGracePeriod() public {
        _open(PRINCIPAL); // 담보 100 대비 80. 한도 92를 다 쓰지 않았습니다.
        skip(TERM);
        _trigger();

        // 발동 직후에는 청산 불가. 조정담보 92 > 부채 약 80.8.
        (uint256 maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertEq(maxRepay, 0, unicode"여유가 있는데 바로 청산 대상이 됐습니다");

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        uint32 ramp = controller.rampDuration();
        uint256 opensAt = _firstLiquidatableElapsed();

        // 이론값: 경과 = (1 - 부채/담보 / 개시LTV) x rampDuration
        uint256 theory = (1e18 - (debt * 1e18 / 100e6) * 1e4 / BORROW_LTV) * ramp / 1e18;

        emit log_named_uint("debt at maturity      ", debt);
        emit log_named_uint("liquidation opens (s) ", opensAt);
        emit log_named_uint("  theory (s)          ", theory);
        emit log_named_uint("  as bp of ramp       ", opensAt * 10_000 / ramp);
        emit log_named_uint("discount there (bps)  ", _discountBps());

        // EVK는 청산선을 bp 정수로 깎으므로(LTVConfig.getLTV) 실수 기준 교차점보다
        // 최대 한 계단 일찍 열립니다. 한 계단 = ramp / 개시LTV(bp) 초.
        uint256 oneStep = uint256(ramp) / BORROW_LTV + 1;
        assertApproxEqAbs(opensAt, theory, oneStep + 2, unicode"교차 시점이 이론식과 어긋납니다");

        // 열리는 순간의 할인은 역시 0에 붙어 있습니다. 출발점이 어디든 같습니다.
        assertLt(_discountBps(), 20, unicode"열리는 순간 할인이 0이 아닙니다");
    }

    /// 할인이 선형으로 오르고 2% 상한에서 멈춥니다. 상한에 닿는 시점을 기록합니다.
    ///
    /// @dev 사다리의 범위 대부분은 할인에 영향이 없습니다. 할인은
    ///      `maxLiquidationDiscount`(2%)에서 잘리고, 거기 닿는 데 사다리의 2% 남짓만
    ///      걸립니다. 그래도 0까지 내려야 하는 이유는 여유를 남긴 차입자를 결국 잡기
    ///      위해서입니다. MaturityController 주석 참조.
    function test_discountRisesThenCaps() public {
        _open(91e6);
        skip(TERM);
        _trigger();

        uint256 startedAt = controller.rampStartedAt(vault);
        uint32 ramp = controller.rampDuration();
        uint256 opensAt = _firstLiquidatableElapsed();

        uint256 step = uint256(ramp) / 500; // 사다리의 0.2% 씩
        uint256 previous;
        uint256 cappedAt;

        for (uint256 i; i <= 30; ++i) {
            vm.warp(startedAt + opensAt + i * step);
            uint256 bps = _discountBps();
            if (bps == type(uint256).max) continue;

            assertGe(bps + 1, previous, unicode"할인이 줄었습니다");
            assertLe(bps, 205, unicode"할인이 2% 상한을 넘었습니다");

            if (bps >= 195 && cappedAt == 0) cappedAt = i * step;
            previous = bps;
        }

        emit log_named_uint("liquidation opens (s)  ", opensAt);
        emit log_named_uint("discount caps after (s)", cappedAt);
        emit log_named_uint("  as bp of ramp        ", cappedAt * 10_000 / ramp);

        assertGt(cappedAt, 0, unicode"할인이 상한에 닿지 않았습니다");
        assertGe(previous, 195, unicode"사다리 끝에서 할인이 상한에 있지 않습니다");
    }

    // --- 4. 되돌릴 수 없다 ---

    /// 관리자도 사다리를 시작한 담보의 LTV를 다시 올릴 수 없습니다.
    ///
    /// @dev 먼저 걸리는 가드는 `E_MarketClosed` 입니다. triggerMaturity 가 사다리를
    ///      시작하기 전에 시장을 닫으므로, 사다리가 시작된 담보는 언제나 "시장이 닫힌"
    ///      시장에 속합니다. 그래서 configureCollateral 의 `E_RampAlreadyStarted` 는
    ///      현재 도달 불가능한 가드입니다 — 남겨두되 여기 적어 둡니다.
    function test_adminCannotUndoRamp() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();

        vm.prank(controller.admin());
        vm.expectRevert(MaturityController.E_MarketClosed.selector);
        controller.configureCollateral(vault, BORROW_LTV, LIQUIDATION_LTV);

        // 어느 쪽이든 LTV는 그대로여야 합니다. 그것이 이 테스트의 요지입니다.
        assertEq(IEVault(d.debtVault).LTVBorrow(vault), 0);
        assertLe(IEVault(d.debtVault).LTVLiquidation(vault), BORROW_LTV);
    }

    /// 한 번 닫힌 시장은 다시 열리지 않습니다. 이 PoC의 시장은 단일 기간입니다.
    ///
    /// @dev 레지스트리의 `setMarketMaturity` 는 다음 기간으로 굴릴 수 있지만, 컨트롤러에는
    ///      `marketClosedAt` 을 되돌리는 경로가 없습니다. 거버넌스를 넘기는 함수도 없으니
    ///      새 컨트롤러로 교체할 수도 없습니다. **다음 기간을 열려면 시장을 새로
    ///      배포해야 합니다.**
    ///
    ///      되돌릴 수 없게 만든 선택의 대가입니다. 7일 repo 한 번을 보이는 데모에는
    ///      문제가 없지만, 같은 볼트로 기간을 굴리려면 타임락을 거버너로 두고 컨트롤러를
    ///      교체 가능하게 바꿔야 합니다.
    function test_closedMarketCannotReopenEvenAfterRoll() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();

        // 레지스트리는 굴러갑니다.
        uint256 next = block.timestamp + TERM;
        MaturityRegistry(d.maturityRegistry).setMarketMaturity(d.debtVault, next);
        assertEq(MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault), next);

        // 그래도 시장은 닫힌 채입니다.
        assertTrue(controller.marketClosed());

        // 차입이 막혀 있어 새 계약을 열 수 없습니다.
        address second = makeAddr("second");
        MockKycNFT(d.kycNft).safeMint(second);
        MockWTGXX(d.wtgxx).mint(second, COLLATERAL);

        vm.startPrank(second);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        evc.setAccountOperator(second, address(opener), true);
        vm.expectRevert();
        opener.open(vault, COLLATERAL, PRINCIPAL, next, lender);
        vm.stopPrank();
    }

    /// 시장이 닫힌 뒤에는 새 담보도 들일 수 없습니다.
    function test_noOnboardingAfterMarketClosed() public {
        skip(TERM);
        controller.closeMarket();

        vm.prank(controller.admin());
        vm.expectRevert(MaturityController.E_MarketClosed.selector);
        controller.configureCollateral(d.usdc, BORROW_LTV, LIQUIDATION_LTV);
    }

    function test_onboardingRejectsNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(MaturityController.E_NotAdmin.selector);
        controller.configureCollateral(d.usdc, BORROW_LTV, LIQUIDATION_LTV);
    }

    /// 배포자는 더 이상 볼트 거버너가 아닙니다. setLTV 를 직접 부를 수 없습니다.
    function test_deployerLostGovernance() public {
        assertEq(IEVault(d.debtVault).governorAdmin(), d.maturityController);

        vm.expectRevert();
        IEVault(d.debtVault).setLTV(vault, 0.7e4, 0.7e4, 0);
    }

    /// 거버넌스를 되돌려받는 함수가 없습니다. 선택이며 대가가 있습니다.
    function test_controllerHasNoGovernanceEscapeHatch() public view {
        // setGovernorAdmin 을 노출하지 않으므로 호출 자체가 불가능합니다.
        (bool ok,) = address(controller).staticcall(
            abi.encodeWithSignature("transferGovernance(address)", address(this))
        );
        assertFalse(ok, unicode"거버넌스 반환 경로가 생겼습니다");
    }

    // --- 전체 경로: 만기 → 발동 → 청산 ---

    /// S6을 Wave 1 방식으로. 사람이 LTV를 손으로 내리지 않습니다.
    function test_maturityToLiquidationEndToEnd() public {
        _open(PRINCIPAL);

        // 만기 정각에는 시장만 만기이고 계정은 아직 디폴트가 아닙니다. Wave 0b에서
        // 의도한 한 칸 차이입니다 — 정각의 상환은 연체가 아닙니다.
        skip(TERM);
        assertTrue(MaturityRegistry(d.maturityRegistry).isMarketMatured(d.debtVault));
        assertFalse(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));

        // 1. 한 초 지나면 계정도 디폴트입니다.
        skip(1);
        assertTrue(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));

        // 2. 상대방이 부도를 선언합니다. 통지 창 안이므로 대여자만 할 수 있습니다.
        //    창이 지난 뒤라면 제3자도 할 수 있고, 그쪽은 NoticeWindow.t.sol 이 봅니다.
        _trigger();

        // 3. 사다리가 차입자의 비율까지 내려올 때까지 기다립니다.
        uint256 maxRepay;
        for (uint256 i; i < 50; ++i) {
            skip(controller.rampDuration() / 50);
            (maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
            if (maxRepay > 0) break;
        }
        assertGt(maxRepay, 0, unicode"사다리가 끝까지 내려와도 청산이 열리지 않았습니다");

        // 4. 대여자가 청산합니다.
        uint256 debtBefore = IEVault(d.debtVault).debtOf(borrower);
        vm.startPrank(lender);
        evc.enableController(lender, d.debtVault);
        evc.enableCollateral(lender, vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: d.debtVault,
            onBehalfOfAccount: lender,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.liquidate, (borrower, vault, maxRepay, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: d.debtVault,
            onBehalfOfAccount: lender,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.repay, (type(uint256).max, lender))
        });
        evc.batch(items);
        vm.stopPrank();

        assertLt(IEVault(d.debtVault).debtOf(borrower), debtBefore, unicode"부채가 줄지 않았습니다");

        // 5. 비로소 실제 WTGXX.
        uint256 shares = IEVault(vault).balanceOf(lender);
        assertGt(shares, 0, unicode"담보 share를 받지 못했습니다");
        vm.prank(lender);
        IEVault(vault).withdraw(shares, lender, lender);
        assertGt(MockWTGXX(d.wtgxx).balanceOf(lender), 0, unicode"WTGXX를 받지 못했습니다");
    }

    /// 만기를 넘기고 발동까지 됐지만 차입자가 갚는 경우. 연체 이자 없이 끝납니다.
    function test_fullCycleWithLateRepaymentAfterTrigger() public {
        _open(PRINCIPAL);
        skip(TERM);

        uint256 debtAtMaturity = IEVault(d.debtVault).debtOf(borrower);
        _trigger();

        // 사흘 늦게 갚습니다. 백서 4.4절이면 추가 이자가 없어야 합니다.
        skip(3 days);
        uint256 debtNow = IEVault(d.debtVault).debtOf(borrower);
        assertEq(debtNow, debtAtMaturity, unicode"사흘치 연체 이자가 붙었습니다");

        MockUSDC(d.usdc).mint(borrower, debtNow - PRINCIPAL);
        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        IEVault(d.debtVault).disableController();
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL);
        assertEq(IEVault(d.debtVault).debtOf(borrower), 0);
    }

    /// 부분 상환도 통해야 합니다. 개시 LTV가 0이어도 막히지 않습니다.
    /// @dev EVK의 repay 는 CHECKACCOUNT_NONE 이라 계정 건전성 검사를 걸지 않습니다.
    ///      걸렸다면 개시 LTV 0 때문에 어떤 부분 상환도 실패했을 것입니다.
    function test_partialRepayWorksWithZeroBorrowLtv() public {
        _open(PRINCIPAL);
        skip(TERM);
        _trigger();

        assertEq(IEVault(d.debtVault).LTVBorrow(vault), 0);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(10e6, borrower);
        vm.stopPrank();

        assertApproxEqAbs(IEVault(d.debtVault).debtOf(borrower), PRINCIPAL + 770_000 - 10e6, 1e6);
    }
}
