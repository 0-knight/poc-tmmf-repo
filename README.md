# Radius PoC — M1 · M2

WTGXX를 담보로 USDC를 대여하는 고정 만기 레포의 개념 검증.

- **M1** 의존성이 없는 독립 컨트랙트 넷과 목업 스택
- **M2** KYC NFT를 받을 수 있는 담보 볼트

## 설치

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup

make install      # EVK + EVK의 중첩 서브모듈
forge build
```

EVK를 의존성으로 씁니다. 두 단계가 필요합니다 — EVK 자체를 받고, EVK의 중첩
서브모듈(EVC, OpenZeppelin, permit2)을 초기화합니다. `make install`이 둘 다 합니다.

**패치로 받으셨다면 반드시 `make install`을 쓰세요.** `git apply`는 서브모듈을 인덱스에
등록하지 못하므로 `git submodule update`만으로는 EVK가 받아지지 않습니다.

`solc 0.8.30`을 씁니다. WisdomTree 배포분과 같은 컴파일러(`commit.73712a01`)입니다.

## 테스트

로컬 단위 테스트. 네트워크가 필요 없습니다.

```bash
forge test
```

Sepolia 실물을 상대로 하는 읽기 전용 fork 테스트. **실행은 로컬에서 이뤄지고, 트랜잭션을
보내지 않으며, 개인키도 가스도 필요 없습니다.**

```bash
cp .env.example .env      # SEPOLIA_RPC_URL 채우기
source .env
forge test --match-path "test/fork/*" -vv
```

`SEPOLIA_RPC_URL`이 없으면 fork 테스트는 조용히 건너뜁니다.

## 로컬 배포

```bash
anvil                                       # 별도 터미널
make deploy-local
```

스크립트가 배포 직후 상태를 자체 검증합니다. decimals, 배선, 오라클 보정, 게이트 초기 판정.

배포 후 게이트를 직접 눌러보려면:

```bash
RPC=http://127.0.0.1:8545
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
D=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

cast call --rpc-url $RPC $GATE "checkEntry(address)(uint8)" $D   # 5 = NotWhitelisted
cast send --rpc-url $RPC --private-key $PK $KYC "safeMint(address)" $D
cast call --rpc-url $RPC $GATE "checkEntry(address)(uint8)" $D   # 0 = Allowed

# 컴플라이언스를 지우면 토큰은 true를 주고 게이트는 막습니다
cast send --rpc-url $RPC --private-key $PK $WTGXX "setCompliance(address)" 0x0
cast call --rpc-url $RPC $WTGXX "isAddressWhitelisted(address,address,uint256)(bool)" 0x0 $D 0
cast call --rpc-url $RPC $GATE  "checkEntry(address)(uint8)" $D   # 2 = ComplianceRemoved
```

## 구성

```
src/
  interfaces/
    IWTGXX.sol                 Radius가 호출하는 함수만. 시그니처는 검증 소스에서 확인
    IEulerPriceOracle.sol      EVK 부채 볼트가 담보 환산에 쓰는 인터페이스
  oracle/
    FixedOneToOneOracle.sol    1대1 고정 + decimals 보정 (18 <-> 6)
  registry/
    MaturityRegistry.sol       만기 기록. 강제하지 않음
  gate/
    WTGXXGate.sol              백서 6장 진입 게이트
  vault/
    WTGXXCollateralVault.sol   EVault + onERC721Received
  mocks/
    MockERC20.sol              최소 ERC-20 베이스
    MockUSDC.sol               decimals 6
    MockWTGXX.sol              검증된 가드 배치 재현
    MockKycNFT.sol             소울바운드, safeMint
    MockComplianceOracle.sol   to만 판정, 비활성 시 false
