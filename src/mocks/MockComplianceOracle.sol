// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IKycBalance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title MockComplianceOracle
/// @notice WhitelistComplianceOracle의 목업.
///
/// @dev 실물(Sepolia 구현 0xE420f2c6…)의 확인된 동작을 재현합니다.
///      - canTransfer는 from과 amount를 무시하고 to만 판정합니다.
///        (실물 소스 421~433행에서 두 인자가 이름 없이 선언돼 있습니다)
///      - 오라클이 비활성이면 판정 없이 false를 반환합니다. 전면 동결입니다.
///      - to == address(0)이면 false가 아니라 revert합니다.
///      - 판정은 등록된 컨텍스트 중 하나라도 잔고 > 0이면 통과입니다.
///        실물은 컨텍스트 1개(KYC NFT)를 쓰고 최대 10개까지 등록 가능합니다.
contract MockComplianceOracle {
    error OracleZeroAddressNotAllowed();
    error NotAdmin();
    error MaxContextsExceeded();

    event OracleEnabled(address indexed oracle);
    event OracleDisabled(address indexed oracle);
    event AddedToOracleWhitelist(address indexed context);
    event RemovedFromOracleWhitelist(address indexed context);

    address public immutable admin;
    bool public oracleEnabled = true;
    uint256 public maxContexts = 10;

    address[] internal contexts;

    constructor(address admin_, address kycNft_) {
        admin = admin_;
        if (kycNft_ != address(0)) contexts.push(kycNft_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function canTransfer(
        address,
        /* from */
        address to,
        uint256 /* amount */
    )
        external
        view
        returns (bool)
    {
        if (!oracleEnabled) return false;
        if (to == address(0)) revert OracleZeroAddressNotAllowed();
        return _isAddressWhitelisted(to);
    }

    function _isAddressWhitelisted(address to) internal view returns (bool) {
        uint256 len = contexts.length;
        for (uint256 i = 0; i < len; ++i) {
            if (IKycBalance(contexts[i]).balanceOf(to) > 0) return true;
        }
        return false;
    }

    function getContractAddresses() external view returns (address[] memory) {
        return contexts;
    }

    function getMaxContexts() external view returns (uint256) {
        return maxContexts;
    }

    // --- 관리자 경로. 위험 시나리오 재현용 ---

    /// @dev 이걸 호출하면 canTransfer가 전부 false가 됩니다. 백서 4.3절 청산 경로가 막힙니다.
    function disableOracle() external onlyAdmin {
        oracleEnabled = false;
        emit OracleDisabled(address(this));
    }

    function enableOracle() external onlyAdmin {
        oracleEnabled = true;
        emit OracleEnabled(address(this));
    }

    function addContractAddress(address context) external onlyAdmin {
        if (contexts.length >= maxContexts) revert MaxContextsExceeded();
        contexts.push(context);
        emit AddedToOracleWhitelist(context);
    }

    function removeContractAddress(address context) external onlyAdmin {
        uint256 len = contexts.length;
        for (uint256 i = 0; i < len; ++i) {
            if (contexts[i] == context) {
                contexts[i] = contexts[len - 1];
                contexts.pop();
                emit RemovedFromOracleWhitelist(context);
                return;
            }
        }
    }
}
