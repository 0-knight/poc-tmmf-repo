// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {DeployStack} from "../../script/DeployStack.s.sol";

/// @title ScaleUnitTest
/// @notice 사다리 금액을 환경 변수로 뺀 것이 맞게 도는가.
///
/// @dev 기간 상수와 같은 이유로 뺐습니다. 샌드박스 잔고가 테스트 기본값 100에 못 미치므로
///      시연에서는 줄여야 하는데, 그때마다 코드를 고쳐 다시 배포하는 일을 없앱니다.
///
///      **핵심은 차입액을 손으로 적지 않는다는 것입니다.** 비율에서 끌어내므로 `SCALE_UNIT`
///      을 아무 값으로 바꿔도 개시 LTV 여유가 그대로 유지됩니다. 손으로 적으면 단위를 줄일
///      때 한 칸만 안 고쳐서 개시가 조용히 막히는 일이 생깁니다.
contract ScaleUnitTest is Test {
    DeployStack internal deployScript;

    /// @dev 배포 스크립트의 내부 상수와 같은 값. 여기서 다시 적는 이유는 바뀌면 이 테스트가
    ///      깨져야 하기 때문입니다.
    uint16 internal constant DRAW_RUNG1 = 0.80e4;
    uint16 internal constant DRAW_RUNG2 = 0.80e4;
    uint16 internal constant DRAW_RUNG3 = 0.70e4;

    uint16 internal constant BORROW_LTV_RUNG1 = 0.92e4;
    uint16 internal constant BORROW_LTV_RUNG2 = 0.85e4;
    uint16 internal constant BORROW_LTV_RUNG3 = 0.78e4;

    /// @dev **주변 환경을 고정합니다.** `forge test` 는 셸의 환경 변수를 그대로 읽어갑니다.
    ///      시연 중에 `export SCALE_UNIT=20` 해 두면 아래 테스트가 20을 보고 깨졌습니다.
    ///      환경 변수를 읽는 함수를 테스트하면서 주변 환경에 의존하면 안 됩니다.
    ///      여기서 명시적으로 세우면 셸에 무엇이 있든 결과가 같습니다.
    function setUp() public {
        deployScript = new DeployStack();
        vm.setEnv("SCALE_UNIT", "100");
    }

    /// 100은 `DEFAULT_SCALE_UNIT` 과 같은 값이고, 기존 테스트가 쓰는 규모입니다.
    function test_hundredGivesTheTestScale() public view {
        assertEq(deployScript.scaleUnit(), 100);
        assertEq(deployScript.collateralAmount(), 100e18);
        assertEq(deployScript.supplyAmount(), 100e6);
    }

    /// decimals 보정이 자산마다 다릅니다. WTGXX 18, USDC 6.
    function test_decimalsDifferPerAsset() public view {
        uint256 unit = deployScript.scaleUnit();
        assertEq(deployScript.collateralAmount(), unit * 1e18);
        assertEq(deployScript.supplyAmount(), unit * 1e6);
    }

    /// 차입액이 예치액의 비율로 나와야 합니다.
    function test_drawFollowsRatio() public view {
        assertEq(deployScript.drawAmount(DRAW_RUNG1), 80e6);
        assertEq(deployScript.drawAmount(DRAW_RUNG2), 80e6);
        assertEq(deployScript.drawAmount(DRAW_RUNG3), 70e6);
    }

    /// **이게 이 파일의 존재 이유입니다.** 어떤 단위에서도 개시 LTV 아래여야 합니다.
    function test_everyRungStaysUnderItsBorrowLtv() public view {
        uint256 supply = deployScript.supplyAmount();

        assertLt(deployScript.drawAmount(DRAW_RUNG1), (supply * BORROW_LTV_RUNG1) / 1e4);
        assertLt(deployScript.drawAmount(DRAW_RUNG2), (supply * BORROW_LTV_RUNG2) / 1e4);
        assertLt(deployScript.drawAmount(DRAW_RUNG3), (supply * BORROW_LTV_RUNG3) / 1e4);
    }

    /// 환경 변수를 세우면 그 값이 쓰이고, 비율은 그대로 따라옵니다.
    /// @dev `setUp` 이 매 테스트마다 100으로 되돌리지만, 여기서도 끝에 복구합니다 —
    ///      이 파일 밖에서 `scaleUnit()` 을 읽는 테스트가 생겨도 안전하도록.
    function test_envOverrideScalesEverything() public {
        vm.setEnv("SCALE_UNIT", "20");

        assertEq(deployScript.scaleUnit(), 20);
        assertEq(deployScript.collateralAmount(), 20e18);
        assertEq(deployScript.supplyAmount(), 20e6);

        // 시연에서 쓸 숫자. 문서의 표와 같아야 합니다.
        assertEq(deployScript.drawAmount(DRAW_RUNG1), 16e6);
        assertEq(deployScript.drawAmount(DRAW_RUNG2), 16e6);
        assertEq(deployScript.drawAmount(DRAW_RUNG3), 14e6);

        // 줄여도 LTV 여유가 유지됩니다.
        uint256 supply = deployScript.supplyAmount();
        assertLt(deployScript.drawAmount(DRAW_RUNG3), (supply * BORROW_LTV_RUNG3) / 1e4);

        vm.setEnv("SCALE_UNIT", "100");
        assertEq(deployScript.scaleUnit(), 100);
    }

    /// 0은 사다리를 세울 수 없습니다. 조용히 넘어가면 개시가 영문 모를 곳에서 막힙니다.
    function test_rejectsZero() public {
        vm.setEnv("SCALE_UNIT", "0");

        vm.expectRevert();
        deployScript.scaleUnit();

        vm.setEnv("SCALE_UNIT", "100");
    }
}
