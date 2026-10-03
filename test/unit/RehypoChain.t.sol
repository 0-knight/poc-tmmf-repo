// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";
import {RepoOpener} from "../../src/repo/RepoOpener.sol";
import {MaturityController} from "../../src/repo/MaturityController.sol";
import {MaturityRegistry} from "../../src/registry/MaturityRegistry.sol";
import {MockWTGXX} from "../../src/mocks/MockWTGXX.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockKycNFT} from "../../src/mocks/MockKycNFT.sol";

/// @title RehypoChainTest
/// @notice Wave 3. 사다리 한 칸 — A → B → C.
///
/// @dev 설계 문서의 갈래 2를 코드로 올립니다. 핵심 주장은 하나입니다 —
///      **대여자의 채권이 이미 ERC-4626 지분이므로, 그것을 그대로 다음 칸의 담보로
///      걸면 재담보가 된다.** 매니저 원장도, 포장 토큰도, 새 컨트랙트도 없습니다.
///
///      사다리 두 칸.
///
///        V_B   A가 WTGXX 100을 맡기고 USDC 80을 빌린다. B가 100을 댄다
///        V_C   B가 eV_B 100을 담보로 걸고 USDC 80을 빌린다. C가 100을 댄다
///
///      B의 순투입은 100 − 80 = 20입니다. 중간에 선 참여자는 자기 돈을 거의 내지
///      않으면서 양쪽에 서 있습니다 — 전통 repo의 매치북입니다.
///
///      **WTGXX는 맨 아래 칸에서 움직이지 않습니다.** B와 C는 WTGXX를 쥔 적이 없고,
///      쥘 일도 없습니다. V_C가 압류하는 것은 eV_B — V_B에 대한 청구권 — 입니다.
///      규제 자산의 이전 대리인 명부는 A와 V_A 사이에서 끝납니다.
contract RehypoChainTest is Test {
    DeployStack internal deployScript;
    DeployStack.Deployment internal d;
    DeployStack.Rung internal rung2;

    RepoOpener internal openerAB;
    RepoOpener internal openerBC;
    MaturityRegistry internal maturities;
    EthereumVaultConnector internal evc;

    address internal vaultA; // V_A — A의 담보 볼트 (WTGXX)
    address internal vaultB; // V_B — A가 빌리는 시장 (USDC). B의 채권이 eV_B
    address internal vaultC; // V_C — B가 빌리는 시장 (USDC). 담보가 eV_B

    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");

    uint256 internal constant COLLATERAL = 100e18; // WTGXX
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

        // 온보딩. 셋 다 자격이 있어야 합니다 — 청산 시 담보를 받을 수 있어야 하므로.
        MockKycNFT(d.kycNft).safeMint(vaultA);
        MockKycNFT(d.kycNft).safeMint(A);
        MockKycNFT(d.kycNft).safeMint(B);
        MockKycNFT(d.kycNft).safeMint(C);

        MockWTGXX(d.wtgxx).mint(A, COLLATERAL);
        MockUSDC(d.usdc).mint(B, 1_000e6);
        MockUSDC(d.usdc).mint(C, 1_000e6);

        vm.prank(B);
        MockUSDC(d.usdc).approve(vaultB, type(uint256).max);
        vm.prank(B);
        MockUSDC(d.usdc).approve(vaultC, type(uint256).max);
        vm.prank(C);
        MockUSDC(d.usdc).approve(vaultC, type(uint256).max);
    }

    function _maturity() internal view returns (uint256) {
        return maturities.marketMaturity(vaultB);
    }

    /// @dev C가 V_C에 자금을 댑니다. 사다리 꼭대기의 현금입니다.
    function _fundTop() internal {
        vm.prank(C);
        IEVault(vaultC).deposit(C_SUPPLIES, C);
    }

    /// @dev B가 V_B에 자금을 댑니다. 이 예치로 B는 eV_B 지분을 받습니다.
    function _fundMiddle() internal {
        vm.prank(B);
        IEVault(vaultB).deposit(B_SUPPLIES, B);
    }

    /// @dev A가 V_B에서 빌립니다. 사다리 맨 아래 칸.
    function _openAB() internal {
        vm.startPrank(A);
        MockWTGXX(d.wtgxx).approve(vaultA, type(uint256).max);
        evc.setAccountOperator(A, address(openerAB), true);
        openerAB.open(vaultA, COLLATERAL, A_BORROWS, _maturity(), B);
        vm.stopPrank();
    }

    /// @dev B가 자기 eV_B를 담보로 V_C에서 빌립니다. 재담보 한 칸.
    ///
    ///      예치를 opener에 맡기지 않고 따로 하는 이유는 B가 이미 대여자이기 때문입니다 —
    ///      eV_B는 A에게 빌려주면서 생긴 것이지 담보로 쓰려고 새로 만든 것이 아닙니다.
    function _openBC() internal {
        vm.startPrank(B);
        evc.setAccountOperator(B, address(openerBC), true);
        openerBC.open(vaultB, 0, B_BORROWS, _maturity(), C);
        vm.stopPrank();
    }

    function _buildChain() internal {
        _fundTop();
        _fundMiddle();
        _openAB();
        _openBC();
    }

    // --- 배선 ---

    /// 칸마다 자기 시장입니다. 만기는 같은 날짜로 맞춥니다.
    function test_rungIsItsOwnMarket() public view {
        assertEq(IEVault(vaultC).asset(), d.usdc);
        assertEq(IEVault(vaultC).governorAdmin(), rung2.controller);
        assertEq(maturities.marketMaturity(vaultC), maturities.marketMaturity(vaultB));
        assertTrue(maturities.isRegistrar(rung2.opener));
        assertTrue(maturities.isRegistrar(d.repoOpener), unicode"아래 칸 개시 컨트랙트가 지워졌습니다");
    }

    /// eV_B가 담보로 인식되고 가격이 풀립니다. 어댑터를 새로 쓰지 않았습니다.
    function test_collateralSharesArePriced() public view {
        assertEq(IEVault(vaultC).LTVBorrow(vaultB), 0.85e4);
        assertEq(IEVault(vaultC).LTVLiquidation(vaultB), 0.90e4);

        // 예치 전이라도 변환은 성립합니다. EVK의 가상 지분 때문에 1:1 에 가깝습니다.
        uint256 quoted = EulerRouter(d.router).getQuote(100e6, vaultB, d.usdc);
        assertGt(quoted, 0, unicode"eV_B가 가격으로 풀리지 않았습니다");
    }

    // --- 체인 세우기 ---

    /// 사다리 두 칸이 서고, 숫자가 설계 문서와 맞습니다.
    function test_chainStandsUp() public {
        _buildChain();

        // 맨 아래. A는 WTGXX를 맡기고 USDC를 받았습니다.
        assertEq(IEVault(vaultA).balanceOf(A), COLLATERAL);
        assertEq(IEVault(vaultB).debtOf(A), A_BORROWS);
        assertEq(MockUSDC(d.usdc).balanceOf(A), A_BORROWS);

        // 중간. B는 V_B의 대여자이면서 V_C의 차입자입니다.
        assertGt(IEVault(vaultB).balanceOf(B), 0, unicode"B가 eV_B를 못 받았습니다");
        assertEq(IEVault(vaultC).debtOf(B), B_BORROWS);

        // B의 순투입. 100을 넣고 80을 빌렸으니 20입니다.
        uint256 bNet = 1_000e6 - MockUSDC(d.usdc).balanceOf(B);
        assertEq(bNet, B_SUPPLIES - B_BORROWS, unicode"중간 참여자의 순투입이 20이 아닙니다");
        emit log_named_uint("B net capital (usdc)", bNet);

        // 꼭대기. C만 온전히 자기 돈을 댔습니다.
        assertEq(1_000e6 - MockUSDC(d.usdc).balanceOf(C), C_SUPPLIES);
    }

    /// WTGXX는 맨 아래 칸을 벗어나지 않습니다. 규제 자산의 경계입니다.
    function test_wtgxxNeverLeavesBottomRung() public {
        _buildChain();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(B), 0, unicode"B가 WTGXX를 쥐었습니다");
        assertEq(MockWTGXX(d.wtgxx).balanceOf(C), 0, unicode"C가 WTGXX를 쥐었습니다");
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultB), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultC), 0);
        assertEq(MockWTGXX(d.wtgxx).balanceOf(vaultA), COLLATERAL, unicode"담보가 V_A를 떠났습니다");
    }

    /// 담보가 두 번 잠깁니다. A는 WTGXX를, B는 eV_B를 뺄 수 없습니다.
    function test_bothRungsLockTheirCollateral() public {
        _buildChain();

        vm.prank(A);
        vm.expectRevert();
        IEVault(vaultA).withdraw(COLLATERAL, A, A);

        vm.prank(B);
        vm.expectRevert();
        IEVault(vaultB).withdraw(B_SUPPLIES, B, B);
    }

    /// 각 칸의 상대방이 따로 기록됩니다. 백서 4.5절의 손실 귀속이 칸마다 성립합니다.
    function test_counterpartyRecordedPerRung() public {
        _buildChain();

        assertEq(maturities.counterpartyOf(A), B);
        assertEq(maturities.counterpartyOf(B), C);
    }

    // --- 정상 종료. 위에서 아래로 ---

    /// 사다리가 통째로 풀립니다. A가 갚으면 B가 갚을 수 있고, 그래야 C가 회수합니다.
    ///
    /// @dev 순서가 강제됩니다. B의 현금은 A에게 나가 있으므로, B가 V_C에 갚으려면
    ///      먼저 V_B에서 환매해야 하고, 환매하려면 V_B에 현금이 있어야 합니다.
    ///      그 현금은 A의 상환으로 들어옵니다.
    function test_fullCycleUnwindsTopDown() public {
        _buildChain();
        skip(TERM);

        // 1. A가 갚고 담보를 되찾습니다.
        uint256 debtA = IEVault(vaultB).debtOf(A);
        assertGt(debtA, A_BORROWS, unicode"이자가 붙지 않았습니다");
        MockUSDC(d.usdc).mint(A, debtA);

        vm.startPrank(A);
        MockUSDC(d.usdc).approve(vaultB, type(uint256).max);
        IEVault(vaultB).repay(type(uint256).max, A);
        IEVault(vaultB).disableController();
        IEVault(vaultA).withdraw(COLLATERAL, A, A);
        vm.stopPrank();

        assertEq(MockWTGXX(d.wtgxx).balanceOf(A), COLLATERAL);

        // 2. B가 V_C에 갚습니다. 지갑에 현금이 모자라므로 V_B에서 환매해 메웁니다.
        uint256 debtB = IEVault(vaultC).debtOf(B);
        MockUSDC(d.usdc).mint(B, debtB);

        vm.startPrank(B);
        IEVault(vaultC).repay(type(uint256).max, B);
        IEVault(vaultC).disableController();

        // 3. 이제 eV_B가 풀렸으니 B가 환매합니다. 원금 + A가 낸 이자입니다.
        uint256 shares = IEVault(vaultB).balanceOf(B);
        IEVault(vaultB).redeem(shares, B, B);
        vm.stopPrank();

        assertEq(IEVault(vaultC).debtOf(B), 0);
        assertEq(IEVault(vaultB).balanceOf(B), 0);

        // 4. C가 회수합니다. B가 낸 이자가 붙어 있습니다.
        uint256 cShares = IEVault(vaultC).balanceOf(C);
        vm.prank(C);
        IEVault(vaultC).redeem(cShares, C, C);

        assertGt(MockUSDC(d.usdc).balanceOf(C), 1_000e6, unicode"C가 이자를 못 받았습니다");
        emit log_named_uint("C gain (usdc)", MockUSDC(d.usdc).balanceOf(C) - 1_000e6);
    }

    /// B가 먼저 갚으려 해도 막히지 않습니다 — 지갑에 현금만 있으면 됩니다.
    /// 막히는 것은 환매입니다. V_B의 현금이 A에게 나가 있기 때문입니다.
    function test_middleCannotRedeemBeforeBottomRepays() public {
        _buildChain();
        skip(TERM);

        uint256 debtB = IEVault(vaultC).debtOf(B);
        MockUSDC(d.usdc).mint(B, debtB);

        vm.startPrank(B);
        IEVault(vaultC).repay(type(uint256).max, B);
        IEVault(vaultC).disableController();

        // V_B의 현금은 100 − 80 = 20뿐입니다. 전액 환매가 안 됩니다.
        uint256 shares = IEVault(vaultB).balanceOf(B);
        vm.expectRevert();
        IEVault(vaultB).redeem(shares, B, B);

        // 남은 현금만큼은 됩니다. 설계 문서가 말한 "유동성은 가격 문제가 아니다"입니다.
        uint256 before = MockUSDC(d.usdc).balanceOf(B);
        IEVault(vaultB).withdraw(10e6, B, B);
        vm.stopPrank();

        assertEq(MockUSDC(d.usdc).balanceOf(B) - before, 10e6, unicode"남은 현금만큼도 못 뺐습니다");
        emit log_named_uint("V_B cash left (usdc)", MockUSDC(d.usdc).balanceOf(vaultB));
    }

    // --- 만기는 칸마다 ---

    /// 칸마다 자기 만기 컨트랙트를 가집니다. 아래 칸을 닫아도 위 칸은 열려 있습니다.
    function test_rungsCloseIndependently() public {
        _buildChain();
        skip(TERM);

        MaturityController ctrlB = MaturityController(d.maturityController);
        MaturityController ctrlC = MaturityController(rung2.controller);

        vm.prank(B);
        ctrlB.closeMarket();

        assertTrue(ctrlB.marketClosed());
        assertFalse(ctrlC.marketClosed(), unicode"아래 칸을 닫았는데 위 칸도 닫혔습니다");

        vm.prank(C);
        ctrlC.closeMarket();
        assertTrue(ctrlC.marketClosed());
    }

    /// 통지 권한도 칸마다 따로입니다. C는 B의 부도만, B는 A의 부도만 선언합니다.
    function test_noticeRightsArePerRung() public {
        _buildChain();
        skip(TERM);

        MaturityController ctrlB = MaturityController(d.maturityController);
        MaturityController ctrlC = MaturityController(rung2.controller);

        // 아래 칸: A의 상대방은 B입니다. C는 창 안에서 선언할 수 없습니다.
        assertTrue(ctrlB.canTrigger(vaultA, A, B));
        assertFalse(ctrlB.canTrigger(vaultA, A, C));

        // 위 칸: B의 상대방은 C입니다.
        assertTrue(ctrlC.canTrigger(vaultB, B, C));
        assertFalse(ctrlC.canTrigger(vaultB, B, A));
    }
}
