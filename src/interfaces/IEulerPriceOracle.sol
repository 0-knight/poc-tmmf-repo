// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IEulerPriceOracle
/// @notice EVK 부채 볼트가 담보를 unitOfAccount로 환산할 때 호출하는 인터페이스.
interface IEulerPriceOracle {
    function name() external view returns (string memory);

    /// @param inAmount base 자산의 수량
    /// @param base 환산할 자산
    /// @param quote 환산 결과의 단위
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256 outAmount);

    /// @notice 매수/매도 양방향 호가. 상수 오라클에서는 두 값이 같습니다.
    function getQuotes(uint256 inAmount, address base, address quote)
        external
        view
        returns (uint256 bidOutAmount, uint256 askOutAmount);
}
