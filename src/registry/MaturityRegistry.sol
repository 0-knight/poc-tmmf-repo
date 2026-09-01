// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MaturityRegistry
/// @notice 대출의 만기를 온체인에 기록합니다. 그 이상은 하지 않습니다.
///
/// @dev EVK에는 만기 개념이 없습니다. 부채는 IRM으로 초당 누적되고 멈추지 않으며,
///      liquidate는 건전성이 깨져야만 통과합니다. 백서 4.4절이 정의하는
///      unicode"만기 경과 미상환"은 EVK에서 표현할 방법이 없습니다.
///
///      이 컨트랙트는 그 사유를 기록만 합니다. 청산을 강제하지도 막지도 않고,
///      다른 컨트랙트가 참조하지도 않습니다. 오프체인이 읽어 청산 판단의 근거로 씁니다.
///      PoC에서 실제 청산은 거버넌스가 setLTV를 낮춰 발동시키며, 이 레지스트리의
///      기록이 unicode"왜 낮췄는가"의 온체인 증거가 됩니다.
contract MaturityRegistry {
    error NotAuthorized();
    error AlreadySet(address account, uint256 currentMaturity);
    error MaturityInPast(uint256 maturity, uint256 nowTs);
    error NotSet(address account);
    error ZeroAddress();

    event MaturitySet(address indexed account, uint256 maturity, address indexed setBy);
    event MaturityCleared(address indexed account, address indexed clearedBy);

    /// @notice 계정별 만기 타임스탬프. 0이면 미설정.
    /// @dev 절대 시각입니다. 기간이 아닙니다. 백서 3.1절 "Maturity is a date, not a term."
    mapping(address account => uint256 maturity) public maturityOf;

    /// @notice 계정 본인 외에 기록을 남길 수 있는 주체. PoC에서는 Radius 백엔드.
    address public immutable registrar;

    constructor(address registrar_) {
        if (registrar_ == address(0)) revert ZeroAddress();
        registrar = registrar_;
    }

    modifier onlyAccountOrRegistrar(address account) {
        if (msg.sender != account && msg.sender != registrar) revert NotAuthorized();
        _;
    }

    /// @notice 만기를 기록합니다. 이미 설정돼 있으면 덮어쓰지 않습니다.
    function setMaturity(address account, uint256 maturity) external onlyAccountOrRegistrar(account) {
        if (account == address(0)) revert ZeroAddress();
        uint256 current = maturityOf[account];
        if (current != 0) revert AlreadySet(account, current);
        if (maturity <= block.timestamp) revert MaturityInPast(maturity, block.timestamp);

        maturityOf[account] = maturity;
        emit MaturitySet(account, maturity, msg.sender);
    }

    /// @notice 상환이나 청산으로 계약이 끝난 뒤 기록을 지웁니다.
    /// @dev 부채가 0인지 확인하지 않습니다. 이 컨트랙트는 부채를 모릅니다.
    ///      호출 시점의 정당성은 호출자 책임입니다.
    function clearMaturity(address account) external onlyAccountOrRegistrar(account) {
        if (maturityOf[account] == 0) revert NotSet(account);

        delete maturityOf[account];
        emit MaturityCleared(account, msg.sender);
    }

    /// @notice 만기가 지났는지 봅니다. 미설정 계정은 false입니다.
    function isDefaulted(address account) external view returns (bool) {
        uint256 maturity = maturityOf[account];
        return maturity != 0 && block.timestamp > maturity;
    }

    /// @notice 만기까지 남은 초. 미설정이거나 이미 지났으면 0입니다.
    function timeToMaturity(address account) external view returns (uint256) {
        uint256 maturity = maturityOf[account];
        if (maturity == 0 || block.timestamp >= maturity) return 0;
        return maturity - block.timestamp;
    }
}
