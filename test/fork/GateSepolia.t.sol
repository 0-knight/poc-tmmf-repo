// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WTGXXGate} from "../../src/gate/WTGXXGate.sol";
import {IWTGXX} from "../../src/interfaces/IWTGXX.sol";

/// @title GateSepoliaForkTest
/// @notice 실제 Sepolia WTGXX를 상대로 게이트를 돌립니다.
///
/// @dev 실행은 로컬에서 이뤄집니다. Sepolia에 트랜잭션을 보내지 않고 상태만 읽습니다.
///      가스도 개인키도 필요 없습니다.
///
///          export SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
///          forge test --match-path "test/fork/*" -vv
///
///      RPC가 없으면 조용히 건너뜁니다.
contract GateSepoliaForkTest is Test {
    // Sepolia 실배포 주소. cast로 직접 확인한 값입니다.
    address internal constant WTGXX = 0x0b2517eef907389F36fd87Add36E9118d364BD67;
    address internal constant COMPLIANCE_ORACLE = 0xcA07Ab5B46d6A9B0E803db3525203053FFDD32F3;
    address internal constant KYC_NFT = 0xF10fDD8A96b225Bd322c09C22B5eeB435F4C9d5B;
    address internal constant TOKEN_IMPL = 0xb73B016BD85f7289D189ee7ff9B31273A54D4b95;

    WTGXXGate internal gate;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        try vm.createSelectFork(rpc) {
            forked = true;
            gate = new WTGXXGate(WTGXX);
        } catch {
            forked = false;
        }
    }

    modifier onlyForked() {
        if (!forked) {
            emit log(unicode"SEPOLIA_RPC_URL not set - skipping fork tests");
            return;
        }
        _;
    }

    /// 배포분의 기본 사실을 고정합니다. 바뀌면 설계 전제가 흔들립니다.
    function test_fork_tokenFacts() public onlyForked {
        IWTGXX token = IWTGXX(WTGXX);

        assertEq(token.decimals(), 18, unicode"decimals가 18이 아니면 상수 오라클 보정이 틀립니다");
        assertEq(token.getCompliance(), COMPLIANCE_ORACLE, unicode"컴플라이언스 오라클이 교체됐습니다");
        assertEq(token.getImplementation(), TOKEN_IMPL, unicode"비콘 업그레이드가 발생했습니다");
        assertFalse(token.isPaused(), unicode"토큰이 일시정지 상태입니다");
    }

    /// 이력 없는 새 주소는 화이트리스트가 아니어야 합니다.
    /// true가 나오면 검사가 사실상 꺼진 것이고 게이트 설계를 다시 봐야 합니다.
    function test_fork_freshAddressIsNotWhitelisted() public onlyForked {
        address fresh = makeAddr("fresh-address-with-no-history");

        assertFalse(IWTGXX(WTGXX).isFrozen(fresh));
        assertFalse(IWTGXX(WTGXX).isAddressWhitelisted(address(0), fresh, 0));
        assertFalse(gate.canEnter(fresh));
        assertEq(uint256(gate.checkEntry(fresh)), uint256(WTGXXGate.Reason.NotWhitelisted));
    }

    /// from과 amount는 판정에 쓰이지 않습니다. 인자를 바꿔도 결과가 같아야 합니다.
    function test_fork_fromAndAmountAreIgnored() public onlyForked {
        address fresh = makeAddr("another-fresh-address");
        IWTGXX token = IWTGXX(WTGXX);

        bool asMint = token.isAddressWhitelisted(address(0), fresh, 0);
        bool asTransfer = token.isAddressWhitelisted(fresh, fresh, 1e18);
        bool asLarge = token.isAddressWhitelisted(WTGXX, fresh, type(uint256).max);

        assertEq(asMint, asTransfer);
        assertEq(asTransfer, asLarge);
    }

    /// 게이트는 zero 주소에 revert하지 않아야 합니다.
    /// 실제 오라클은 to == address(0)에 OracleZeroAddressNotAllowed로 revert합니다.
    function test_fork_zeroAddressDoesNotRevert() public onlyForked {
        assertFalse(gate.canEnter(address(0)));
        assertEq(uint256(gate.checkEntry(address(0))), uint256(WTGXXGate.Reason.ZeroTarget));
    }

    /// 오라클이 KYC NFT 잔고로 판정한다는 것을 확인합니다.
    function test_fork_oracleUsesKycNftContext() public onlyForked {
        (bool ok, bytes memory ret) = COMPLIANCE_ORACLE.staticcall(abi.encodeWithSignature("getContractAddresses()"));
        assertTrue(ok, unicode"getContractAddresses 호출 실패");

        address[] memory contexts = abi.decode(ret, (address[]));
        assertGt(
            contexts.length,
            0,
            unicode"컨텍스트가 비어 있으면 모든 주소가 비화이트리스트입니다"
        );
        assertEq(contexts[0], KYC_NFT, unicode"KYC NFT 컨텍스트가 교체됐습니다");
    }

    /// 오라클 활성 플래그. getter가 없어 스토리지 슬롯을 직접 읽습니다.
    function test_fork_oracleIsEnabled() public onlyForked {
        bytes32 slot = keccak256("proxy.oracleEnabled");
        bytes32 value = vm.load(COMPLIANCE_ORACLE, slot);
        assertEq(uint256(value), 1, unicode"오라클이 비활성이면 모든 전송이 막힙니다");
    }
}
