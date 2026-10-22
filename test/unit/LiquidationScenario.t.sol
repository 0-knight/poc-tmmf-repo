// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";
import {RepoOpener} from "../../src/repo/RepoOpener.sol";
import {LiquidationPrecheck} from "../../src/repo/LiquidationPrecheck.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";
import {MaturityController} from "../../src/repo/MaturityController.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

/// @dev encodeCall 용 최소 선언. IEVault는 합성 인터페이스라 상속 멤버로 포인터를
///      만들 수 없습니다.
interface ILiquidationCall {
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function repay(uint256 amount, address receiver) external returns (uint256);
}

/// @title LiquidationScenarioTest
/// @notice M6. 만기를 넘기고 상환하지 않은 계약을 청산합니다.
///
/// @dev 두 가지를 보여주는 것이 목적입니다.
///
///      **백서 4.4절은 이제 MaturityController 가 담당합니다.** M6에서는 거버너가 손으로
///      setLTV 를 낮춰 청산을 열었고, 그래서 성립하는 문장이 "만기가 지나면 청산된다"가
///      아니라 "거버너가 마음먹으면 청산된다"였습니다. Wave 1에서 그 자리를 컨트랙트가
///      대신합니다 — 만기 후에만, 누구나, 되돌릴 수 없게. 사다리와 할인의 성질은
///      MaturityController.t.sol 이 봅니다. 이 파일은 청산 **기계**에 집중합니다.
///
///      **청산 성공이 담보 확보가 아닙니다.** EVK 청산은 볼트 share를 이전할 뿐 WTGXX를
///      만지지 않아 화이트리스트도 동결도 타지 않습니다. 실제 토큰은 그다음 인출에서
///      나오고, 거기서 처음 규제 자산 제약에 부딪힙니다.
contract LiquidationScenarioTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    RepoOpener internal opener;
    MaturityController internal controller;
    LiquidationPrecheck internal precheck;
    EthereumVaultConnector internal evc;

    address internal vault;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant PRINCIPAL = 80e6;
    uint256 internal constant TERM = 7 days;

    uint16 internal constant LTV_BORROW = 0.92e4;
    uint16 internal constant LTV_LIQUIDATION = 0.95e4;

    function setUp() public {
        deployScript = new DeployStack();
        d = deployScript.run();
        (vault,) = deployScript.deployCollateralVault(d, borrower);

        evc = EthereumVaultConnector(payable(d.evc));
        opener = RepoOpener(d.repoOpener);
        controller = MaturityController(d.maturityController);
        precheck = new LiquidationPrecheck(d.wtgxx);

        // Wave 2부터 부채 볼트 입금에 자격 검사가 붙습니다. 화이트리스트를 먼저 깔아야
        // 대여자가 자금을 넣을 수 있습니다 — 순서가 뒤바뀌면 setUp 이 되돌아갑니다.
        MockKycNFT(d.kycNft).safeMint(vault);
        MockKycNFT(d.kycNft).safeMint(borrower);
        MockKycNFT(d.kycNft).safeMint(lender);

        // 대여자가 청산인이 되므로 대여 자산을 여유 있게 갖고 있어야 합니다.
        MockUSDC(d.usdc).mint(lender, 2_000e6);
        vm.startPrank(lender);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).deposit(1_000e6, lender);
        vm.stopPrank();

        MockWTGXX(d.wtgxx).mint(borrower, COLLATERAL);

        _open();
    }

    function _open() internal {
        // 만기는 시장에서 읽습니다. 차입자가 고르는 값이 아닙니다. 백서 3.1절.
        uint256 maturity = MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault);
        assertEq(maturity, block.timestamp + TERM, unicode"시장 만기가 기대와 다릅니다");

        vm.startPrank(borrower);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        evc.setAccountOperator(borrower, address(opener), true);
        opener.open(vault, COLLATERAL, PRINCIPAL, maturity, lender);
        vm.stopPrank();
    }

    /// 배포가 두 LTV를 벌려 놓았는지 확인합니다. 아래 청산 테스트들이 기대는 전제입니다.
    function test_ltvSplitAtDeploy() public view {
        assertEq(IEVault(d.debtVault).LTVBorrow(vault), LTV_BORROW);
        assertEq(IEVault(d.debtVault).LTVLiquidation(vault), LTV_LIQUIDATION);
    }

    /// @dev 만기 경과를 청산 가능 상태로 바꿉니다. 손으로 setLTV 를 부르지 않습니다.
    ///
    ///      발동만으로는 이 차입자(담보 100 대비 부채 약 80.8)가 아직 청산 대상이 아닙니다.
    ///      사다리가 개시 한도 92%에서 출발해 0까지 내려가므로, 조정담보가 부채 아래로
    ///      내려올 때까지 기다려야 합니다. 그 기다림까지 포함해 "부도 판정"으로 묶습니다.
    function _markDefaultOnChain() internal {
        if (controller.rampStartedAt(vault) == 0) {
            vm.prank(lender);
            controller.triggerMaturity(vault, borrower);
        }

        uint32 ramp = controller.rampDuration();
        for (uint256 i; i < 50; ++i) {
            (uint256 maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
            if (maxRepay > 0) return;
            skip(ramp / 50);
        }
        revert("ramp never opened liquidation");
    }

    // --- 만기만으로는 EVK가 꿈쩍하지 않는다. 그래서 컨트랙트가 필요하다 ---

    /// 만기가 지나도 EVK 기준으로는 건전합니다. 담보가 충분하기 때문입니다.
    /// @dev 이것이 백서 4.4절과 EVK가 어긋나는 지점이고, MaturityController 의 존재 이유입니다.
    function test_positionStillHealthyAfterMaturity() public {
        skip(TERM + 1 days);

        assertTrue(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));

        (uint256 collateralValue, uint256 liabilityValue) = IEVault(d.debtVault).accountLiquidity(borrower, true);
        assertGt(collateralValue, liabilityValue, unicode"담보가 부족해졌습니다");
    }

    /// 발동하지 않으면 청산이 거부됩니다.
    function test_liquidateRejectedWhileHealthy() public {
        skip(TERM + 1 days);

        (uint256 maxRepay, uint256 maxYield) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertEq(maxRepay, 0, unicode"청산 가능액이 0이 아닙니다");
        assertEq(maxYield, 0);

        vm.prank(lender);
        vm.expectRevert();
        IEVault(d.debtVault).liquidate(borrower, vault, PRINCIPAL, 0);
    }

    /// 발동하면 비로소 청산 가능해집니다. 사람이 아니라 컨트랙트가 엽니다.
    function test_ltvReductionEnablesLiquidation() public {
        skip(TERM + 1 days);
        _markDefaultOnChain();

        (uint256 maxRepay, uint256 maxYield) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertGt(maxRepay, 0, unicode"발동 후에도 청산이 불가합니다");
        assertGt(maxYield, 0);
    }

    /// 발동은 거버너의 재량이 아닙니다. 아무나 부르고, 만기 전에는 아무도 못 부릅니다.
    function test_liquidationPathNeedsNoGovernorDiscretion() public {
        assertEq(IEVault(d.debtVault).governorAdmin(), d.maturityController);

        vm.expectRevert();
        vm.prank(lender);
        controller.triggerMaturity(vault, borrower); // 아직 만기 전

        // 통지 창 안에서는 상대방만. 창이 지나면 지나가던 사람도 부릅니다.
        skip(TERM + controller.noticeWindow());
        vm.prank(makeAddr("passerby"));
        controller.triggerMaturity(vault, borrower);
        assertTrue(controller.marketClosed());
    }

    // --- 사전검사 ---

    function test_precheckPassesInNormalState() public view {
        assertTrue(precheck.canSettle(vault, lender));
        assertEq(uint256(precheck.check(vault, lender)), uint256(LiquidationPrecheck.Blocker.None));
    }

    function test_precheckDetectsPause() public {
        MockWTGXX(d.wtgxx).pause();
        assertFalse(precheck.canSettle(vault, lender));
        assertEq(uint256(precheck.check(vault, lender)), uint256(LiquidationPrecheck.Blocker.TokenPaused));
    }

    function test_precheckDetectsFrozenVault() public {
        MockWTGXX(d.wtgxx).freeze(vault);
        assertEq(uint256(precheck.check(vault, lender)), uint256(LiquidationPrecheck.Blocker.VaultFrozen));
    }

    function test_precheckDetectsFrozenRecipient() public {
        MockWTGXX(d.wtgxx).freeze(lender);
        assertEq(uint256(precheck.check(vault, lender)), uint256(LiquidationPrecheck.Blocker.RecipientFrozen));
    }

    function test_precheckDetectsUnwhitelistedRecipient() public {
        address outsider = makeAddr("outsider");
        assertEq(uint256(precheck.check(vault, outsider)), uint256(LiquidationPrecheck.Blocker.RecipientNotWhitelisted));
    }

    /// 컴플라이언스가 제거되면 전송은 통과하지만 사유로 남깁니다. 게이트 무력화 신호입니다.
    function test_precheckFlagsComplianceRemoval() public {
        MockWTGXX(d.wtgxx).setCompliance(address(0));
        assertEq(uint256(precheck.check(vault, lender)), uint256(LiquidationPrecheck.Blocker.ComplianceRemoved));
    }

    // --- 청산은 WTGXX를 만지지 않습니다 ---

    /// 담보 볼트가 동결돼도 청산 자체는 성공합니다. share만 움직이기 때문입니다.
    /// 대여자가 share를 들고도 토큰을 못 받는 상황이 여기서 만들어집니다.
    function test_liquidationSucceedsEvenWhenTokenTransferWouldFail() public {
        skip(TERM + 1 days);
        _markDefaultOnChain();

        MockWTGXX(d.wtgxx).freeze(vault);
        // 사전검사가 막아야 하는 상태입니다.
        assertFalse(precheck.canSettle(vault, lender), unicode"사전검사가 통과해버렸습니다");

        uint256 sharesBefore = IEVault(vault).balanceOf(lender);
        _liquidate();

        assertGt(IEVault(vault).balanceOf(lender), sharesBefore, unicode"share를 받지 못했습니다");
        assertEq(MockWTGXX(d.wtgxx).balanceOf(lender), 0, unicode"토큰이 이미 넘어왔습니다");

        // 인출에서 막힙니다.
        vm.prank(lender);
        vm.expectRevert();
        IEVault(vault).withdraw(1e18, lender, lender);
    }

    // --- 전체 청산 경로 ---

    /// S6. 만기 경과 → 청산 → 인출까지.
    function test_defaultLiquidationEndToEnd() public {
        skip(TERM + 1 days);

        // 1. 온체인 디폴트 판정
        assertTrue(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));

        // 2. 사전검사. 통과할 때만 진행합니다.
        assertTrue(precheck.canSettle(vault, lender));

        // 3. 만기 경과를 EVK 언어로 번역
        _markDefaultOnChain();

        // 4. 청산. 대여자가 담보 share를 받고 부채를 인수합니다.
        uint256 debtBefore = IEVault(d.debtVault).debtOf(borrower);
        _liquidate();

        uint256 lenderShares = IEVault(vault).balanceOf(lender);
        assertGt(lenderShares, 0, unicode"담보 share를 받지 못했습니다");
        assertLt(IEVault(d.debtVault).debtOf(borrower), debtBefore, unicode"부채가 줄지 않았습니다");

        // 5. 인출 직전 재확인. 4번과 5번 사이에 상태가 바뀔 수 있습니다.
        assertTrue(precheck.canSettle(vault, lender));

        // 6. 비로소 실제 WTGXX
        vm.prank(lender);
        IEVault(vault).withdraw(lenderShares, lender, lender);

        assertGt(MockWTGXX(d.wtgxx).balanceOf(lender), 0, unicode"WTGXX를 받지 못했습니다");
    }

    /// 청산인이 부채를 인수합니다. 백서 4.3절의 "담보를 가져가 환매"와 형태가 다릅니다.
    ///
    /// @dev 배치 없이 청산만 하면 청산인 계정에 부채가 남고, 인수 직후 건전성이 깨져
    ///      트랜잭션 전체가 실패합니다. 여기서는 배치 안에서 청산만 실행하고 상태 검사
    ///      전에 부채를 확인합니다. 대여자가 자기 볼트의 채권자이자 채무자가 되는 구조라
    ///      상환으로 즉시 상쇄되며, 그것이 _liquidate 의 두 번째 항목입니다.
    function test_liquidatorAssumesDebt() public {
        skip(TERM + 1 days);
        _markDefaultOnChain();

        uint256 borrowerDebtBefore = IEVault(d.debtVault).debtOf(borrower);
        assertEq(IEVault(d.debtVault).debtOf(lender), 0);

        _liquidate();

        // 배치 안에서 상환까지 끝나 부채가 0으로 남습니다.
        assertEq(IEVault(d.debtVault).debtOf(lender), 0, unicode"청산인 부채가 상쇄되지 않았습니다");
        assertLt(
            IEVault(d.debtVault).debtOf(borrower), borrowerDebtBefore, unicode"차입자 부채가 그대로입니다"
        );

        // 대여자의 대여 자산이 부채 인수분만큼 줄었습니다. 실질적으로 대여금을 담보로 바꾼 것입니다.
        assertLt(MockUSDC(d.usdc).balanceOf(lender), 1_000e6, unicode"대여자 자산이 줄지 않았습니다");
        assertGt(IEVault(vault).balanceOf(lender), 0, unicode"담보 share를 받지 못했습니다");
    }

    /// 잔여 담보는 차입자에게 남습니다. 백서 4.3절.
    function test_residualCollateralStaysWithBorrower() public {
        skip(TERM + 1 days);
        _markDefaultOnChain();

        uint256 borrowerSharesBefore = IEVault(vault).balanceOf(borrower);
        _liquidateWith(20e6); // 부분 청산

        uint256 remaining = IEVault(vault).balanceOf(borrower);
        assertLt(remaining, borrowerSharesBefore);
        assertGt(remaining, 0, unicode"부분 청산인데 잔여 담보가 없습니다");
    }

    /// @dev 대여자가 청산인이 됩니다.
    ///
    ///      청산과 상환을 한 배치로 묶습니다. 청산인은 담보 share와 함께 차입자의 부채를
    ///      인수하는데, 인수 직후 자기 건전성이 깨질 수 있습니다. LTV를 낮춘 상태이므로
    ///      받은 담보로는 인수한 부채를 덮지 못합니다.
    ///
    ///      배치 안에서는 상태 검사가 지연되므로 중간의 불건전 상태가 문제가 되지 않습니다.
    ///      대여자가 자기 볼트의 채권자이자 채무자가 되어 상쇄되는 구조이며, 백서 4.3절의
    ///      "대여자가 담보를 직접 가져간다"를 EVK에서 표현하는 방식입니다.
    function _liquidate() internal {
        _liquidateWith(type(uint256).max);
    }

    function _liquidateWith(uint256 desiredRepay) internal {
        (uint256 maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        uint256 repayAmount = desiredRepay < maxRepay ? desiredRepay : maxRepay;

        vm.startPrank(lender);
        evc.enableController(lender, d.debtVault);
        evc.enableCollateral(lender, vault);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: d.debtVault,
            onBehalfOfAccount: lender,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.liquidate, (borrower, vault, repayAmount, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: d.debtVault,
            onBehalfOfAccount: lender,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.repay, (type(uint256).max, lender))
        });
        evc.batch(items);
        vm.stopPrank();
    }
}
