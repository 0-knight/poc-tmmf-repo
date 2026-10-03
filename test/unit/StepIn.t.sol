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
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

interface ILiquidationCall {
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function repay(uint256 amount, address receiver) external returns (uint256);
}

/// @title StepInTest
/// @notice Wave 3. 중간이 무너져도 체인은 끊어지지 않는다 — 승계(step-in).
///
/// @dev 설계 문서가 "백서의 네팅이 아니라 승계"라고 바로잡은 지점을 코드로 봅니다.
///
///      B가 C에게 갚지 못하면 C가 B를 청산합니다. C가 압류하는 것은 **eV_B** —
///      V_B에 대한 B의 청구권 — 입니다. 그 지분을 받는 순간 **C가 V_B의 대여자가
///      됩니다.** A와의 계약은 그대로 살아 있고, A가 갚으면 그 현금이 이제 C에게
///      갑니다. 새 계약도, 재연결 코드도, 매니저 원장의 개입도 없습니다.
///
///      이것이 중첩 볼트 방식이 공짜로 주는 성질입니다. 대여자의 채권이 ERC-4626
///      지분이므로 그 지분의 주인이 바뀌면 대여자가 바뀝니다.
///
///      **A는 아무 영향도 받지 않습니다.** A의 부채도, 담보도, 만기도 그대로입니다.
///      부도의 피해는 B와 C 사이에서 끝납니다.
contract StepInTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    DeployStack.Rung internal rung2;

    RepoOpener internal openerAB;
    RepoOpener internal openerBC;
    MaturityRegistry internal maturities;
    MaturityController internal ctrlB;
    MaturityController internal ctrlC;
    EthereumVaultConnector internal evc;

    address internal vaultA;
    address internal vaultB;
    address internal vaultC;

    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant A_BORROWS = 80e6;
    uint256 internal constant B_SUPPLIES = 100e6;
    uint256 internal constant B_BORROWS = 80e6;
    uint256 internal constant C_SUPPLIES = 100e6;
    uint256 internal constant TERM = 7 days;

    function setUp() public {
        deployScript = new DeployStack();
        d = deployScript.run();
        (vaultA,) = deployScript.deployCollateralVault(d, A);
        vaultB = d.debtVault;
        rung2 = deployScript.deployRung(d, vaultB, 0.85e4, 0.90e4, 0.40e18);
        vaultC = rung2.debtVault;

        evc = EthereumVaultConnector(payable(d.evc));
        openerAB = RepoOpener(d.repoOpener);
        openerBC = RepoOpener(rung2.opener);
        maturities = MaturityRegistry(d.maturityRegistry);
        ctrlB = MaturityController(d.maturityController);
        ctrlC = MaturityController(rung2.controller);

        MockKycNFT(d.kycNft).safeMint(vaultA);
        MockKycNFT(d.kycNft).safeMint(A);
        MockKycNFT(d.kycNft).safeMint(B);
        MockKycNFT(d.kycNft).safeMint(C);

        MockWTGXX(d.wtgxx).mint(A, COLLATERAL);
        MockUSDC(d.usdc).mint(B, 1_000e6);
        MockUSDC(d.usdc).mint(C, 1_000e6);

        vm.prank(B);
        MockUSDC(d.usdc).approve(vaultB, type(uint256).max);
        vm.prank(C);
        MockUSDC(d.usdc).approve(vaultC, type(uint256).max);

        // 사다리 두 칸을 세웁니다.
        vm.prank(C);
        IEVault(vaultC).deposit(C_SUPPLIES, C);
        vm.prank(B);
        IEVault(vaultB).deposit(B_SUPPLIES, B);

        vm.startPrank(A);
        MockWTGXX(d.wtgxx).approve(vaultA, type(uint256).max);
        evc.setAccountOperator(A, address(openerAB), true);
        openerAB.open(vaultA, COLLATERAL, A_BORROWS, maturities.marketMaturity(vaultB), B);
        vm.stopPrank();

        vm.startPrank(B);
        evc.setAccountOperator(B, address(openerBC), true);
        openerBC.open(vaultB, 0, B_BORROWS, maturities.marketMaturity(vaultC), C);
        vm.stopPrank();
    }

    /// @dev 위 칸의 부도를 선언하고 사다리가 B의 비율까지 내려올 때까지 기다립니다.
    function _makeBLiquidatable() internal returns (uint256 maxRepay) {
        skip(TERM + 1);

        vm.prank(C);
        ctrlC.triggerMaturity(vaultB, B);

        uint32 ramp = ctrlC.rampDuration();
        for (uint256 i; i < 60; ++i) {
            (maxRepay,) = IEVault(vaultC).checkLiquidation(C, B, vaultB);
            if (maxRepay > 0) return maxRepay;
            skip(ramp / 60);
        }
        revert("ramp never opened liquidation on rung 2");
    }

    /// @dev C가 B를 청산합니다. 청산과 상환을 한 배치에 묶습니다.
    function _liquidateB(uint256 repayAmount) internal {
        vm.startPrank(C);
        MockUSDC(d.usdc).approve(vaultC, type(uint256).max);
        evc.enableController(C, vaultC);
        evc.enableCollateral(C, vaultB);
        vm.stopPrank();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: vaultC,
            onBehalfOfAccount: C,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.liquidate, (B, vaultB, repayAmount, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: vaultC,
            onBehalfOfAccount: C,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.repay, (type(uint256).max, C))
        });

        vm.prank(C);
        evc.batch(items);
    }

    // --- 승계 ---

    /// C가 B를 청산하면 C가 V_B의 대여자가 됩니다. 새 계약이 필요 없습니다.
    function test_liquidatingMiddleTransfersTheLendingPosition() public {
        uint256 bSharesBefore = IEVault(vaultB).balanceOf(B);
        assertEq(IEVault(vaultB).balanceOf(C), 0, unicode"C가 이미 eV_B를 들고 있습니다");

        uint256 maxRepay = _makeBLiquidatable();
        _liquidateB(maxRepay);

        uint256 cShares = IEVault(vaultB).balanceOf(C);
        assertGt(cShares, 0, unicode"C가 eV_B를 못 받았습니다");
        assertLt(IEVault(vaultB).balanceOf(B), bSharesBefore, unicode"B의 지분이 그대로입니다");

        emit log_named_uint("eV_B seized by C  ", cShares);
        emit log_named_uint("eV_B left with B  ", IEVault(vaultB).balanceOf(B));
    }

    /// A는 아무 영향도 받지 않습니다. 부채도, 담보도, 만기도, 상대방 기록도 그대로입니다.
    ///
    /// @dev 이것이 설계 문서가 말한 "피해는 당사자 둘 사이에서 끝난다"입니다.
    function test_bottomRungUntouchedByMiddleDefault() public {
        uint256 maxRepay = _makeBLiquidatable();

        // **청산 직전** 값을 잡습니다. 그 사이 시간이 흘러 A의 부채는 이자만큼 자랐고,
        // 그것은 B의 부도와 무관합니다. 여기서 보려는 것은 청산이 A를 건드리는가입니다.
        uint256 debtBefore = IEVault(vaultB).debtOf(A);
        uint256 maturityBefore = maturities.maturityOf(A);
        assertGt(debtBefore, A_BORROWS, unicode"기다리는 동안 이자가 붙지 않았습니다");

        _liquidateB(maxRepay);

        assertEq(IEVault(vaultB).debtOf(A), debtBefore, unicode"청산이 A의 부채를 건드렸습니다");
        assertEq(IEVault(vaultA).balanceOf(A), COLLATERAL, unicode"A의 담보가 움직였습니다");
        assertEq(maturities.maturityOf(A), maturityBefore);
        assertEq(maturities.counterpartyOf(A), B, unicode"A의 계약 기록이 바뀌었습니다");
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultA), COLLATERAL);

        // A의 시장은 아직 아무도 닫지 않았습니다. 위 칸의 부도가 아래로 번지지 않습니다.
        assertFalse(ctrlB.marketClosed(), unicode"위 칸 부도가 아래 칸 시장을 닫았습니다");
        assertEq(IEVault(vaultB).LTVLiquidation(vaultA), 0.95e4, unicode"아래 칸 청산선이 내려갔습니다");
    }

    /// 승계된 자리로 A의 상환이 들어옵니다. **A가 갚은 돈이 이제 C에게 갑니다.**
    ///
    /// @dev 체인이 끊어지지 않았다는 증거입니다. A는 B와 계약했고 B는 사라졌지만,
    ///      A의 상환은 V_B로 들어오고 그 V_B의 지분을 C가 들고 있습니다.
    function test_cCollectsWhatBWouldHaveCollected() public {
        uint256 maxRepay = _makeBLiquidatable();
        _liquidateB(maxRepay);

        uint256 cShares = IEVault(vaultB).balanceOf(C);
        uint256 cBefore = MockUSDC(d.usdc).balanceOf(C);

        // A가 갚습니다. 상대방이 바뀐 것을 A는 알 필요가 없습니다.
        uint256 debtA = IEVault(vaultB).debtOf(A);
        MockUSDC(d.usdc).mint(A, debtA);
        vm.startPrank(A);
        MockUSDC(d.usdc).approve(vaultB, type(uint256).max);
        IEVault(vaultB).repay(type(uint256).max, A);
        IEVault(vaultB).disableController();
        IEVault(vaultA).withdraw(COLLATERAL, A, A);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(A), COLLATERAL, unicode"A가 담보를 못 되찾았습니다");

        // 이제 C가 환매합니다. 승계받은 자리에서 원금과 이자가 나옵니다.
        vm.prank(C);
        IEVault(vaultB).redeem(cShares, C, C);

        uint256 collected = MockUSDC(d.usdc).balanceOf(C) - cBefore;
        assertGt(collected, 0, unicode"C가 승계한 자리에서 아무것도 못 받았습니다");
        emit log_named_uint("C collected from V_B", collected);
    }

    /// 승계는 코드가 아니라 성질입니다. 재연결을 위해 부른 함수가 없습니다.
    ///
    /// @dev 백서 5.3의 네팅(채무 고리의 현금 없는 상계)과는 다른 것입니다. 여기서는
    ///      고리를 상계한 것이 아니라 **대여자의 자리가 통째로 넘어간** 것입니다.
    function test_stepInNeedsNoExtraCall() public {
        uint256 maxRepay = _makeBLiquidatable();

        // 청산 한 번. 그 밖에 아무것도 부르지 않습니다.
        _liquidateB(maxRepay);

        // C는 V_B에 예치한 적이 없는데 지분을 가지고 있습니다.
        assertGt(IEVault(vaultB).balanceOf(C), 0);
        assertEq(IEVault(vaultB).debtOf(C), 0, unicode"C가 V_B의 차입자가 됐습니다");

        // A의 상대방 기록은 그대로 B입니다 — 레지스트리는 승계를 모릅니다.
        // 그래도 현금은 C에게 갑니다. 지분이 말을 하기 때문입니다.
        assertEq(maturities.counterpartyOf(A), B);
    }

    // --- 경계 ---

    /// 압류되는 것은 eV_B뿐입니다. C는 WTGXX 근처에도 가지 않습니다.
    function test_seizureStopsAtTheShareLayer() public {
        uint256 maxRepay = _makeBLiquidatable();
        _liquidateB(maxRepay);

        assertEq(MockWTGXX(d.wtgxx).balanceOf(C), 0, unicode"C가 WTGXX를 받았습니다");
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultA), COLLATERAL);

        // C가 V_A에서 직접 뺄 방법도 없습니다. 그 볼트의 지분을 가진 적이 없습니다.
        assertEq(IEVault(vaultA).balanceOf(C), 0);
    }

    /// B가 제때 갚으면 승계는 일어나지 않습니다. 정상 경로가 기본입니다.
    function test_noStepInWhenMiddleRepays() public {
        skip(TERM);

        uint256 debtB = IEVault(vaultC).debtOf(B);
        MockUSDC(d.usdc).mint(B, debtB);

        vm.startPrank(B);
        MockUSDC(d.usdc).approve(vaultC, type(uint256).max);
        IEVault(vaultC).repay(type(uint256).max, B);
        IEVault(vaultC).disableController();
        vm.stopPrank();

        assertEq(IEVault(vaultC).debtOf(B), 0);
        assertEq(IEVault(vaultB).balanceOf(C), 0, unicode"갚았는데 승계가 일어났습니다");
        assertGt(IEVault(vaultB).balanceOf(B), 0, unicode"B가 자기 자리를 잃었습니다");
    }

    /// 중간이 무너지는 동안에도 아래 칸의 만기 장치는 독립으로 돕니다.
    function test_bottomRungMaturityStillWorksAfterStepIn() public {
        uint256 maxRepay = _makeBLiquidatable();
        _liquidateB(maxRepay);

        // 아래 칸은 아직 아무도 선언하지 않았습니다.
        assertFalse(ctrlB.marketClosed(), unicode"아래 칸이 저절로 닫혔습니다");

        // 승계받은 C가 이제 A의 상대방 자리에서 선언할 수 있어야 할 텐데,
        // 레지스트리의 기록은 여전히 B입니다. 통지 창 안에서는 B만 선언합니다.
        assertFalse(ctrlB.canTrigger(vaultA, A, C), unicode"기록과 다른 주소가 선언할 수 있습니다");
        assertTrue(ctrlB.canTrigger(vaultA, A, B));

        // 창이 지나면 C도 선언할 수 있습니다. 포지션이 영원히 묶이지는 않습니다.
        vm.warp(ctrlB.noticeWindowEndsAt());
        assertTrue(ctrlB.canTrigger(vaultA, A, C));

        vm.prank(C);
        ctrlB.triggerMaturity(vaultA, A);
        assertTrue(ctrlB.marketClosed());
    }
}
