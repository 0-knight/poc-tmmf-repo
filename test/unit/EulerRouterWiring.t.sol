// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EVaultTestBase} from "euler-vault-kit/test/unit/evault/EVaultTestBase.t.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {TestERC20} from "euler-vault-kit/test/mocks/TestERC20.sol";
import {IRMTestFixed} from "euler-vault-kit/test/mocks/IRMTestFixed.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";

import {FixedOneToOneOracle} from "../../src/oracle/FixedOneToOneOracle.sol";
import {WTGXXCollateralVault} from "../../src/vault/WTGXXCollateralVault.sol";

/// @title EulerRouterWiringTest
/// @notice 볼트의 trailingData에 라우터를 두고, 그 뒤에서 어댑터를 교체할 수 있는지 봅니다.
///
/// @dev trailingData(자산·오라클·unitOfAccount)는 BeaconProxy 생성자 인자이므로 CREATE2
///      주소에 들어갑니다. 오라클 주소를 직접 박으면 어댑터를 교체할 때 볼트 주소가 바뀌고,
///      참여자가 명부 등록과 KYC NFT 발행을 처음부터 다시 해야 합니다. NFT는 소울바운드라
///      회수도 안 됩니다.
///
///      라우터를 오라클 자리에 두면 라우터 주소가 고정되므로 어댑터를 바꿔도 볼트 주소가
///      유지됩니다. 프로덕션에서 FixedOneToOneOracle을 Dataspan shadowNav 어댑터로 바꾸는
///      경로가 이것입니다.
contract EulerRouterWiringTest is EVaultTestBase {
    TestERC20 internal wtgxx; // 18 decimals
    TestERC20 internal usdc; // 6 decimals

    EulerRouter internal router;
    FixedOneToOneOracle internal adapter;

    IEVault internal collateralVault;
    IEVault internal debtVault;

    address internal governor = makeAddr("radius-governor");
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");

    uint16 internal constant LTV = 0.9e4;

    function setUp() public override {
        super.setUp();

        wtgxx = new TestERC20("Mock WTGXX", "WTGXX", 18, false);
        usdc = new TestERC20("Mock USDC", "USDC", 6, false);

        router = new EulerRouter(address(evc), governor);
        adapter = new FixedOneToOneOracle(address(wtgxx), address(usdc));

        address radiusImpl = address(new WTGXXCollateralVault(integrations, modules));
        vm.prank(admin);
        factory.setImplementation(radiusImpl);

        // 볼트의 오라클 자리에 라우터를 둡니다. 어댑터가 아니라 라우터입니다.
        collateralVault = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(wtgxx), address(router), address(usdc)))
        );
        collateralVault.setHookConfig(address(0), 0);

        debtVault = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(usdc), address(router), address(usdc)))
        );
        debtVault.setHookConfig(address(0), 0);
        debtVault.setInterestRateModel(address(new IRMTestFixed()));
        debtVault.setMaxLiquidationDiscount(0.2e4);
        debtVault.setLTV(address(collateralVault), LTV, LTV, 0);

        // 라우터 설정. 볼트 해석과 어댑터 지정.
        vm.startPrank(governor);
        router.govSetResolvedVault(address(collateralVault), true);
        router.govSetConfig(address(wtgxx), address(usdc), address(adapter));
        vm.stopPrank();

        usdc.mint(lender, 1_000e6);
        vm.startPrank(lender);
        usdc.approve(address(debtVault), type(uint256).max);
        debtVault.deposit(1_000e6, lender);
        vm.stopPrank();

        wtgxx.mint(borrower, 100e18);
        vm.startPrank(borrower);
        wtgxx.approve(address(collateralVault), type(uint256).max);
        collateralVault.deposit(100e18, borrower);
        evc.enableCollateral(borrower, address(collateralVault));
        evc.enableController(borrower, address(debtVault));
        vm.stopPrank();
    }

    /// 라우터를 거쳐도 담보 평가가 정확해야 합니다.
    function test_routerDrivesHealthCheck() public view {
        (uint256 collateralValue, uint256 liabilityValue) = debtVault.accountLiquidity(borrower, false);

        assertEq(collateralValue, 90e6, unicode"라우터 경유 담보 평가가 어긋났습니다");
        assertEq(liabilityValue, 0);
    }

    /// 라우터가 볼트 share를 기초자산으로 해석한 뒤 어댑터에 넘깁니다.
    /// 어댑터에는 볼트 주소를 등록하지 않았는데도 통과해야 합니다.
    function test_routerResolvesVaultBeforeAdapter() public view {
        uint256 out = router.getQuote(100e18, address(collateralVault), address(usdc));
        assertEq(out, 100e6);

        // 어댑터 단독으로는 볼트를 몰라도 됩니다. 라우터가 이미 풀었습니다.
        assertEq(adapter.getQuote(100e18, address(wtgxx), address(usdc)), 100e6);
    }

    function test_borrowThroughRouter() public {
        vm.prank(borrower);
        debtVault.borrow(90e6 - 1, borrower);

        assertEq(usdc.balanceOf(borrower), 90e6 - 1);
    }

    /// 핵심 검증. 어댑터를 바꿔도 볼트 주소는 그대로입니다.
    function test_adapterSwappableWithoutChangingVaultAddress() public {
        address vaultBefore = address(collateralVault);

        // 프로덕션에서 Dataspan shadowNav 어댑터로 교체하는 상황을 흉내냅니다.
        // 여기서는 같은 성격의 새 어댑터를 배포해 갈아 끼웁니다.
        FixedOneToOneOracle newAdapter = new FixedOneToOneOracle(address(wtgxx), address(usdc));

        vm.prank(governor);
        router.govSetConfig(address(wtgxx), address(usdc), address(newAdapter));

        assertEq(address(collateralVault), vaultBefore, unicode"볼트 주소가 바뀌었습니다");
        assertEq(router.getConfiguredOracle(address(wtgxx), address(usdc)), address(newAdapter));

        // 교체 후에도 건전성 계산이 계속 돌아야 합니다.
        (uint256 collateralValue,) = debtVault.accountLiquidity(borrower, false);
        assertEq(collateralValue, 90e6);
    }

    /// 어댑터 교체 권한은 거버넌스에 있습니다. 감시 항목입니다.
    function test_onlyGovernorCanSwapAdapter() public {
        FixedOneToOneOracle other = new FixedOneToOneOracle(address(wtgxx), address(usdc));

        vm.prank(borrower);
        vm.expectRevert();
        router.govSetConfig(address(wtgxx), address(usdc), address(other));
    }

    /// 부채가 있으면 담보가 잠깁니다. 라우터를 거쳐도 마찬가지입니다.
    function test_collateralLockedThroughRouter() public {
        vm.prank(borrower);
        debtVault.borrow(80e6, borrower);

        vm.prank(borrower);
        vm.expectRevert();
        collateralVault.withdraw(20e18, borrower, borrower);
    }
}
