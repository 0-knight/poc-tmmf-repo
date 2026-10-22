// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";
import {RepoOpener} from "../../src/repo/RepoOpener.sol";
import {MaturityController} from "../../src/repo/MaturityController.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";
import {MockVariableOracle} from "../../src/mocks/MockVariableOracle.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

/// @dev encodeCall 용 최소 선언. IEVault는 합성 타입이라 상속된 멤버로 함수 포인터를
///      만들 수 없습니다.
interface ILiquidationCall {
    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance) external;
    function repay(uint256 amount, address receiver) external returns (uint256);
    function redeem(uint256 amount, address receiver, address owner) external returns (uint256);
}

/// @title ChainDefaultTest
/// @notice Wave 4. 사다리 세 칸 — A → B → C → D. 부족분이 생겼을 때 무엇이 어디로 가는가.
///
/// @dev 두 가지를 봅니다. 하나는 설계 문서의 전파 임계표를 다시 유도하는 것이고,
///      다른 하나는 칸이 셋이 되면서 드러난 EVC 제약입니다.
///
///      **1. 부족분은 가격으로 번지지 않습니다.**
///
///      임계표는 "손실이 지분 가격을 떨어뜨리고, 떨어진 가격이 위 칸의 건전성을 깬다"는
///      전제로 만들어졌습니다 — S가 4.7을 넘으면 B가, 20을 넘으면 C가, 29를 넘으면 D가
///      깨진다는 식이었습니다. **그 전제가 `CFG_DONT_SOCIALIZE_DEBT` 때문에 성립하지
///      않습니다.**
///
///      EVK는 청산 후 담보가 바닥난 차입자의 남은 부채를 전체 예금자에게 분산합니다
///      (`Liquidation.sol` 의 debt socialization). 그때 `totalBorrows` 가 줄고
///      `totalAssets` 도 줄어 지분 가격이 떨어집니다. 백서 4.5절이 그 분산을 거부하므로
///      우리는 플래그를 켰고, 그래서 **남은 부채가 차입자 계정에 그대로 남습니다.**
///      `totalBorrows` 가 줄지 않으니 `totalAssets` 도 그대로이고, 지분 가격이 움직이지
///      않습니다.
///
///        가격 전파   일어나지 않는다. eV_B 는 부족분이 생겨도 같은 값을 유지한다
///        실제 전파   B가 환매하려 할 때 현금이 모자란 것으로 나타난다
///
///      임계표가 틀린 것은 숫자가 아니라 **종류**입니다.
///
///      그리고 손실이 B에게 떨어지는 것은 B가 "직접 계약한 대여자"이기 때문이 아니라
///      **B가 그 시장의 유일한 대여자**이기 때문입니다. 지분 가격이 안 움직이므로
///      손실은 마지막에 환매하는 사람이 먹습니다. 시장 하나에 대여자 하나인 설계에서는
///      그 둘이 같은 사람이고, 여러 명이 섞이면 같지 않습니다. 설계 문서에 적어야 할
///      조건입니다.
///
///      **2. 중간 참여자는 자기 계정으로 자기 차입자를 청산할 수 없습니다.**
///
///      EVC는 계정당 컨트롤러를 하나만 허용하고(`EVC_ControllerViolation`), EVK의
///      청산은 컨트롤러 중립 연산이 아닙니다(`CONTROLLER_NEUTRAL_OPS` 에 OP_LIQUIDATE가
///      없습니다). 즉 청산인은 그 볼트를 자기 컨트롤러로 등록해야 합니다. 그런데 B는
///      이미 V_C의 차입자라 V_C가 B의 컨트롤러입니다. **B는 V_B를 두 번째 컨트롤러로
///      등록할 수 없습니다.**
///
///      사다리 중간에 선 참여자 전부에게 걸리는 제약이고, 칸이 둘일 때는 안 보였습니다 —
///      Wave 3에서 청산한 쪽은 꼭대기의 C였고 C는 차입자가 아니었습니다.
///
///      풀이는 EVC 서브계정입니다. 그리고 `_mayServeNotice` 가 `haveCommonOwner` 를
///      받아들이므로 그 서브계정이 통지도 함께 보낼 수 있습니다.
contract ChainDefaultTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    DeployStack.Rung internal rungC;
    DeployStack.Rung internal rungD;

    MockVariableOracle internal oracle;
    MaturityRegistry internal maturities;
    MaturityController internal ctrlB;
    EthereumVaultConnector internal evc;

    address internal vaultA; // V_A — A의 WTGXX 담보 볼트
    address internal vaultB; // V_B — A가 빌리는 시장. B가 댄다
    address internal vaultC; // V_C — B가 빌리는 시장. 담보가 eV_B. C가 댄다
    address internal vaultD; // V_D — C가 빌리는 시장. 담보가 eV_C. D가 댄다

    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");
    address internal D = makeAddr("D");
    address internal L = makeAddr("L"); // 제3자 청산인

    uint256 internal constant COLLATERAL = 100e18; // WTGXX
    uint256 internal constant SUPPLY = 100e6; // 칸마다 대여자가 대는 현금
    uint256 internal constant A_BORROWS = 80e6;
    uint256 internal constant B_BORROWS = 80e6;
    uint256 internal constant C_BORROWS = 70e6;
    uint256 internal constant WALLET = 1_000e6;
    uint256 internal constant TERM = 7 days;

    /// @dev 가격 충격 시점과 가격. 만기 전입니다 — 부족분은 담보 사건이고 만기 사건이
    ///      아니라는 것을 분리해 보려는 것입니다.
    uint256 internal constant SHOCK_AT = 3 days;
    uint256 internal constant SHOCK_PRICE = 0.70e18;

    /// @dev 칸마다 금리가 내려갑니다. V_B가 연 50%(배포 기본), 위로 10%p씩.
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
        ctrlB = MaturityController(d.maturityController);

        // 1:1 고정 오라클을 가변으로 갈아끼웁니다. 부족분을 만들 수 있어야 합니다.
        oracle = new MockVariableOracle(address(this), d.wtgxx, d.usdc);
        EulerRouter(d.router).govSetConfig(d.wtgxx, d.usdc, address(oracle));

        MockKycNFT(d.kycNft).safeMint(vaultA);
        MockKycNFT(d.kycNft).safeMint(A);
        MockKycNFT(d.kycNft).safeMint(B);
        MockKycNFT(d.kycNft).safeMint(C);
        MockKycNFT(d.kycNft).safeMint(D);
        MockKycNFT(d.kycNft).safeMint(L);
        // B의 서브계정도 압류 수령자가 될 수 있어야 합니다.
        MockKycNFT(d.kycNft).safeMint(_sub(B, 1));

        MockWTGXX(d.wtgxx).mint(A, COLLATERAL);
        MockUSDC(d.usdc).mint(B, WALLET);
        MockUSDC(d.usdc).mint(C, WALLET);
        MockUSDC(d.usdc).mint(D, WALLET);
        MockUSDC(d.usdc).mint(L, WALLET);

        _approveAll(B);
        _approveAll(C);
        _approveAll(D);
        _approveAll(L);

        // 위에서부터 자금을 채우고 아래에서부터 빌립니다.
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

    /// @dev EVC 서브계정. 주소 하위 1바이트를 XOR한 것이고 소유자가 같습니다.
    function _sub(address owner, uint8 id) internal pure returns (address) {
        return address(uint160(owner) ^ uint160(uint256(id)));
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

    /// @dev 시간을 흘리고 WTGXX 가격을 내립니다. 이 호출 뒤 같은 블록에서 청산합니다 —
    ///      그래야 이자 증가와 청산 효과가 섞이지 않습니다.
    function _ripen() internal {
        skip(SHOCK_AT);
        oracle.setPrice(SHOCK_PRICE);
    }

    /// @dev 제3자 청산인이 A를 청산합니다. 담보가 전량 넘어가고 부족분이 남습니다.
    ///
    ///      청산과 상환을 한 배치에 묶습니다. 청산 직후 청산인은 A의 부채를 인수한 상태라
    ///      담보(가격이 떨어진 eV_A)만으로는 개시 LTV를 못 맞춥니다. EVC가 계정 검사를
    ///      배치 끝으로 미루므로 그 안에서 갚아 버리면 통과합니다.
    function _liquidateA(address liquidator) internal returns (uint256 repaid, uint256 debtBefore) {
        (uint256 maxRepay, uint256 maxYield) = IEVault(vaultB).checkLiquidation(liquidator, A, vaultA);
        require(maxRepay > 0, "A not liquidatable after the price drop");

        debtBefore = IEVault(vaultB).debtOf(A);

        vm.startPrank(liquidator);
        evc.enableController(liquidator, vaultB);
        evc.enableCollateral(liquidator, vaultA);
        vm.stopPrank();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: vaultB,
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.liquidate, (A, vaultA, maxRepay, 0))
        });
        items[1] = IEVC.BatchItem({
            targetContract: vaultB,
            onBehalfOfAccount: liquidator,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.repay, (type(uint256).max, liquidator))
        });

        vm.prank(liquidator);
        evc.batch(items);

        emit log_named_uint("max repay          ", maxRepay);
        emit log_named_uint("max yield (eV_A)   ", maxYield);
        return (maxRepay, debtBefore);
    }

    function _shortfall() internal returns (uint256 repaid, uint256 debtBefore) {
        _ripen();
        return _liquidateA(L);
    }

    // --- 체인이 세 칸 선다 ---

    function test_threeRungsStandUp() public view {
        assertEq(IEVault(vaultB).debtOf(A), A_BORROWS);
        assertEq(IEVault(vaultC).debtOf(B), B_BORROWS);
        assertEq(IEVault(vaultD).debtOf(C), C_BORROWS);

        assertEq(maturities.counterpartyOf(A), B);
        assertEq(maturities.counterpartyOf(B), C);
        assertEq(maturities.counterpartyOf(C), D);

        // 칸을 올릴수록 LTV가 좁아집니다. 현금까지 가는 데 단계가 더 걸립니다.
        assertEq(IEVault(vaultB).LTVBorrow(vaultA), 0.92e4);
        assertEq(IEVault(vaultC).LTVBorrow(vaultB), 0.85e4);
        assertEq(IEVault(vaultD).LTVBorrow(vaultC), 0.78e4);

        // 만기는 한 날짜입니다. 사다리가 한 번에 끝나야 중간이 아래에서 받기 전에
        // 위에 갚아야 하는 일이 생기지 않습니다.
        uint256 m = maturities.marketMaturity(vaultB);
        assertEq(maturities.marketMaturity(vaultC), m);
        assertEq(maturities.marketMaturity(vaultD), m);
    }

    /// 순자본. 중간 둘은 자기 돈을 거의 내지 않습니다 — 전통 repo의 매치북입니다.
    function test_netCapitalOfTheChain() public {
        uint256 bNet = WALLET - MockUSDC(d.usdc).balanceOf(B);
        uint256 cNet = WALLET - MockUSDC(d.usdc).balanceOf(C);
        uint256 dNet = WALLET - MockUSDC(d.usdc).balanceOf(D);

        emit log_named_uint("B net capital", bNet);
        emit log_named_uint("C net capital", cNet);
        emit log_named_uint("D net capital", dNet);

        assertEq(bNet, SUPPLY - B_BORROWS, unicode"B 순자본이 20이 아닙니다");
        assertEq(cNet, SUPPLY - C_BORROWS, unicode"C 순자본이 30이 아닙니다");
        assertEq(dNet, SUPPLY, unicode"D는 온전히 자기 돈을 댑니다");

        // A에게 나간 돈은 80. 그걸 받치는 순자본의 합은 150입니다.
        assertEq(bNet + cNet + dNet, 150e6);
    }

    /// WTGXX는 맨 아래 칸을 벗어나지 않습니다. 칸이 셋이어도 같습니다.
    function test_wtgxxNeverLeavesBottomRung() public view {
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultA), COLLATERAL);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(B), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(C), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(D), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultB), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultC), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultD), 0);
    }

    // --- 칸이 셋이 되자 드러난 제약: 컨트롤러는 계정당 하나 ---

    /// **B는 자기 계정으로 A를 청산할 수 없습니다.** 이미 V_C의 차입자이기 때문입니다.
    ///
    /// @dev EVK 청산은 컨트롤러 중립 연산이 아니므로(`CONTROLLER_NEUTRAL_OPS`) 청산인이
    ///      그 볼트를 컨트롤러로 등록해야 하고, EVC는 계정당 컨트롤러를 하나만 허용합니다.
    function test_middleCannotLiquidateFromItsOwnAccount() public {
        _ripen();

        (uint256 maxRepay,) = IEVault(vaultB).checkLiquidation(B, A, vaultA);
        assertGt(maxRepay, 0, unicode"A가 청산 대상이 아닙니다");

        vm.prank(B);
        vm.expectRevert(bytes4(keccak256("EVC_ControllerViolation()")));
        evc.enableController(B, vaultB);

        // B의 컨트롤러는 여전히 V_C 하나뿐입니다.
        address[] memory controllers = evc.getControllers(B);
        assertEq(controllers.length, 1);
        assertEq(controllers[0], vaultC);
    }

    /// 풀이는 서브계정입니다. 소유자가 같으므로 B가 대신 서명합니다.
    ///
    /// @dev 서브계정에는 개인키가 없습니다. 그래서 두 가지를 소유자 계정으로 돌립니다 —
    ///      배치를 보내는 것과, 상환 대금을 내는 것입니다. `repay(amount, receiver)` 의
    ///      지불자는 인증된 계정이고 수령자는 부채가 줄어드는 계정이므로, B가 내고
    ///      서브계정의 부채를 지울 수 있습니다.
    function test_middleLiquidatesFromItsSubAccount() public {
        address Bsub = _sub(B, 1);
        _ripen();

        (uint256 maxRepay,) = IEVault(vaultB).checkLiquidation(Bsub, A, vaultA);
        assertGt(maxRepay, 0);

        vm.startPrank(B);
        evc.enableController(Bsub, vaultB);
        evc.enableCollateral(Bsub, vaultA);
        vm.stopPrank();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: vaultB,
            onBehalfOfAccount: Bsub,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.liquidate, (A, vaultA, maxRepay, 0))
        });
        // 지불자는 B, 부채가 지워지는 쪽은 서브계정입니다.
        items[1] = IEVC.BatchItem({
            targetContract: vaultB,
            onBehalfOfAccount: B,
            value: 0,
            data: abi.encodeCall(ILiquidationCall.repay, (type(uint256).max, Bsub))
        });

        vm.prank(B);
        evc.batch(items);

        assertEq(IEVault(vaultB).debtOf(Bsub), 0, unicode"서브계정에 부채가 남았습니다");
        assertEq(IEVault(vaultA).balanceOf(Bsub), COLLATERAL, unicode"서브계정이 담보를 못 받았습니다");
        assertEq(IEVault(vaultA).balanceOf(A), 0);

        // B의 V_C 포지션은 건드리지 않았습니다.
        assertGt(IEVault(vaultC).debtOf(B), 0);
        assertEq(IEVault(vaultB).balanceOf(B), SUPPLY, unicode"B의 eV_B가 움직였습니다");
    }

    /// 그 서브계정이 통지도 보낼 수 있습니다. `_mayServeNotice` 가 공통 소유자를 봅니다.
    ///
    /// @dev Wave 2.5에서 `haveCommonOwner` 를 넣은 것이 여기서 값을 합니다. 중간
    ///      참여자는 청산을 서브계정으로 해야 하는데, 통지 권한이 본계정에만 있으면
    ///      두 계정을 번갈아 써야 합니다.
    function test_subAccountMayServeTheNotice() public {
        address Bsub = _sub(B, 1);
        skip(TERM);

        assertTrue(ctrlB.canTrigger(vaultA, A, B));
        assertTrue(ctrlB.canTrigger(vaultA, A, Bsub), unicode"서브계정이 통지를 못 보냅니다");
        assertFalse(ctrlB.canTrigger(vaultA, A, L), unicode"창 안에서 제3자가 통지했습니다");

        vm.prank(B);
        ctrlB.triggerMaturity(vaultA, A);
        assertTrue(ctrlB.marketClosed());
    }

    // --- 핵심: 부족분은 가격을 움직이지 않는다 ---

    /// 청산 후 남은 부채가 차입자 계정에 그대로 남습니다. 분산되지 않습니다.
    function test_badDebtStaysOnDefaulter() public {
        (uint256 repaid, uint256 debtBefore) = _shortfall();

        uint256 remaining = IEVault(vaultB).debtOf(A);
        emit log_named_uint("A debt before liq", debtBefore);
        emit log_named_uint("repaid by L      ", repaid);
        emit log_named_uint("A debt after liq ", remaining);

        assertGt(remaining, 0, unicode"부족분이 안 생겼습니다. 가격을 더 내려야 합니다");
        assertEq(IEVault(vaultA).balanceOf(A), 0, unicode"담보가 남아 있으면 부족분 경로가 아닙니다");
        assertApproxEqAbs(remaining, debtBefore - repaid, 2, unicode"남은 부채가 계산과 다릅니다");

        // 그 부채는 볼트 장부에도 남아 있습니다. 사회화되면 여기서 빠집니다.
        assertApproxEqAbs(IEVault(vaultB).totalBorrows(), remaining, 2);
    }

    /// **지분 가격이 움직이지 않습니다.** 설계 문서의 임계표가 전제한 메커니즘이 없습니다.
    function test_shortfallDoesNotMoveSharePrice() public {
        _ripen();

        uint256 priceBefore = IEVault(vaultB).convertToAssets(1e6);
        uint256 assetsBefore = IEVault(vaultB).totalAssets();

        _liquidateA(L);

        uint256 priceAfter = IEVault(vaultB).convertToAssets(1e6);
        uint256 assetsAfter = IEVault(vaultB).totalAssets();

        emit log_named_uint("eV_B price before     ", priceBefore);
        emit log_named_uint("eV_B price after      ", priceAfter);
        emit log_named_uint("V_B totalAssets before", assetsBefore);
        emit log_named_uint("V_B totalAssets after ", assetsAfter);

        assertApproxEqAbs(priceAfter, priceBefore, 2, unicode"지분 가격이 움직였습니다");
        assertApproxEqAbs(assetsAfter, assetsBefore, 2, unicode"볼트 총자산이 움직였습니다");
    }

    /// 그래서 위 칸은 **숫자로는** 멀쩡합니다. 전파가 가격으로 일어나지 않습니다.
    function test_upperRungsStayHealthyByTheNumbers() public {
        _shortfall();

        (uint256 maxRepayB,) = IEVault(vaultC).checkLiquidation(C, B, vaultB);
        (uint256 maxRepayC,) = IEVault(vaultD).checkLiquidation(D, C, vaultC);

        assertEq(maxRepayB, 0, unicode"B가 가격 때문에 청산 대상이 됐습니다");
        assertEq(maxRepayC, 0, unicode"C가 가격 때문에 청산 대상이 됐습니다");

        // 담보 평가액도 그대로입니다. 전파가 일어날 통로 자체가 없습니다.
        (uint256 bCollateral, uint256 bLiability) = IEVault(vaultC).accountLiquidity(B, true);
        emit log_named_uint("B collateral value (liq)", bCollateral);
        emit log_named_uint("B liability value       ", bLiability);
        assertGt(bCollateral, bLiability, unicode"B의 담보가 부채 아래로 내려갔습니다");
    }

    /// 손실은 여기서 드러납니다 — **환매할 때 현금이 모자랍니다.**
    ///
    /// @dev B는 먼저 C에게 갚아야 eV_B가 풀립니다. 풀린 다음 환매를 시도하면 장부상
    ///      청구권과 볼트의 현금이 벌어져 있습니다. 그 차이가 A의 부실채권입니다.
    function test_lossSurfacesAtRedemption() public {
        _shortfall();
        uint256 badDebt = IEVault(vaultB).debtOf(A);

        // 1. B가 C에게 갚습니다. 지갑에 현금이 있으므로 막히지 않습니다.
        //
        //    컨트롤러를 끊는 것은 **볼트에게** 말해야 합니다. `evc.disableController` 는
        //    msg.sender 를 지우므로 차입자가 직접 부르면 아무 일도 하지 않습니다.
        vm.startPrank(B);
        IEVault(vaultC).repay(type(uint256).max, B);
        IEVault(vaultC).disableController();
        vm.stopPrank();

        // 2. 이제 eV_B가 풀렸습니다. 청구권과 현금을 나란히 놓습니다.
        uint256 shares = IEVault(vaultB).balanceOf(B);
        uint256 claim = IEVault(vaultB).convertToAssets(shares);
        uint256 cash = IEVault(vaultB).cash();

        emit log_named_uint("B claim (by price)", claim);
        emit log_named_uint("V_B cash on hand  ", cash);
        emit log_named_uint("gap               ", claim - cash);
        emit log_named_uint("A bad debt        ", badDebt);

        assertGt(claim, cash, unicode"청구권과 현금이 벌어지지 않았습니다");

        // 격차가 곧 A의 부실채권입니다. 정확히 같지는 않습니다 — EVK가 이자의 10%를
        // 지분으로 발행해 두었고(`Initialize.DEFAULT_INTEREST_FEE`) 그만큼 B의 몫이
        // 희석되어 있습니다. 3일치 이자의 10%라 0.3% 남짓 벌어집니다.
        assertApproxEqRel(claim - cash, badDebt, 0.01e18, unicode"격차가 부실채권과 다릅니다");

        // 장부상 청구권만큼은 못 뺍니다.
        vm.prank(B);
        vm.expectRevert();
        IEVault(vaultB).redeem(shares, B, B);

        // 남은 현금만큼은 뺍니다. 손실은 그 차이입니다.
        uint256 before = MockUSDC(d.usdc).balanceOf(B);
        vm.prank(B);
        IEVault(vaultB).withdraw(cash, B, B);
        assertEq(MockUSDC(d.usdc).balanceOf(B) - before, cash);
        assertGt(IEVault(vaultB).balanceOf(B), 0, unicode"못 받은 몫의 지분이 남아야 합니다");
    }

    /// 손실은 그 시장의 대여자에게 떨어집니다. 위 칸으로 넘어가지 않습니다.
    ///
    /// @dev **조건을 분명히 둡니다.** 손실이 B에게 가는 것은 B가 "직접 계약한 대여자"라서가
    ///      아니라 **B가 V_B의 유일한 대여자**이기 때문입니다. 지분 가격이 안 움직이므로
    ///      부족분은 마지막에 환매하는 사람이 먹습니다. 시장 하나에 대여자 하나인
    ///      설계에서는 그 둘이 같습니다.
    function test_lossLandsOnTheLenderOfThatMarket() public {
        _shortfall();

        // 청산인은 담보를 받고 차액만큼 벌었습니다. 할인 2%가 그것입니다.
        uint256 seized = IEVault(vaultA).balanceOf(L);
        assertEq(seized, COLLATERAL, unicode"청산인이 담보 전량을 못 받았습니다");

        // 수량을 **미리** 읽습니다. `vm.prank` 는 한 번만 쓰이고, 인자 안의 `balanceOf` 가
        // 그 한 번을 먼저 써 버립니다. 그러면 redeem 이 테스트 컨트랙트 권한으로 들어가
        // owner 와 sender 가 달라지고 E_InsufficientAllowance 로 막힙니다.
        vm.prank(L);
        IEVault(vaultA).redeem(seized, L, L);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(L), COLLATERAL);

        uint256 lSpent = WALLET - MockUSDC(d.usdc).balanceOf(L);
        uint256 lGot = (COLLATERAL * SHOCK_PRICE / 1e18) / 1e12; // WTGXX 100개의 USDC 가치
        emit log_named_uint("liquidator spent  ", lSpent);
        emit log_named_uint("liquidator got    ", lGot);
        assertLt(lSpent, lGot, unicode"청산 유인이 없습니다");

        // 모자란 쪽은 V_B의 대여자입니다. 장부는 100을 가리키는데 현금이 그만큼 없습니다.
        uint256 claim = IEVault(vaultB).convertToAssets(IEVault(vaultB).balanceOf(B));
        assertGt(claim, IEVault(vaultB).cash(), unicode"대여자 쪽에 부족분이 안 생겼습니다");

        // C와 D의 장부는 그대로입니다.
        assertGt(IEVault(vaultC).debtOf(B), 0);
        assertGt(IEVault(vaultD).debtOf(C), 0);
        assertEq(IEVault(vaultB).balanceOf(C), 0, unicode"C가 아래 칸 지분을 받았습니다");
        assertEq(MockWTGXX(d.wtgxx).balanceOf(C), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(D), 0);
    }

    // --- 아래로는 번지지 않는다 ---

    /// 꼭대기가 무너져도 아래 칸은 모릅니다. D가 C의 부도를 선언해도 A는 그대로입니다.
    function test_noDownwardPropagation() public {
        skip(TERM + 1);

        // 기준값은 선언 **직전**에 잡습니다. 기다리는 동안 붙은 이자는 부도와 무관합니다.
        uint256 debtA = IEVault(vaultB).debtOf(A);
        uint256 collateralA = IEVault(vaultA).balanceOf(A);
        uint256 maturityA = maturities.maturityOf(A);

        vm.prank(D);
        MaturityController(rungD.controller).triggerMaturity(vaultC, C);

        assertEq(IEVault(vaultB).debtOf(A), debtA, unicode"A의 부채가 바뀌었습니다");
        assertEq(IEVault(vaultA).balanceOf(A), collateralA, unicode"A의 담보가 움직였습니다");
        assertEq(maturities.maturityOf(A), maturityA);
        assertEq(maturities.counterpartyOf(A), B);
        assertEq(IEVault(vaultB).LTVLiquidation(vaultA), 0.95e4, unicode"아래 칸 청산선이 내려갔습니다");
        assertFalse(ctrlB.marketClosed(), unicode"꼭대기 부도가 아래 칸 시장을 닫았습니다");

        // 중간 칸도 닫히지 않았습니다. 칸마다 자기 컨트랙트입니다.
        assertFalse(MaturityController(rungC.controller).marketClosed());
        assertTrue(MaturityController(rungD.controller).marketClosed());
    }
}
