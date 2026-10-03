// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";
import {RepoOpener} from "../../src/repo/RepoOpener.sol";
import {MaturityController} from "../../src/repo/MaturityController.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

/// @title NoticeWindowTest
/// @notice Wave 2.5. 만기가 지나도 자동으로 청산되지 않는다.
///
/// @dev GMRA 2011 ¶10을 EVK로 옮긴 결과를 봅니다. ¶10(a)(i)은 만기 미지급을 Event of
///      Default로 적지만 비부도 당사자가 Default Notice를 보내야 성립하고, ¶10(b)는 그
///      통지까지 최대 20일을 줍니다. 대여자가 통지하지 않기로 선택하는 것 —
///      forbearance — 이 차입자의 만회 기회입니다.
///
///      **운영자는 어느 쪽에도 없습니다.** 첫 관문의 열쇠는 상대방이 쥐고, 둘째 관문의
///      열쇠는 시계가 쥡니다. 거버넌스가 LTV를 되올려 청산을 취소하는 경로는 없습니다.
///
///      숫자는 설계 문서의 예제와 같습니다 — 담보 100, 부채 80, 만기 D+7, 통지 창
///      24시간, 사다리 하루. 만기 시점 부채는 이자가 붙어 약 80.770입니다.
contract NoticeWindowTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    RepoOpener internal opener;
    MaturityController internal controller;
    MaturityRegistry internal maturities;
    EthereumVaultConnector internal evc;

    address internal vault;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal bot = makeAddr("bot");
    address internal agent = makeAddr("agent");

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant PRINCIPAL = 80e6;
    uint256 internal constant TERM = 7 days;

    function setUp() public {
        deployScript = new DeployStack();
        d = deployScript.run();
        (vault,) = deployScript.deployCollateralVault(d, borrower);

        evc = EthereumVaultConnector(payable(d.evc));
        opener = RepoOpener(d.repoOpener);
        controller = MaturityController(d.maturityController);
        maturities = MaturityRegistry(d.maturityRegistry);

        MockKycNFT(d.kycNft).safeMint(vault);
        MockKycNFT(d.kycNft).safeMint(borrower);
        MockKycNFT(d.kycNft).safeMint(lender);

        MockUSDC(d.usdc).mint(lender, 2_000e6);
        vm.startPrank(lender);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).deposit(1_000e6, lender);
        vm.stopPrank();

        MockWTGXX(d.wtgxx).mint(borrower, COLLATERAL);

        vm.startPrank(borrower);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        evc.setAccountOperator(borrower, address(opener), true);
        opener.open(vault, COLLATERAL, PRINCIPAL, maturities.marketMaturity(d.debtVault), lender);
        vm.stopPrank();
    }

    function _maturity() internal view returns (uint256) {
        return maturities.marketMaturity(d.debtVault);
    }

    /// @dev 차입자가 전액 상환하고 담보를 되찾습니다.
    function _repayAndExit() internal {
        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        MockUSDC(d.usdc).mint(borrower, debt);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        IEVault(d.debtVault).disableController();
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
        vm.stopPrank();
    }

    // --- 상대방이 기록되는가 ---

    /// 개시 때 상대방이 온체인에 남습니다. 백서 4.5절의 "직접 계약한 대여자"입니다.
    function test_counterpartyRecordedAtOpen() public view {
        assertEq(maturities.counterpartyOf(borrower), lender);
    }

    /// 계약이 끝나면 함께 지워집니다.
    function test_counterpartyClearedWithMaturity() public {
        skip(TERM);
        _repayAndExit();

        vm.prank(borrower);
        maturities.clearMaturity(borrower);

        assertEq(maturities.maturityOf(borrower), 0);
        assertEq(maturities.counterpartyOf(borrower), address(0));
    }

    // --- 예제 1. 차입자가 늦게 갚는다. cure 성공 ---

    /// 아무도 통지하지 않으면 청산은 일어나지 않습니다. 운영자는 아무것도 하지 않았습니다.
    function test_example1_lateRepaymentWithoutNotice() public {
        skip(TERM);

        // 누구나 시장을 닫을 수 있습니다. 차입자 본인이 부르는 것이 정상입니다 —
        // 갚아야 할 금액을 고정하는 조치이기 때문입니다.
        vm.prank(borrower);
        controller.closeMarket();

        uint256 fixedDebt = IEVault(d.debtVault).debtOf(borrower);
        assertGt(fixedDebt, PRINCIPAL, unicode"만기까지의 이자가 붙지 않았습니다");

        // 아홉 시간 뒤에 갚습니다. 연체 이자는 없습니다.
        skip(9 hours);
        assertEq(IEVault(d.debtVault).debtOf(borrower), fixedDebt, unicode"연체 이자가 붙었습니다");

        _repayAndExit();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL, unicode"담보를 못 되찾았습니다");
        assertEq(IEVault(d.debtVault).debtOf(borrower), 0);
        assertEq(controller.rampStartedAt(vault), 0, unicode"사다리가 시작됐습니다");
    }

    /// 시장을 닫는 것은 부도 선언이 아닙니다. 담보는 그대로 차입자에게 있습니다.
    function test_closeMarketIsNotDefault() public {
        skip(TERM);
        vm.prank(bot);
        controller.closeMarket();

        assertTrue(controller.marketClosed());
        assertEq(controller.rampStartedAt(vault), 0);
        assertEq(IEVault(d.debtVault).LTVLiquidation(vault), 0.95e4, unicode"청산선이 내려갔습니다");

        (uint256 maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertEq(maxRepay, 0, unicode"닫기만 했는데 청산 가능해졌습니다");
    }

    // --- 예제 2. 대여자가 통지한다 ---

    /// 통지는 cure를 끝내지 않습니다. 사다리가 내려오는 동안 차입자는 여전히 갚을 수 있습니다.
    function test_example2_borrowerStillCuresAfterNotice() public {
        skip(TERM);

        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);
        assertGt(controller.rampStartedAt(vault), 0);

        // 통지 직후에는 아직 청산 불가. 담보 여유가 남아 있습니다.
        (uint256 maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertEq(maxRepay, 0, unicode"통지하자마자 청산 대상이 됐습니다");

        // 한 시간 뒤에도 아직입니다. 그 사이 차입자가 갚으면 끝납니다.
        skip(1 hours);
        (maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertEq(maxRepay, 0);

        _repayAndExit();
        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL, unicode"통지 후 상환이 막혔습니다");
    }

    /// 통지 뒤 사다리가 내려오면 비로소 청산이 열립니다. 숫자를 기록합니다.
    function test_example2_liquidationOpensAfterRamp() public {
        skip(TERM);

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);

        uint256 startedAt = controller.rampStartedAt(vault);
        uint32 ramp = controller.rampDuration();

        uint256 lo = 0;
        uint256 hi = ramp;
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

        emit log_named_uint("debt at maturity     ", debt);
        emit log_named_uint("liquidation opens (s)", hi);
        emit log_named_uint("  in minutes         ", hi / 60);

        // 설계 문서의 예제는 2시간 56분. 범위로 단정합니다 — 정확한 초는 이자 누적과
        // EVK의 bp 반올림에 달려 있고, 그 둘은 이 테스트가 보려는 것이 아닙니다.
        assertGt(hi, 2 hours + 30 minutes, unicode"문서 예제보다 너무 일찍 열렸습니다");
        assertLt(hi, 3 hours + 20 minutes, unicode"문서 예제보다 너무 늦게 열렸습니다");
    }

    // --- 예제 3. 제3자가 서두른다 ---

    /// 창 안에서는 상대방이 아닌 주소를 거부합니다.
    function test_example3_thirdPartyRejectedInsideWindow() public {
        skip(TERM + 30 minutes);

        assertFalse(controller.canTrigger(vault, borrower, bot));
        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(MaturityController.E_NoticeWindowRestricted.selector, borrower, lender, bot)
        );
        controller.triggerMaturity(vault, borrower);
    }

    /// 창이 지나면 같은 주소가 통과합니다. 대여자가 사라져도 포지션이 풀립니다.
    function test_example3_thirdPartyAllowedAfterWindow() public {
        skip(TERM + controller.noticeWindow());

        assertTrue(controller.canTrigger(vault, borrower, bot));
        vm.prank(bot);
        controller.triggerMaturity(vault, borrower);

        assertGt(controller.rampStartedAt(vault), 0);
    }

    /// 창의 마지막 1초까지는 막힙니다.
    function test_windowClosesExactlyOnTime() public {
        uint256 endsAt = controller.noticeWindowEndsAt();
        assertEq(endsAt, _maturity() + controller.noticeWindow());

        vm.warp(endsAt - 1);
        assertFalse(controller.canTrigger(vault, borrower, bot));

        vm.warp(endsAt);
        assertTrue(controller.canTrigger(vault, borrower, bot));
    }

    /// 차입자 본인도 창 안에서는 부도를 선언할 수 없습니다. 자기 계약의 상대방이 아닙니다.
    function test_borrowerCannotDeclareOwnDefault() public {
        skip(TERM);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(MaturityController.E_NoticeWindowRestricted.selector, borrower, lender, borrower)
        );
        controller.triggerMaturity(vault, borrower);
    }

    // --- 대리인 ---

    /// 대여자가 EVC operator로 위임하면 대리인이 통지합니다. 새 레지스트리가 필요 없습니다.
    function test_agentCanServeNoticeWhenAuthorized() public {
        skip(TERM);

        assertFalse(controller.canTrigger(vault, borrower, agent));

        vm.prank(lender);
        evc.setAccountOperator(lender, agent, true);

        assertTrue(controller.canTrigger(vault, borrower, agent));
        vm.prank(agent);
        controller.triggerMaturity(vault, borrower);
        assertGt(controller.rampStartedAt(vault), 0);
    }

    /// 위임을 거두면 다시 막힙니다. 권한은 대여자가 쥡니다.
    function test_agentBlockedAfterRevocation() public {
        skip(TERM);

        vm.startPrank(lender);
        evc.setAccountOperator(lender, agent, true);
        evc.setAccountOperator(lender, agent, false);
        vm.stopPrank();

        assertFalse(controller.canTrigger(vault, borrower, agent));
        vm.prank(agent);
        vm.expectRevert();
        controller.triggerMaturity(vault, borrower);
    }

    /// 대여자의 서브계정도 통과합니다.
    function test_lenderSubAccountCanServeNotice() public {
        skip(TERM);
        address sub = address(uint160(uint160(lender) ^ 1));

        assertTrue(controller.canTrigger(vault, borrower, sub));
        vm.prank(sub);
        controller.triggerMaturity(vault, borrower);
        assertGt(controller.rampStartedAt(vault), 0);
    }

    // --- 짝이 맞는지 ---

    /// 남의 담보에 사다리를 걸 수 없습니다. 차입자가 그 볼트의 지분을 들고 있어야 합니다.
    function test_rejectsBorrowerWhoDoesNotHoldCollateral() public {
        skip(TERM + controller.noticeWindow());

        vm.prank(bot);
        vm.expectRevert(
            abi.encodeWithSelector(MaturityController.E_NotCollateralHolder.selector, bot, vault)
        );
        controller.triggerMaturity(vault, bot);
    }

    // --- 상대방 기록이 없는 계약 ---

    /// 상대방이 없으면 창을 적용하지 않습니다. 누구를 기다려야 할지 알 수 없기 때문입니다.
    ///
    /// @dev 이 변경 전에 열린 계약, 또는 레지스트리를 직접 쓴 계약이 여기 해당합니다.
    ///      영원히 안 풀리는 것보다 창 없이 푸는 편이 낫습니다.
    function test_noCounterpartyMeansNoWindow() public {
        // 상대방 기록만 지웁니다. 만기 기록은 남겨 두기 위해 계약을 지우고 다시 씁니다.
        skip(TERM);
        vm.startPrank(borrower);
        maturities.clearMaturity(borrower);
        maturities.setMaturity(borrower, block.timestamp + 1);
        vm.stopPrank();

        assertEq(maturities.counterpartyOf(borrower), address(0));
        assertTrue(controller.canTrigger(vault, borrower, bot), unicode"기록이 없는데 창이 걸렸습니다");

        vm.prank(bot);
        controller.triggerMaturity(vault, borrower);
        assertGt(controller.rampStartedAt(vault), 0);
    }

    // --- 창은 부도 선언만 막는다 ---

    /// 창 안에서도 시장은 누구나 닫습니다. 부채 정지는 차입자에게 유리한 조치입니다.
    function test_closeMarketNotRestrictedByWindow() public {
        skip(TERM);

        vm.prank(bot);
        controller.closeMarket();

        assertTrue(controller.marketClosed());
        assertEq(controller.rampStartedAt(vault), 0, unicode"닫기가 사다리까지 시작했습니다");
    }

    /// 시장을 먼저 닫고 나중에 통지해도 같은 결과입니다.
    function test_closeThenNoticeMatchesSingleCall() public {
        skip(TERM);

        vm.prank(borrower);
        controller.closeMarket();
        uint256 closedAt = controller.marketClosedAt();

        skip(2 hours);
        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);

        assertEq(controller.marketClosedAt(), closedAt, unicode"닫힌 시각이 덮어써졌습니다");
        assertEq(controller.rampStartedAt(vault), block.timestamp);
        assertEq(IEVault(d.debtVault).LTVLiquidation(vault), 0.92e4);
    }

    // --- 전체 사이클 ---

    /// 통지가 와도 차입자가 사다리 안에 갚으면 정상 종료입니다. 대여자도 회수합니다.
    function test_fullCycleCuredAfterNotice() public {
        skip(TERM);

        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);

        skip(1 hours);
        _repayAndExit();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL);
        assertEq(IEVault(d.debtVault).debtOf(borrower), 0);

        uint256 shares = IEVault(d.debtVault).balanceOf(lender);
        vm.prank(lender);
        IEVault(d.debtVault).redeem(shares, lender, lender);
        assertGt(MockUSDC(d.usdc).balanceOf(lender), 1_000e6, unicode"대여자가 이자를 못 받았습니다");
    }
}
