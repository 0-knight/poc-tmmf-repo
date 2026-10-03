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
import {ParticipantRegistry} from "../../src/registry/ParticipantRegistry.sol";
import {CollateralVaultHook} from "../../src/vault/CollateralVaultHook.sol";
import {DebtVaultAccessHook} from "../../src/vault/DebtVaultAccessHook.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

interface ILiquidationCall {
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function repay(uint256 amount, address receiver) external returns (uint256);
}

/// @title SeizureBoundaryTest
/// @notice Wave 2. 손실이 확정되기 전에 경계를 확인한다.
///
/// @dev M6에서 찾은 사실이 출발점입니다. **청산 성공이 담보 확보가 아닙니다.** EVK 압류는
///      볼트 share만 옮기고 WTGXX를 만지지 않으므로 이슈어의 화이트리스트가 발동하지
///      않습니다. 자격 없는 청산인이 share를 받고, 그다음 `withdraw` 에서 처음 막힙니다 —
///      그때는 이미 차입자의 부채를 인수해 버린 뒤입니다. 순서가 거꾸로였습니다.
///
///      Wave 2는 그 순서를 바로잡습니다. 압류가 들어오는 순간 수령자를 확인하고, 자격이
///      없으면 청산 트랜잭션 전체를 되돌립니다. 청산인은 부채를 떠안지 않습니다.
contract SeizureBoundaryTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    RepoOpener internal opener;
    MaturityController internal controller;
    ParticipantRegistry internal participants;
    EthereumVaultConnector internal evc;

    address internal vault;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal outsider = makeAddr("outsider");

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
        participants = ParticipantRegistry(d.participantRegistry);

        MockKycNFT(d.kycNft).safeMint(vault);
        MockKycNFT(d.kycNft).safeMint(borrower);
        MockKycNFT(d.kycNft).safeMint(lender);
        MockWTGXX(d.wtgxx).mint(borrower, COLLATERAL);

        MockUSDC(d.usdc).mint(lender, 2_000e6);
        vm.startPrank(lender);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).deposit(1_000e6, lender);
        vm.stopPrank();

        vm.startPrank(borrower);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        evc.setAccountOperator(borrower, address(opener), true);
        opener.open(vault, COLLATERAL, PRINCIPAL, MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault), lender);
        vm.stopPrank();
    }

    /// @dev 만기를 발동하고 사다리가 차입자 비율까지 내려오길 기다립니다.
    function _makeLiquidatable() internal returns (uint256 maxRepay) {
        skip(TERM + 1);
        if (controller.rampStartedAt(vault) == 0) {
            vm.prank(lender);
            controller.triggerMaturity(vault, borrower);
        }

        uint32 ramp = controller.rampDuration();
        for (uint256 i; i < 50; ++i) {
            (maxRepay,) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
            if (maxRepay > 0) return maxRepay;
            skip(ramp / 50);
        }
        revert("ramp never opened liquidation");
    }

    /// @dev 청산인 쪽 준비. 승인과 컨트롤러·담보 등록까지.
    ///
    ///      배치 호출과 분리한 이유는 `vm.expectRevert` 입니다. 되돌아가기를 기대하는
    ///      호출 **바로 앞**에 있어야 하므로, 준비 호출들이 사이에 끼면 안 됩니다.
    function _prepLiquidator(address liquidator) internal {
        vm.startPrank(liquidator);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        evc.enableController(liquidator, d.debtVault);
        evc.enableCollateral(liquidator, vault);
        vm.stopPrank();
    }

    /// @dev 청산과 상환을 한 배치에. 청산인은 담보와 함께 부채를 인수하므로
    ///      곧바로 갚지 않으면 자기 건전성이 깨집니다.
    function _batch(address liquidator, uint256 repayAmount) internal view returns (IEVC.BatchItem[] memory items) {
        items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: d.debtVault,
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.liquidate, (borrower, vault, repayAmount, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: d.debtVault,
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.repay, (type(uint256).max, liquidator))
        });
    }

    function _liquidateAs(address liquidator, uint256 repayAmount) internal {
        _prepLiquidator(liquidator);
        IEVC.BatchItem[] memory items = _batch(liquidator, repayAmount);
        vm.prank(liquidator);
        evc.batch(items);
    }

    /// @dev 되돌아가기를 기대하는 청산. 선택자를 그대로 확인합니다.
    function _expectLiquidationRevert(address liquidator, uint256 repayAmount, bytes memory expected) internal {
        _prepLiquidator(liquidator);
        IEVC.BatchItem[] memory items = _batch(liquidator, repayAmount);
        vm.prank(liquidator);
        vm.expectRevert(expected);
        evc.batch(items);
    }

    // --- 압류 수령자 경계 ---

    /// 자격 있는 대여자의 압류는 통과합니다. 기준선입니다.
    function test_eligibleLiquidatorSeizes() public {
        uint256 maxRepay = _makeLiquidatable();
        assertTrue(participants.isEligible(lender));

        _liquidateAs(lender, maxRepay);
        assertGt(IEVault(vault).balanceOf(lender), 0, unicode"담보 share를 받지 못했습니다");
    }

    /// 자격 없는 주소의 압류는 **압류 단계에서** 막힙니다. 인출까지 가지 않습니다.
    ///
    /// @dev Wave 1까지는 이 청산이 성공하고 outsider 가 부채를 인수한 뒤
    ///      `withdraw` 에서 처음 막혔습니다. 손실 확정 후에 경계를 보는 순서였습니다.
    function test_ineligibleLiquidatorBlockedAtSeizure() public {
        uint256 maxRepay = _makeLiquidatable();

        MockUSDC(d.usdc).mint(outsider, 2_000e6);
        assertFalse(participants.isEligible(outsider), unicode"outsider가 자격을 갖고 있습니다");

        _expectLiquidationRevert(
            outsider,
            maxRepay,
            abi.encodeWithSelector(CollateralVaultHook.E_SeizureRecipientNotEligible.selector, outsider)
        );

        // 부채도 담보도 움직이지 않았습니다.
        assertEq(IEVault(d.debtVault).debtOf(outsider), 0, unicode"자격 없는 청산인이 부채를 떠안았습니다");
        assertEq(IEVault(vault).balanceOf(outsider), 0);
        assertEq(IEVault(vault).balanceOf(borrower), COLLATERAL, unicode"차입자 담보가 줄었습니다");
    }

    /// 자격을 잃은 대여자의 압류도 막힙니다. 개시 시점 자격이 영구 통행증이 아닙니다.
    function test_lenderLosingEligibilityCannotSeize() public {
        uint256 maxRepay = _makeLiquidatable();

        MockWTGXX(d.wtgxx).freeze(lender);
        assertFalse(participants.isEligible(lender));

        _expectLiquidationRevert(
            lender,
            maxRepay,
            abi.encodeWithSelector(CollateralVaultHook.E_SeizureRecipientNotEligible.selector, lender)
        );
    }

    // --- 게이트가 답하지 못할 때의 대비 ---

    /// 컴플라이언스가 제거되면 게이트는 모두를 거부합니다. 그러면 청산이 영구히 막힙니다.
    /// 백서 6.2절이 적은 상황이며, 승인 목록이 그 출구입니다.
    function test_approvalListRescuesSeizureWhenGateCannotAnswer() public {
        uint256 maxRepay = _makeLiquidatable();

        MockWTGXX(d.wtgxx).setCompliance(address(0));
        (bool answered, bool allowed) = participants.gateSays(lender);
        assertTrue(answered, unicode"게이트가 revert했습니다");
        assertFalse(allowed, unicode"컴플라이언스가 없는데 게이트가 허용했습니다");
        assertFalse(participants.isEligible(lender));

        // 이 상태에서는 압류가 막힙니다.
        _expectLiquidationRevert(
            lender,
            maxRepay,
            abi.encodeWithSelector(CollateralVaultHook.E_SeizureRecipientNotEligible.selector, lender)
        );

        // 운영이 대여자를 승인하면 압류가 통과합니다.
        vm.prank(participants.admin());
        participants.setApproved(lender, true);
        assertTrue(participants.isEligible(lender));
        assertTrue(participants.isEligibleOnlyByApproval(lender), unicode"승인 경로로 통과한 것이 아닙니다");

        _liquidateAs(lender, maxRepay);
        assertGt(IEVault(vault).balanceOf(lender), 0);
    }

    /// 승인 목록이 불법 전송을 만들지는 않습니다. 실제 토큰은 이슈어가 막습니다.
    ///
    /// @dev 승인은 "청구권을 들고 기다릴 수 있는 자"를 정할 뿐입니다. WTGXX는 그다음
    ///      `withdraw` 에서 나가고 거기서 화이트리스트를 그대로 탑니다.
    function test_approvalDoesNotBypassIssuerWhitelist() public {
        uint256 maxRepay = _makeLiquidatable();

        MockUSDC(d.usdc).mint(outsider, 2_000e6);
        vm.prank(participants.admin());
        participants.setApproved(outsider, true);

        _liquidateAs(outsider, maxRepay);
        uint256 shares = IEVault(vault).balanceOf(outsider);
        assertGt(shares, 0, unicode"승인했는데 압류가 막혔습니다");

        // 그래도 실제 WTGXX는 못 받습니다. KYC NFT 가 없습니다.
        vm.prank(outsider);
        vm.expectRevert();
        IEVault(vault).withdraw(shares, outsider, outsider);

        assertEq(MockWTGXX(d.wtgxx).balanceOf(outsider), 0);
    }

    // --- 부채 볼트 입구 ---

    /// 자격 없는 주소는 대여자가 될 수 없습니다. 백서 3.5절.
    function test_ineligibleCannotLend() public {
        MockUSDC(d.usdc).mint(outsider, 500e6);

        vm.startPrank(outsider);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(DebtVaultAccessHook.E_NotEligible.selector, outsider));
        IEVault(d.debtVault).deposit(500e6, outsider);
        vm.stopPrank();
    }

    /// 자격 있는 주소가 자격 없는 주소에 share를 발행해 줄 수도 없습니다.
    /// 수령자를 보지 않으면 검사를 한 바퀴 돌아 무력화됩니다.
    function test_eligibleCannotMintSharesToIneligible() public {
        MockUSDC(d.usdc).mint(lender, 500e6);

        vm.startPrank(lender);
        vm.expectRevert(abi.encodeWithSelector(DebtVaultAccessHook.E_NotEligible.selector, outsider));
        IEVault(d.debtVault).deposit(500e6, outsider);
        vm.stopPrank();
    }

    /// **자격이 있어도** RepoOpener 를 건너뛴 직접 차입은 막힙니다.
    ///
    /// @dev 자격만 검사하면 이 구멍이 남습니다. 자격 있는 차입자가 `borrow` 를 직접
    ///      부르면 만기 레지스트리에 아무것도 남지 않아 `MaturityController` 가 발동할
    ///      근거가 사라집니다. 그래서 차입 훅이 만기 기록도 봅니다.
    ///
    ///      Wave 1까지 `DeployStack.t.sol` 의 `test_openAndRepay` 가 실제로 이 경로로
    ///      돌고 있었습니다.
    function test_eligibleBorrowerCannotSkipRepoOpener() public {
        address second = makeAddr("second");
        address secondVault = _onboardSecond(second);

        assertTrue(participants.isEligible(second), unicode"자격이 없으면 이 테스트의 요지가 사라집니다");
        assertEq(MaturityRegistry(d.maturityRegistry).maturityOf(second), 0);

        vm.startPrank(second);
        evc.enableCollateral(second, secondVault);
        evc.enableController(second, d.debtVault);
        vm.expectRevert(abi.encodeWithSelector(DebtVaultAccessHook.E_NoMaturityRecord.selector, second));
        IEVault(d.debtVault).borrow(10e6, second);
        vm.stopPrank();
    }

    /// 자격을 잃은 차입자는 자격 검사에서 먼저 막힙니다.
    function test_ineligibleCannotBorrowDirectly() public {
        address second = makeAddr("second");
        address secondVault = _onboardSecond(second);

        MockWTGXX(d.wtgxx).freeze(second);
        assertFalse(participants.isEligible(second));

        vm.startPrank(second);
        evc.enableCollateral(second, secondVault);
        evc.enableController(second, d.debtVault);
        vm.expectRevert(abi.encodeWithSelector(DebtVaultAccessHook.E_NotEligible.selector, second));
        IEVault(d.debtVault).borrow(10e6, second);
        vm.stopPrank();
    }

    /// RepoOpener 를 거치면 같은 참여자가 통과합니다. 정상 경로가 막히지 않았음을 봅니다.
    function test_secondBorrowerWorksThroughRepoOpener() public {
        address second = makeAddr("second");
        address secondVault = _onboardSecond(second);

        vm.startPrank(second);
        evc.setAccountOperator(second, address(opener), true);
        opener.open(
            secondVault, 0, 10e6, MaturityRegistry(d.maturityRegistry).marketMaturity(d.debtVault), lender
        );
        vm.stopPrank();

        assertEq(IEVault(d.debtVault).debtOf(second), 10e6);
        assertEq(MockUSDC(d.usdc).balanceOf(second), 10e6);
    }

    /// @dev 두 번째 참여자를 담보까지만 올려 둡니다. 만기 기록은 남기지 않습니다.
    ///
    ///      WTGXX 는 수령자가 화이트리스트여야 발행되므로(MockWTGXX.mint) 계정에도
    ///      KYC NFT 를 줍니다. 자격을 없애야 하는 테스트는 그 뒤에 freeze 합니다.
    function _onboardSecond(address who) internal returns (address secondVault) {
        (secondVault,) = deployScript.deployCollateralVault(d, who);
        MockKycNFT(d.kycNft).safeMint(secondVault);
        MockKycNFT(d.kycNft).safeMint(who);
        MockWTGXX(d.wtgxx).mint(who, COLLATERAL);

        // 담보 볼트 훅은 소유자만 보고 게이트는 보지 않습니다. 자기 볼트에 자기 돈을
        // 넣는 것은 백서 6장이 말하는 "진입"이 아닙니다.
        vm.startPrank(who);
        MockWTGXX(d.wtgxx).approve(secondVault, type(uint256).max);
        IEVault(secondVault).deposit(COLLATERAL, who);
        vm.stopPrank();
    }

    // --- 출구는 계속 열려 있어야 한다. 백서 6.1절 ---

    /// 자격을 잃어도 상환과 인출은 통과합니다. 접근 통제이고 수탁이 아닙니다.
    function test_exitStaysOpenWithoutEligibility() public {
        skip(TERM);

        MockWTGXX(d.wtgxx).setCompliance(address(0));
        assertFalse(participants.isEligible(borrower));

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        MockUSDC(d.usdc).mint(borrower, debt - PRINCIPAL);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        IEVault(d.debtVault).disableController();
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL);
    }

    /// 대여자도 자격 없이 환매할 수 있습니다.
    function test_lenderCanRedeemWithoutEligibility() public {
        skip(TERM);

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        MockUSDC(d.usdc).mint(borrower, debt - PRINCIPAL);
        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        vm.stopPrank();

        MockWTGXX(d.wtgxx).freeze(lender);
        assertFalse(participants.isEligible(lender));

        uint256 shares = IEVault(d.debtVault).balanceOf(lender);
        vm.prank(lender);
        IEVault(d.debtVault).redeem(shares, lender, lender);

        assertGt(MockUSDC(d.usdc).balanceOf(lender), 1_000e6, unicode"대여자가 환매하지 못했습니다");
    }

    // --- 전체 사이클이 여전히 돈다 ---

    /// 경계를 좁혀도 정상 경로는 그대로입니다. 개시 → 만기 → 상환.
    function test_fullCycleStillWorks() public {
        skip(TERM);

        uint256 debt = IEVault(d.debtVault).debtOf(borrower);
        assertGt(debt, PRINCIPAL);
        MockUSDC(d.usdc).mint(borrower, debt - PRINCIPAL);

        vm.startPrank(borrower);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).repay(type(uint256).max, borrower);
        IEVault(d.debtVault).disableController();
        IEVault(vault).withdraw(COLLATERAL, borrower, borrower);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(borrower), COLLATERAL);
        assertEq(IEVault(d.debtVault).debtOf(borrower), 0);
    }

    /// 만기 발동 후에는 입구가 자격 검사에서 **비활성화**로 바뀝니다.
    /// 두 설정의 연산 집합이 같아야 그 전환에 틈이 없습니다.
    function test_hookedOpsMatchClosedOps() public {
        (address hookTarget, uint32 hookedOps) = IEVault(d.debtVault).hookConfig();
        assertEq(hookTarget, d.debtVaultHook);
        assertEq(hookedOps, controller.CLOSED_OPS(), unicode"입구 집합이 만기 차단 집합과 다릅니다");

        skip(TERM);
        vm.prank(lender);
        controller.triggerMaturity(vault, borrower);

        (hookTarget, hookedOps) = IEVault(d.debtVault).hookConfig();
        assertEq(hookTarget, address(0), unicode"만기 후 연산이 비활성화되지 않았습니다");
        assertEq(hookedOps, controller.CLOSED_OPS());

        // 자격 있는 대여자도 더는 넣을 수 없습니다.
        vm.startPrank(lender);
        vm.expectRevert();
        IEVault(d.debtVault).deposit(100e6, lender);
        vm.stopPrank();
    }
}
