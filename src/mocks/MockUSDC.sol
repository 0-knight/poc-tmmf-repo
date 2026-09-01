// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "./MockERC20.sol";

/// @title MockUSDC
/// @notice PoC의 대여 자산. decimals 6.
/// @dev Sepolia 공식 테스트 USDC는 faucet 제한이 있어 시나리오를 반복 실행하기 어렵습니다.
///      발행량을 통제할 수 있는 목업을 씁니다.
contract MockUSDC is MockERC20 {
    constructor() MockERC20("Mock USD Coin", "USDC", 6) {}
}
