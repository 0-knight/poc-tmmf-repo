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
///      **백서 4.4절이 EVK에 없습니다.** 백서는 "담보가 충분해도 만기 미상환은 청산
///      사유"라고 합니다. EVK의 liquidate는 건전성이 깨져야만 통과하고, WTGXX는 $1
///      고정에 수익으로 늘기만 해서 만기가 지나도 깨지지 않습니다. PoC에서는 거버넌스가
///      setLTV를 낮춰 발동시키며, 이는 만기 경과를 담보 부족으로 위장하는 것입니다.
///      온체인 이벤트에는 "담보 부족"으로 남으므로 만기 레지스트리의 기록이 "왜 낮췄는가"의
///      근거가 됩니다.
///
///      **청산 성공이 담보 확보가 아닙니다.** EVK 청산은 볼트 share를 이전할 뿐 WTGXX를
///      만지지 않아 화이트리스트도 동결도 타지 않습니다. 실제 토큰은 그다음 인출에서
///      나오고, 거기서 처음 규제 자산 제약에 부딪힙니다.
contract LiquidationScenarioTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    RepoOpener internal opener;
    LiquidationPrecheck internal precheck;
    EthereumVaultConnector internal evc;

    address internal vault;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant PRINCIPAL = 80e6;
    uint256 internal constant TERM = 7 days;

    uint16 internal constant LTV_INITIAL = 0.9e4;
    uint16 internal constant LTV_ON_DEFAULT = 0.7e4;

    function setUp() public {
        deployScript = new DeployStack();
        d = deployScript.run();
        (vault,) = deployScript.deployCollateralVault(d, borrower);

        evc = EthereumVaultConnector(payable(d.evc));
        opener = RepoOpener(d.repoOpener);
        precheck = new LiquidationPrecheck(d.wtgxx);

        // 대여자가 청산인이 되므로 대여 자산을 여유 있게 갖고 있어야 합니다.
        MockUSDC(d.usdc).mint(lender, 2_000e6);
        vm.startPrank(lender);
        MockUSDC(d.usdc).approve(d.debtVault, type(uint256).max);
        IEVault(d.debtVault).deposit(1_000e6, lender);
        vm.stopPrank();

        MockKycNFT(d.kycNft).safeMint(vault);
        MockKycNFT(d.kycNft).safeMint(borrower);
        MockKycNFT(d.kycNft).safeMint(lender);
        MockWTGXX(d.wtgxx).mint(borrower, COLLATERAL);

        _open();
    }

    function _open() internal {
        vm.startPrank(borrower);
        MockWTGXX(d.wtgxx).approve(vault, type(uint256).max);
        evc.setAccountOperator(borrower, address(opener), true);
        opener.open(vault, COLLATERAL, PRINCIPAL, block.timestamp + TERM, lender);
        vm.stopPrank();
    }

    /// @dev 만기 경과를 EVK 언어로 번역합니다. PoC 한정 우회입니다.
    function _markDefaultOnChain() internal {
        IEVault(d.debtVault).setLTV(vault, LTV_ON_DEFAULT, LTV_ON_DEFAULT, 0);
    }

    // --- 백서 4.4절이 EVK에 없다는 증거 ---

    /// 만기가 지나도 건전성이 깨지지 않습니다. 담보가 충분하기 때문입니다.
    function test_positionStillHealthyAfterMaturity() public {
        skip(TERM + 1 days);

        assertTrue(MaturityRegistry(d.maturityRegistry).isDefaulted(borrower));

        (uint256 collateralValue, uint256 liabilityValue) = IEVault(d.debtVault).accountLiquidity(borrower, true);
        assertGt(collateralValue, liabilityValue, unicode"담보가 부족해졌습니다");
    }

    /// 그래서 청산이 거부됩니다. 백서 4.4절을 EVK가 표현하지 못합니다.
    function test_liquidateRejectedWhileHealthy() public {
        skip(TERM + 1 days);

        (uint256 maxRepay, uint256 maxYield) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertEq(maxRepay, 0, unicode"청산 가능액이 0이 아닙니다");
        assertEq(maxYield, 0);

        vm.prank(lender);
        vm.expectRevert();
        IEVault(d.debtVault).liquidate(borrower, vault, PRINCIPAL, 0);
    }

    /// LTV를 낮추면 비로소 청산 가능해집니다.
    function test_ltvReductionEnablesLiquidation() public {
        skip(TERM + 1 days);
        _markDefaultOnChain();

        (uint256 maxRepay, uint256 maxYield) = IEVault(d.debtVault).checkLiquidation(lender, borrower, vault);
        assertGt(maxRepay, 0, unicode"LTV 인하 후에도 청산이 불가합니다");
        assertGt(maxYield, 0);
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
