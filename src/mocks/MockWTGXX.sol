// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "./MockERC20.sol";

interface ICompliance {
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);
}

/// @title MockWTGXX
/// @notice WTGXX의 목업. 검증 소스에서 확인한 가드 배치를 그대로 재현합니다.
///
/// @dev 구현 코드를 옮겨오지 않았습니다. Sepolia 배포분(구현 0xb73B016B…)에서 확인한
///      동작만 독립적으로 구현했습니다. 일반 ERC-20 목업으로는 드러나지 않는
///      실패 모드를 재현하는 것이 목적입니다.
///
///      확인된 가드 배치:
///        transfer      notPaused · notFrozen(msg.sender) · notFrozen(to)
///        transferFrom  notPaused · notFrozen(from) · notFrozen(msg.sender) · notFrozen(to)
///        batchTransfer notPaused · notFrozen(msg.sender)  — 전체 성공 아니면 전체 revert
///        mint / burn   REGISTRAR_ROLE. burn은 allowance 불필요
///        _transfer     from == to 이고 value > 0 이면 revert
///        verifyInputs  주소 0 또는 값 0 이면 revert (mint/burn)
///
///      화이트리스트는 to만 봅니다. 동결은 세 주소를 다 봅니다. 층이 다릅니다.
contract MockWTGXX is MockERC20 {
    error ContractPaused();
    error FrozenAccount();
    error AddressNotWhitelisted();
    error CannotTransferToYourself();
    error InvalidAddress();
    error InvalidValue();
    error NotRegistrar();

    event Paused();
    event Unpaused();
    event Frozen(address indexed account);
    event Unfrozen(address indexed account);
    event Clawback(address indexed from, address indexed to, uint256 value);

    address public immutable registrar;

    /// @notice 컴플라이언스 오라클 주소. 0이면 화이트리스트 검사를 건너뜁니다.
    address internal compliance;
    /// @notice 실물은 비콘 프록시입니다. 감시 대상이므로 목업에도 둡니다.
    address internal implementation;

    bool internal paused;
    mapping(address => bool) internal frozen;

    constructor(address registrar_, address compliance_, address implementation_)
        MockERC20("Mock WisdomTree Treasury MMF", "WTGXX", 18)
    {
        registrar = registrar_;
        compliance = compliance_;
        implementation = implementation_;
    }

    // --- 가드 ---

    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert NotRegistrar();
        _;
    }

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier notFrozen(address account) {
        if (frozen[account]) revert FrozenAccount();
        _;
    }

    modifier verifyInputs(address addr, uint256 value) {
        if (addr == address(0)) revert InvalidAddress();
        if (value == 0) revert InvalidValue();
        _;
    }

    // --- 컴플라이언스 확장 ---

    /// @dev 실물 검증 소스 251~257행의 구조입니다. 오라클이 없으면 무조건 true입니다.
    ///      게이트가 getCompliance() != 0을 먼저 확인해야 하는 이유입니다.
    function isAddressWhitelisted(address from, address to, uint256 amount) public view returns (bool) {
        if (compliance == address(0)) return true;
        return ICompliance(compliance).canTransfer(from, to, amount);
    }

    function isPaused() external view returns (bool) {
        return paused;
    }

    function isFrozen(address account) external view returns (bool) {
        return frozen[account];
    }

    function getCompliance() external view returns (address) {
        return compliance;
    }

    function getImplementation() external view returns (address) {
        return implementation;
    }

    // --- 전송 ---

    function transfer(address to, uint256 value)
        public
        override
        notPaused
        notFrozen(msg.sender)
        notFrozen(to)
        returns (bool)
    {
        if (!isAddressWhitelisted(msg.sender, to, value)) revert AddressNotWhitelisted();
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 tokens)
        public
        override
        notPaused
        notFrozen(from)
        notFrozen(msg.sender)
        notFrozen(to)
        returns (bool)
    {
        if (!isAddressWhitelisted(from, to, tokens)) revert AddressNotWhitelisted();
        _spendAllowance(from, tokens);
        _transfer(from, to, tokens);
        return true;
    }

    /// @dev 한 행이라도 실패하면 전체가 revert합니다. Layer 3 네팅에서 문제가 되는 지점입니다.
    function batchTransfer(address[] calldata toList, uint256[] calldata amounts)
        external
        notPaused
        notFrozen(msg.sender)
    {
        if (toList.length != amounts.length) revert InvalidValue();
        for (uint256 i = 0; i < toList.length; ++i) {
            if (frozen[toList[i]]) revert FrozenAccount();
            if (!isAddressWhitelisted(msg.sender, toList[i], amounts[i])) revert AddressNotWhitelisted();
            _transfer(msg.sender, toList[i], amounts[i]);
        }
    }

    /// @dev 실물의 _transfer 536행: from == to 이고 value > 0 이면 revert합니다.
    function _transfer(address from, address to, uint256 value) internal override {
        if (from == to && value > 0) revert CannotTransferToYourself();
        super._transfer(from, to, value);
    }

    // --- 이슈어 경로 ---

    function mint(address to, uint256 value)
        public
        override
        onlyRegistrar
        notPaused
        notFrozen(to)
        verifyInputs(to, value)
    {
        if (!isAddressWhitelisted(address(0), to, value)) revert AddressNotWhitelisted();
        super.mint(to, value);
    }

    /// @dev allowance가 필요 없습니다. 이슈어가 임의 주소에서 소각할 수 있습니다.
    function burn(address from, uint256 value) public override onlyRegistrar notPaused verifyInputs(from, value) {
        super.burn(from, value);
    }

    /// @dev 목적지 화이트리스트가 필수입니다. 임의 주소로 빼돌릴 수 없습니다.
    function clawback(address from, address to, uint256 value) external onlyRegistrar notPaused {
        if (!isAddressWhitelisted(from, to, value)) revert AddressNotWhitelisted();
        super._transfer(from, to, value);
        emit Clawback(from, to, value);
    }

    // --- 관리자 경로. 위험 시나리오 재현용 ---

    function pause() external onlyRegistrar {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyRegistrar {
        paused = false;
        emit Unpaused();
    }

    function freeze(address account) external onlyRegistrar {
        frozen[account] = true;
        emit Frozen(account);
    }

    function unfreeze(address account) external onlyRegistrar {
        frozen[account] = false;
        emit Unfrozen(account);
    }

    /// @dev 이걸 0으로 만들면 isAddressWhitelisted가 무조건 true가 됩니다. 게이트 무력화.
    function setCompliance(address compliance_) external onlyRegistrar {
        compliance = compliance_;
    }

    /// @dev 비콘 업그레이드 재현. 감시 서비스가 이 값의 변화를 봅니다.
    function setImplementation(address implementation_) external onlyRegistrar {
        implementation = implementation_;
    }
}
