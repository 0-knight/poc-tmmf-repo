// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EVaultTestBase} from "euler-vault-kit/test/unit/evault/EVaultTestBase.t.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IPriceOracle} from "evk/interfaces/IPriceOracle.sol";
import {TestERC20} from "euler-vault-kit/test/mocks/TestERC20.sol";
import {IRMTestFixed} from "euler-vault-kit/test/mocks/IRMTestFixed.sol";

import {FixedOneToOneOracle} from "../../src/oracle/FixedOneToOneOracle.sol";
import {WTGXXCollateralVault} from "../../src/vault/WTGXXCollateralVault.sol";

/// @title FixedOracleWiringTest
/// @notice 상수 오라클이 EVK 건전성 계산에 실제로 물리는지 확인합니다.
///
/// @dev 단위 테스트는 오라클을 직접 호출해 값만 봤습니다. 이 테스트는 EVK 부채 볼트가
///      checkAccountStatus 안에서 이 오라클을 불러 담보를 평가하는 경로를 봅니다.
///      선언이 맞는 것과 실제로 붙는 것은 다릅니다.
///
///      decimals 18(담보)과 6(부채)이 섞인 상태에서 LTV가 의도대로 적용되는지가 핵심입니다.
///      10^12 보정이 틀리면 담보가 백만 배로 잡히거나 백만분의 일로 잡힙니다.
contract FixedOracleWiringTest is EVaultTestBase {
    TestERC20 internal wtgxx; // 18 decimals
    TestERC20 internal usdc; // 6 decimals

    IEVault internal collateralVault;
    IEVault internal debtVault;
    FixedOneToOneOracle internal fixedOracle;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");

    uint16 internal constant LTV = 0.9e4; // 90%

    function setUp() public override {
        super.setUp();

        wtgxx = new TestERC20("Mock WTGXX", "WTGXX", 18, false);
        usdc = new TestERC20("Mock USDC", "USDC", 6, false);

        fixedOracle = new FixedOneToOneOracle(address(wtgxx), address(usdc));

        // 담보 볼트는 Radius 구현으로 배포합니다.
        address radiusImpl = address(new WTGXXCollateralVault(integrations, modules));
        vm.prank(admin);
        factory.setImplementation(radiusImpl);

        collateralVault = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(wtgxx), address(fixedOracle), address(usdc)))
        );
        collateralVault.setHookConfig(address(0), 0);

        debtVault = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(usdc), address(fixedOracle), address(usdc)))
        );
        debtVault.setHookConfig(address(0), 0);
        debtVault.setInterestRateModel(address(new IRMTestFixed()));
        debtVault.setMaxLiquidationDiscount(0.2e4);
        debtVault.setLTV(address(collateralVault), LTV, LTV, 0);

        // 대여자가 USDC를 공급합니다.
        usdc.mint(lender, 1_000e6);
        vm.startPrank(lender);
        usdc.approve(address(debtVault), type(uint256).max);
        debtVault.deposit(1_000e6, lender);
        vm.stopPrank();

        // 차입자가 담보를 예치합니다.
        wtgxx.mint(borrower, 100e18);
        vm.startPrank(borrower);
        wtgxx.approve(address(collateralVault), type(uint256).max);
        collateralVault.deposit(100e18, borrower);

        evc.enableCollateral(borrower, address(collateralVault));
        evc.enableController(borrower, address(debtVault));
        vm.stopPrank();
    }

    /// 우리 오라클이 EVK 인터페이스를 만족하는지 타입 수준에서 확인합니다.
    function test_oracleSatisfiesEvkInterface() public view {
        IPriceOracle evkView = IPriceOracle(address(fixedOracle));

        assertEq(evkView.getQuote(1e18, address(wtgxx), address(usdc)), 1e6);
        assertEq(evkView.name(), "FixedOneToOneOracle");

        (uint256 bid, uint256 ask) = evkView.getQuotes(5e18, address(wtgxx), address(usdc));
        assertEq(bid, 5e6);
        assertEq(ask, 5e6);
    }

    /// 담보 100 WTGXX(18)가 정확히 90 USDC(6) 가치로 평가돼야 합니다.
    /// 10^12 보정이 틀렸다면 이 값이 백만 배로 어긋납니다. 이 테스트가 보정의 증거입니다.
    function test_collateralValuedWithCorrectScaling() public view {
        (uint256 collateralValue, uint256 liabilityValue) = debtVault.accountLiquidity(borrower, false);

        assertEq(collateralValue, 90e6, unicode"담보 100e18 x LTV 0.9 는 90e6 이어야 합니다");
        assertEq(liabilityValue, 0);
    }

    /// LTV 한도 직전까지 빌려집니다.
    /// @dev EVK는 담보 > 부채를 요구합니다. 정확히 같으면 통과하지 않습니다.
    function test_borrowUpToLtv() public {
        vm.prank(borrower);
        debtVault.borrow(90e6 - 1, borrower);

        assertEq(usdc.balanceOf(borrower), 90e6 - 1);
        assertEq(debtVault.debtOf(borrower), 90e6 - 1);
    }

    /// 한도와 정확히 같으면 막힙니다. 경계가 어디인지 고정합니다.
    function test_borrowExactlyAtLtvReverts() public {
        vm.prank(borrower);
        vm.expectRevert();
        debtVault.borrow(90e6, borrower);
    }

    /// 부채가 있으면 담보 인출이 막힙니다. PoC의 S3 판정입니다.
    function test_collateralLockedWhileDebtOutstanding() public {
        vm.prank(borrower);
        debtVault.borrow(80e6, borrower);

        // 80 USDC 부채에 담보 100 WTGXX. 20을 빼면 80 * 0.9 = 72 < 80 이라 막혀야 합니다.
        vm.prank(borrower);
        vm.expectRevert();
        collateralVault.withdraw(20e18, borrower, borrower);

        assertEq(wtgxx.balanceOf(borrower), 0);
    }

    /// 상환하면 같은 인출이 통과합니다. 같은 호출이 부채 유무로 갈립니다.
    function test_collateralFreedAfterRepay() public {
        vm.startPrank(borrower);
        debtVault.borrow(80e6, borrower);

        usdc.approve(address(debtVault), type(uint256).max);
        debtVault.repay(type(uint256).max, borrower);
        evc.disableController(address(debtVault));

        collateralVault.withdraw(100e18, borrower, borrower);
        vm.stopPrank();

        assertEq(wtgxx.balanceOf(borrower), 100e18);
        assertEq(debtVault.debtOf(borrower), 0);
    }
}