```

## 설계 근거

### 게이트가 필요한 이유

WisdomTree가 토큰의 컴플라이언스 주소를 0으로 지우면 `isAddressWhitelisted`가 **무조건
`true`를 반환합니다**(검증 소스 251~257행). 토큰만 믿으면 그 순간 진입 제한이 사라집니다.
게이트가 `getCompliance() != 0`을 먼저 확인해 그 경로를 막습니다.

게이트는 어떤 경우에도 revert하지 않습니다. 고수준 호출은 코드 없는 주소에 대해
`extcodesize` 검사에서 revert하고 `try/catch`로 잡히지 않으므로 전부 `staticcall`로
처리합니다.

**진입에만 씁니다.** 상환과 인출 경로에서는 호출하지 마세요. 백서 6.1절이 출구 무검사를
요구합니다. 참여자가 나중에 화이트리스트에서 빠져도 담보를 되찾을 수 있어야 합니다.
그렇지 않으면 접근 통제가 아니라 수탁이 됩니다.

### 상수 오라클의 보정

WTGXX는 18 decimals, USDC는 6입니다. 가치는 1대1이지만 그대로 반환하면 10^12배 틀립니다.
18에서 6 방향은 내림 처리되어 10^12 미만이 0이 되는데, 담보 과소 평가 방향이라 안전합니다.

PoC 전용입니다. 프로덕션에서는 백서 4.2절이 요구하는 NAV 이탈 감시를 위해 Dataspan
`shadowNav`를 읽는 어댑터로 교체해야 합니다. 이 오라클은 WTGXX가 1달러에서 이탈해도
알아채지 못합니다.

### 만기 레지스트리가 아무것도 강제하지 않는 이유

EVK에는 만기 개념이 없습니다. 부채는 IRM으로 초당 누적되고 멈추지 않으며, `liquidate`는
건전성이 깨져야만 통과합니다. 백서 4.4절의 "만기 경과 미상환"을 EVK에서 표현할 방법이
없습니다.

이 컨트랙트는 그 사유를 기록만 합니다. PoC에서 실제 청산은 거버넌스가 `setLTV`를 낮춰
발동시키며, 레지스트리의 기록이 "왜 낮췄는가"의 온체인 증거가 됩니다.

### 담보 볼트가 포크가 아닌 이유

EVault의 모듈 구조를 건드릴 필요가 없습니다. `BeaconProxy`의 `fallback()`이 모든 셀렉터를
구현으로 delegatecall하고, `EVault`는 Solidity 기본 디스패치를 쓰므로 **상속만으로 함수가
추가됩니다.** EVK 소스는 한 줄도 고치지 않습니다.

크기는 주의가 필요합니다. EVault 구현이 EVK의 최적화 설정(`optimizer_runs = 20000`)에서
23,119바이트로 24,576 한계에 근접합니다. 이 프로젝트는 200으로 빌드해 17,889바이트이고
여유가 6,687바이트입니다. **배포 시 최적화 설정을 바꾸면 크기가 크게 달라집니다.**

`onERC721Received`는 발신자와 tokenId를 검사하지 않습니다. WisdomTree의 `safeMint`가
tokenId를 인자로 받지 않아 미리 알 수 없고, 발신자를 KYC NFT 주소로 제한하면 비콘
업그레이드 때 발행이 막히기 때문입니다. NFT 수신 자체는 볼트 회계에 영향이 없습니다.

### 목업이 재현하는 것

일반 ERC-20 목업으로는 드러나지 않는 실패 모드를 재현합니다. 검증 소스에서 확인한 배치입니다.

```
transfer       notPaused · notFrozen(msg.sender) · notFrozen(to)
transferFrom   notPaused · notFrozen(from) · notFrozen(msg.sender) · notFrozen(to)
batchTransfer  전체 성공 아니면 전체 revert
_transfer      from == to 이고 value > 0 이면 revert
burn           allowance 불필요
clawback       목적지 화이트리스트 필수
```

**화이트리스트는 `to`만 봅니다. 동결은 세 주소를 다 봅니다.** 층이 다릅니다.

`MockKycNFT.safeMint`는 수신자가 컨트랙트면 `onERC721Received`를 요구합니다. EVK 원본
볼트에는 그 함수가 없어 발행이 실패하며, 그것이 M2 포크의 존재 이유입니다.
`test_safeMint_revertsForNonReceiverContract`와 `test_safeMint_succeedsForReceiverContract`가
M2의 통과 기준을 미리 고정해둔 것입니다.

## 라이선스 주의

WisdomTree 소스는 파일마다 라이선스가 다릅니다. 구현부는 MIT, 인터페이스 일부는 BUSL-1.1
입니다. 이 리포의 목업은 **동작만 참고해 독립적으로 작성**했으며 원본 코드를 옮겨오지
않았습니다. 인터페이스도 시그니처만 직접 선언했습니다.

## Sepolia 참조 주소

```
WTGXX      프록시 0x0b2517eef907389F36fd87Add36E9118d364BD67
           구현   0xb73B016BD85f7289D189ee7ff9B31273A54D4b95
오라클      프록시 0xcA07Ab5B46d6A9B0E803db3525203053FFDD32F3
           구현   0xE420f2c6adfa8b048a8BfA049D09912135938Fd5
KYC NFT    프록시 0xF10fDD8A96b225Bd322c09C22B5eeB435F4C9d5B
           구현   0xD8916C906aFd5aAf1a7F24625eb120290C995429
```

셋 다 비콘 프록시입니다. `getImplementation()`이 공개돼 있어 업그레이드를 감시할 수
있습니다. 오라클 활성 플래그는 getter가 없지만 스토리지 슬롯
`keccak256("proxy.oracleEnabled")`로 직접 읽힙니다.

## 확정된 파라미터

```
unitOfAccount   USDC
초기 LTV        90%      청산 시 70%
이율            연 50% 고정. 거버넌스가 변경 가능
차입            담보 대비 80%
만기            개시 + 7일 (절대 타임스탬프)
거버넌스        배포자 EOA. 존치
```

## 다음 단계

M3은 CREATE2 볼트 팩토리와 HookTarget입니다. 팩토리는 배포 전에 주소를 공개해 참여자가
독립 검증할 수 있게 하고, HookTarget은 share 전송과 타인 예치를 막습니다. 둘을 막지 않으면
4626 share가 백서 2.1절이 거부한 래퍼 토큰이 됩니다.

**salt 설계를 M3에서 고정해야 합니다.** 이후 바꾸면 이미 공개한 주소가 무효가 됩니다.
