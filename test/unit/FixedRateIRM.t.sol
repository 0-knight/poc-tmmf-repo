// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EVaultTestBase} from "euler-vault-kit/test/unit/evault/EVaultTestBase.t.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IIRM} from "evk/InterestRateModels/IIRM.sol";
import {TestERC20} from "euler-vault-kit/test/mocks/TestERC20.sol";

import {FixedRateIRM} from "../../src/irm/FixedRateIRM.sol";

contract FixedRateIRMTest is EVaultTestBase {
    FixedRateIRM internal irm;

    address internal governor = makeAddr("radius-governor");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant SECONDS_PER_YEAR = 365.2425 days;
    uint256 internal constant NOMINAL_APR = 0.5e18; // 50%

    function setUp() public override {
        super.setUp();
        irm = new FixedRateIRM(governor, NOMINAL_APR);
    }

    /// 연 50%가 초당 수익률로 정확히 환산돼야 합니다.
    function test_rateConversion() public view {
        uint256 expected = (NOMINAL_APR * 1e9) / SECONDS_PER_YEAR;
        assertEq(irm.ratePerSecond(), expected);
    }

    /// 이용률과 무관해야 합니다. 백서 3.3절이 이용률 방식을 거부합니다.
    function test_rateIndependentOfUtilization() public view {
        uint256 empty = irm.computeInterestRateView(address(0), 1_000e6, 0);
        uint256 half = irm.computeInterestRateView(address(0), 500e6, 500e6);
        uint256 full = irm.computeInterestRateView(address(0), 0, 1_000e6);

        assertEq(empty, half);
        assertEq(half, full);
        assertEq(full, irm.ratePerSecond());
    }

    /// 상태 변경 경로는 볼트 자신만 부를 수 있습니다. EVK 규약입니다.
    function test_computeInterestRateOnlyCallableByVault() public {
        vm.prank(stranger);
        vm.expectRevert(IIRM.E_IRMUpdateUnauthorized.selector);
        irm.computeInterestRate(address(0xBEEF), 0, 0);

        // 기대값을 **미리** 읽습니다. `vm.prank` 는 한 번만 쓰이고, 인자 평가 순서는
        // 언어가 보장하지 않습니다. `irm.ratePerSecond()` 가 먼저 평가되면 그 한 번을
        // 써 버려 아래 호출이 테스트 컨트랙트 권한으로 들어갑니다.
        uint256 expected = irm.ratePerSecond();
        vm.prank(address(0xBEEF));
        assertEq(irm.computeInterestRate(address(0xBEEF), 0, 0), expected);
    }

    function test_governorCanChangeRate() public {
        vm.prank(governor);
        irm.setRate(0.1e18);

        assertEq(irm.ratePerSecond(), (0.1e18 * 1e9) / SECONDS_PER_YEAR);
    }

    function test_strangerCannotChangeRate() public {
        vm.prank(stranger);
        vm.expectRevert(FixedRateIRM.E_NotGovernor.selector);
        irm.setRate(0.1e18);
    }

    function test_rejectsRateAboveEvkCap() public {
        // EVK MAX_ALLOWED_INTEREST_RATE 를 넘는 값.
        vm.prank(governor);
        vm.expectRevert();
        irm.setRate(1e30);
    }

    function test_constructorRejectsZeroGovernor() public {
        vm.expectRevert(FixedRateIRM.E_ZeroAddress.selector);
        new FixedRateIRM(address(0), NOMINAL_APR);
    }

    /// EVK 볼트에 붙여 실제로 이자가 붙는지 봅니다.
    /// @dev EVK는 초당 수익률을 복리로 누적합니다. 명목 50%의 7일치는 단리보다 큽니다.
    ///      상환액 검증 시 이 차이를 감안해야 합니다.
    function test_interestAccruesInVault() public {
        TestERC20 usdc = new TestERC20("USDC", "USDC", 6, false);

        IEVault vault = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(usdc), address(oracle), unitOfAccount))
        );
        vault.setHookConfig(address(0), 0);
        vault.setInterestRateModel(address(irm));
        vault.setLTV(address(eTST), 0.9e4, 0.9e4, 0);

        oracle.setPrice(address(usdc), unitOfAccount, 1e18);
        oracle.setPrice(address(assetTST), unitOfAccount, 1e18);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");

        usdc.mint(lender, 1_000e6);
        vm.startPrank(lender);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, lender);
        vm.stopPrank();

        assetTST.mint(borrower, 1_000e18);
        vm.startPrank(borrower);
        assetTST.approve(address(eTST), type(uint256).max);
        eTST.deposit(1_000e18, borrower);
        evc.enableCollateral(borrower, address(eTST));
        evc.enableController(borrower, address(vault));
        vault.borrow(100e6, borrower);
        vm.stopPrank();

        assertEq(vault.debtOf(borrower), 100e6);

        skip(7 days);

        uint256 debtAfter = vault.debtOf(borrower);
        uint256 simpleInterest = (100e6 * NOMINAL_APR * 7 days) / (1e18 * SECONDS_PER_YEAR);

        emit log_named_uint("debt after 7 days", debtAfter);
        emit log_named_uint("simple interest   ", simpleInterest);
        emit log_named_uint("actual interest   ", debtAfter - 100e6);

        assertGt(debtAfter, 100e6, unicode"이자가 붙지 않았습니다");
        // 복리라 단리보다 크되 크게 벗어나지 않아야 합니다.
        assertGe(debtAfter - 100e6, simpleInterest);
        assertLe(debtAfter - 100e6, (simpleInterest * 11) / 10);
    }
}
