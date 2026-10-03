// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MaturityRegistry
/// @notice 대출의 만기를 온체인에 기록합니다. 그 이상은 하지 않습니다.
///
/// @dev EVK에는 만기 개념이 없습니다. 부채는 IRM으로 초당 누적되고 멈추지 않으며,
///      liquidate는 건전성이 깨져야만 통과합니다. 백서 4.4절이 정의하는
///      unicode"만기 경과 미상환"은 EVK에서 표현할 방법이 없습니다.
///
///      이 컨트랙트는 그 사유를 기록합니다. 청산을 강제하지도 막지도 않습니다.
///      PoC에서 실제 청산은 거버넌스가 setLTV를 낮춰 발동시키며, 이 레지스트리의
///      기록이 unicode"왜 낮췄는가"의 온체인 증거가 됩니다.
///
///      기록은 두 층입니다. **시장의 만기**는 백서 3.1절이 말하는 시장의 정의이고,
///      RepoOpener가 개시 시점에 이것과 맞는지 봅니다. **계정의 만기**는 그 시장에
///      들어온 계약의 사본이며, 시장 만기를 다음 기간으로 굴려도 그대로 남습니다.
contract MaturityRegistry {
    error NotAuthorized();
    error NotAdmin();
    error AlreadySet(address account, uint256 currentMaturity);
    error MaturityInPast(uint256 maturity, uint256 nowTs);
    error NotSet(address account);
    error ZeroAddress();
    error CounterpartyAlreadySet(address account, address current);

    event MaturitySet(address indexed account, uint256 maturity, address indexed setBy);
    event MaturityCleared(address indexed account, address indexed clearedBy);
    event RegistrarSet(address indexed previous, address indexed current);
    event RegistrarEnabled(address indexed who, bool enabled, address indexed by);
    event MarketMaturitySet(address indexed market, uint256 previous, uint256 current);
    event CounterpartySet(address indexed account, address indexed counterparty, address indexed setBy);

    /// @notice 계정별 만기 타임스탬프. 0이면 미설정.
    /// @dev 절대 시각입니다. 기간이 아닙니다. 백서 3.1절 "Maturity is a date, not a term."
    mapping(address account => uint256 maturity) public maturityOf;

    /// @notice 계약의 상대방. 차입자에게는 대여자, 즉 그 계약의 비부도 당사자입니다.
    ///
    /// @dev 백서 4.5절은 "손실은 그 차입자와 직접 계약한 대여자에게 귀속"이라고 적습니다
    ///      (`CFG_DONT_SOCIALIZE_DEBT` 의 근거). 그런데 그 "직접 계약한 대여자"가 전까지
    ///      스토리지에 없었습니다 — `RepoOpener` 가 인자로 받고도 이벤트로만 흘려보냈습니다.
    ///
    ///      이 기록이 쓰이는 곳이 둘입니다. `MaturityController` 가 통지 창 안에서 누가
    ///      부도를 선언할 수 있는지 판정하고(GMRA 2011 ¶10 — 비부도 당사자만 Default
    ///      Notice를 보낼 수 있습니다), 오프체인이 손실 귀속을 계산할 때 읽습니다.
    ///
    ///      0이면 상대방이 기록되지 않은 계약입니다. 그 경우 통지 창이 적용되지 않습니다 —
    ///      누구를 기다려야 할지 모르는 계약이 영원히 안 풀리는 것보다 낫습니다.
    mapping(address account => address counterparty) public counterpartyOf;

    /// @notice 시장별 만기 타임스탬프. 0이면 그 시장은 아직 열리지 않았습니다.
    ///
    /// @dev 백서 3.1절은 시장 하나가 만기 하나라고 적습니다. 전까지 이 컨트랙트는 계정별
    ///      만기만 들고 있었고, 차입자가 open 인자로 아무 날짜나 넣을 수 있었습니다.
    ///      같은 부채 볼트를 쓰는 참여자들이 서로 다른 만기를 갖게 되니 "시장"이라고
    ///      부를 수 없는 상태였습니다. 이제 만기는 시장의 속성이고 계정별 기록은 그
    ///      시장에 들어왔다는 사본입니다.
    ///
    ///      시장의 식별자로 부채 볼트 주소를 씁니다. 대여 자산과 만기가 함께 고정되는
    ///      단위가 부채 볼트이며, 재담보 체인을 올릴 때 사다리 칸마다 볼트가 하나씩
    ///      생기므로 칸마다 만기를 따로 둘 자리가 미리 열려 있습니다.
    mapping(address market => uint256 maturity) public marketMaturity;

    /// @notice 계정 본인 외에 기록을 남길 수 있는 주체. 개시 컨트랙트가 이 자리에 옵니다.
    ///
    /// @dev immutable이 아닌 이유는 순환 의존 때문입니다. 개시 컨트랙트는 생성자에서
    ///      레지스트리 주소를 받고, 레지스트리는 개시 컨트랙트를 registrar로 알아야 합니다.
    ///      둘 중 하나는 나중에 설정되어야 하며, 레지스트리 쪽이 위험이 작습니다.
    ///      기록만 하는 컨트랙트라 registrar가 바뀌어도 자금이 걸리지 않습니다.
    address public registrar;

    /// @notice 기록을 남길 수 있는 주체의 집합. 사다리 칸마다 개시 컨트랙트가 하나씩
    ///         생기므로 `registrar` 한 자리로는 모자랍니다.
    ///
    /// @dev 재담보 체인에서 각 칸은 자기 부채 볼트와 자기 `RepoOpener` 를 가집니다.
    ///      A가 V_B에서 빌릴 때는 opener #1이, B가 V_C에서 빌릴 때는 opener #2가
    ///      기록합니다. `registrar` 는 그중 첫 번째를 가리키고, 나머지는 이 집합에
    ///      들어옵니다.
    mapping(address who => bool enabled) public isRegistrar;

    /// @notice registrar를 바꿀 수 있는 주체. 이것은 immutable입니다.
    address public immutable admin;

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        registrar = admin_;
        isRegistrar[admin_] = true;
        emit RegistrarSet(address(0), admin_);
    }

    /// @notice 개시 컨트랙트를 배포한 뒤 registrar로 지정합니다.
    /// @dev 이 컨트랙트는 만기를 기록만 하고 청산을 강제하지 않으므로, registrar 교체가
    ///      기존 기록이나 자금에 영향을 주지 않습니다. 다만 감시 항목입니다.
    function setRegistrar(address registrar_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (registrar_ == address(0)) revert ZeroAddress();

        isRegistrar[registrar] = false;
        isRegistrar[registrar_] = true;

        emit RegistrarSet(registrar, registrar_);
        registrar = registrar_;
    }

    /// @notice registrar 를 하나 더 허용하거나 거둡니다. 사다리를 한 칸 올릴 때 씁니다.
    /// @dev `registrar` 자리는 그대로 두고 집합에만 더합니다. 칸마다 개시 컨트랙트가
    ///      하나씩 생기므로 한 자리로는 모자랍니다.
    function setRegistrarEnabled(address who, bool enabled) external {
        if (msg.sender != admin) revert NotAdmin();
        if (who == address(0)) revert ZeroAddress();

        isRegistrar[who] = enabled;
        emit RegistrarEnabled(who, enabled, msg.sender);
    }

    /// @notice 시장의 만기를 공표합니다. 다음 기간으로 굴릴 때 다시 부릅니다.
    ///
    /// @dev admin만 부릅니다. 이 값을 읽는 쪽이 둘입니다 — RepoOpener가 개시 시점에
    ///      차입자가 제시한 만기와 맞는지 보고, Wave 1의 만기 컨트랙트가 LTV를 내릴
    ///      시점을 여기서 읽습니다.
    ///
    ///      기존 계약의 계정별 기록은 건드리지 않습니다. 만기를 굴려도 이미 열린
    ///      계약의 만기는 그대로이며, 그래서 이 함수가 진행 중인 계약을 깨뜨릴 수
    ///      없습니다. 굴린 뒤 열리는 계약만 새 만기를 받습니다.
    function setMarketMaturity(address market, uint256 maturity) external {
        if (msg.sender != admin) revert NotAdmin();
        if (market == address(0)) revert ZeroAddress();
        if (maturity <= block.timestamp) revert MaturityInPast(maturity, block.timestamp);

        emit MarketMaturitySet(market, marketMaturity[market], maturity);
        marketMaturity[market] = maturity;
    }

    /// @notice 시장의 만기가 지났는지 봅니다. 미개설 시장은 false입니다.
    /// @dev Wave 1의 만기 컨트랙트가 LTV를 내리기 전에 이것을 봅니다.
    function isMarketMatured(address market) external view returns (bool) {
        uint256 maturity = marketMaturity[market];
        return maturity != 0 && block.timestamp >= maturity;
    }

    modifier onlyAccountOrRegistrar(address account) {
        if (msg.sender != account && !isRegistrar[msg.sender]) revert NotAuthorized();
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

    /// @notice 계약의 상대방을 기록합니다. 만기 기록이 먼저 있어야 합니다.
    /// @dev 덮어쓰지 않습니다. 계약 하나에 상대방 하나입니다. 다음 계약을 열려면
    ///      `clearMaturity` 로 함께 지워야 합니다.
    function setCounterparty(address account, address counterparty)
        external
        onlyAccountOrRegistrar(account)
    {
        if (account == address(0) || counterparty == address(0)) revert ZeroAddress();
        if (maturityOf[account] == 0) revert NotSet(account);

        address current = counterpartyOf[account];
        if (current != address(0)) revert CounterpartyAlreadySet(account, current);

        counterpartyOf[account] = counterparty;
        emit CounterpartySet(account, counterparty, msg.sender);
    }

    /// @notice 상환이나 청산으로 계약이 끝난 뒤 기록을 지웁니다.
    /// @dev 부채가 0인지 확인하지 않습니다. 이 컨트랙트는 부채를 모릅니다.
    ///      호출 시점의 정당성은 호출자 책임입니다.
    function clearMaturity(address account) external onlyAccountOrRegistrar(account) {
        if (maturityOf[account] == 0) revert NotSet(account);

        delete maturityOf[account];
        delete counterpartyOf[account];
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
