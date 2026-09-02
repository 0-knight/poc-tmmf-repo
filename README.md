# Radius PoC — M1 ~ M5

WTGXX를 담보로 USDC를 대여하는 고정 만기 레포의 개념 검증.

- **M1** 의존성이 없는 독립 컨트랙트 넷과 목업 스택
- **M2** KYC NFT를 받을 수 있는 담보 볼트
- **M3** 주소를 사전에 알 수 있는 볼트 팩토리와 훅
- **M4** 고정 금리 IRM과 스택 전체 배포 스크립트
- **M5** 게이트와 만기를 강제하는 개시 경로. 정상 종료 시나리오

## 설치

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup

make install      # EVK + EVK의 중첩 서브모듈
forge build
```

EVK와 euler-price-oracle을 의존성으로 씁니다. 각각 중첩 서브모듈이 있어 초기화가 필요하며
`make install`이 전부 처리합니다.

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
anvil                # 별도 터미널

make deploy-local    # 스택 전체 — EVC, 볼트, 라우터, IRM, 팩토리
make deploy-gate     # M1 컨트랙트만 — 게이트를 손으로 눌러볼 때
```

`deploy-local`이 배포 직후 배선을 자체 검증합니다. 부채 볼트 자산·오라클·IRM, 사회화
플래그, 라우터 어댑터, 오라클 보정, 팩토리 오라클. 하나라도 어긋나면 배포가 실패합니다.

목업과 실물은 환경 변수로 전환합니다. M8에서 Sepolia로 넘어갈 때 같은 스크립트를 씁니다.

```bash
WTGXX_ADDRESS=0x0b2517eef907389F36fd87Add36E9118d364BD67 make deploy-local
```

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
  irm/
    FixedRateIRM.sol           이용률 무관 고정 금리
  repo/
    RepoOpener.sol             개시의 유일한 경로. 게이트·만기 강제
  vault/
    WTGXXCollateralVault.sol   EVault + onERC721Received
    CollateralVaultFactory.sol CREATE2 배포. implementation immutable
    CollateralVaultHook.sol    share 전송 차단, 예치를 소유자로 제한
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

### 상수 오라클의 보정과 볼트 해석

WTGXX는 18 decimals, USDC는 6입니다. 가치는 1대1이지만 그대로 반환하면 10^12배 틀립니다.
18에서 6 방향은 내림 처리되어 10^12 미만이 0이 되는데, 담보 과소 평가 방향이라 안전합니다.

**EVK는 담보를 토큰이 아니라 볼트 주소로 조회합니다.**

```
LiquidityUtils.sol:113
  oracle.getQuote(balance, collateral, unitOfAccount)
                          ^^^^^^^^^^ 담보 볼트 주소, 수량도 볼트 share
```

그래서 base가 ERC-4626이면 `convertToAssets`로 기초자산 수량을 구한 뒤 그 자산으로 다시
해석합니다. EulerRouter의 "resolved vault" 처리와 같습니다. 이 층이 없으면 EVK에 붙자마자
`PairNotSupported`로 revert합니다.

`base == quote`도 통과시킵니다. 부채 볼트가 자기 자산을 `unitOfAccount`로 조회하는 경로가
있습니다(`LiquidityUtils.sol:89`).

`FixedOracleWiring.t.sol`이 실제 EVK 볼트 두 개를 배포해 이 오라클을 물리고, 담보
100e18이 정확히 90e6으로 평가되는 것을 확인합니다.

### 볼트의 오라클 자리에는 라우터를 둡니다

`trailingData`(자산·오라클·unitOfAccount)는 `BeaconProxy` 생성자 인자라 CREATE2 주소에
들어갑니다. **오라클 주소를 직접 박으면 어댑터를 교체할 때 볼트 주소가 바뀌고**, 참여자가
명부 등록과 KYC NFT 발행을 처음부터 다시 해야 합니다. NFT는 소울바운드라 회수도 안 됩니다.

그래서 오라클 자리에 `EulerRouter`를 두고 그 뒤에서 어댑터를 교체합니다. 라우터 주소가
고정되므로 볼트 주소가 유지됩니다. 프로덕션에서 `FixedOneToOneOracle`을 Dataspan
`shadowNav` 어댑터로 바꾸는 경로가 이것입니다.

`EulerRouter`는 euler-price-oracle의 컨트랙트를 그대로 씁니다(GPL-2.0). 우리가 만들지
않습니다. `resolvedVaults`가 볼트 share를 기초자산으로 해석해주므로 어댑터는 토큰 쌍만
알면 됩니다.

**대가:** 어댑터 교체 권한이 거버넌스에 생깁니다. 담보 평가를 통째로 바꾸는 권한이므로
감시 항목입니다. `EulerRouterWiring.t.sol`이 이 경로 전체를 검증합니다.

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

### 볼트 주소를 예측 가능하게 만든 방법

EVK의 `GenericFactory`는 `new BeaconProxy(...)`를 쓰므로 주소가 팩토리 nonce로 정해집니다.
배포 순서에 따라 달라져서 **투자자가 자기 이름으로 명부에 오를 컨트랙트를 배포 전에 확인할
방법이 없습니다.** 백서 2.2절의 "등록에는 투자자 서명이 필요하다"가 형식만 남습니다.

`CollateralVaultFactory`가 `BeaconProxy`를 CREATE2로 직접 배포합니다. `BeaconProxy`는
생성자에서 `beacon = msg.sender`로 배포자를 비콘으로 삼으므로 **이 팩토리가 비콘을
겸합니다.** public 변수 `implementation`이 프록시가 찾는 셀렉터(`0x5c60da1b`)를 제공합니다.

```
salt              keccak256(borrower, asset)
implementation    immutable. 교체 함수 없음
oracle            EulerRouter. 어댑터 교체가 주소를 바꾸지 않도록
```

salt에 자산을 넣는 이유는 확장 때문입니다. 차입자 주소만 쓰면 자산이 늘 때 새 팩토리를
배포해야 하고, **팩토리 주소가 바뀌면 기존 볼트 주소 계산이 전부 무효**가 됩니다.

대여자는 salt에 넣지 않습니다. 담보 볼트는 자산별로 하나면 되고, 여러 대여자와의 동시
거래는 EVC 서브계정으로 가릅니다(백서 7.1절). EVC가 계정당 컨트롤러를 하나로 제한하므로
서브계정이 그 용도입니다. 서브계정은 볼트 share만 보유하고 WTGXX를 직접 만지지 않아
별도 화이트리스트가 필요 없습니다.

**대가:** `GenericFactory`의 `proxyLookup`과 `isProxy`에서 빠집니다. EVK 코드가 이를
확인하지 않아(src 전체에 사용처 없음) 담보로 인정받는 데 문제가 없지만, Euler 생태계
도구가 이 볼트를 찾지 못합니다.

`implementation`을 immutable로 둔 것은 EVK 기본보다 엄격합니다. `GenericFactory`는
관리자가 `setImplementation`으로 모든 볼트를 한 번에 바꿀 수 있는데, 백서 2.2절의 불변
볼트 요구와 충돌합니다.

### 훅이 막는 것

담보 볼트가 EVK인 이유는 부채 볼트와 붙기 위해서이고, 그 대가로 ERC-4626이 딸려옵니다.
그대로 두면 두 조항이 깨집니다.

```
share 전송   차입자가 비인가 주소에 넘기면 경제적 소유가 명부 밖으로 나감
             토큰은 볼트에 있어 화이트리스트도 게이트도 감지 못함 (백서 2.1절)
타인 예치     볼트가 투자자 한 명 전용이 아니게 됨 (백서 2.2절)
```

**출금은 막지 않습니다.** 백서 6.1절이 출구 무검사를 요구합니다. 부채가 남아 있으면 EVC의
계정 상태 검사가 막으며, 훅이 판단할 일이 아닙니다.

예치 허용은 `evc.haveCommonOwner`로 판별합니다. `receiver == borrower`로 쓰면 서브계정이
막혀 다중 대여자 거래가 불가능해집니다.

### 두 볼트를 다르게 만듭니다

```
담보 볼트   CollateralVaultFactory (CREATE2)   명부 등록 대상. 주소 예측 필수
부채 볼트   GenericFactory (EVK 표준)          명부도 KYC NFT도 없음
```

부채 볼트는 대여자가 주소를 사전 검증할 이유가 없어 표준 팩토리를 그대로 씁니다.
백서 2.2절이 담보 볼트에만 적용됩니다.

### 금리

`FixedRateIRM`이 이용률과 무관하게 고정 금리를 반환합니다. EVK 기본은 이용률 기반인데
백서 3.3절이 그 방식을 거부합니다 — 기관은 자금 조달 비용을 미리 알아야 합니다. 대여자가
한 명이면 이용률이 100%에 붙어 금리가 의미 없이 튀는 문제도 있습니다.

**EVK는 초당 수익률을 복리로 누적합니다.** 설정하는 연 50%는 명목값이고 실효 수익률은
더 높습니다. 7일 기준 원금의 0.963%가 붙고 단리 계산은 0.958%입니다. 상환액 검증 시
이 차이를 감안하세요.

**PoC 한정 타협:** 거버너가 금리를 바꿀 수 있습니다. 백서 3.1절은 마켓 파라미터 불변을
요구하므로, 프로덕션에서는 immutable로 고정하거나 만기별 볼트를 따로 배포해야 합니다.

### 부실채권 사회화

`setConfigFlags(CFG_DONT_SOCIALIZE_DEBT)`로 끕니다. EVK 기본은 켜져 있어 청산 후 남은
부채를 전체 예금자에게 분산하는데, 백서 4.5절이 이를 명시적으로 거부합니다 — 손실은 그
차입자와 직접 계약한 대여자에게 귀속됩니다.

### 개시 경로를 하나로 좁힌 이유

M4까지는 게이트가 장식이었습니다. 차입자가 부채 볼트의 `borrow`를 직접 부르면 화이트리스트
확인을 건너뛸 수 있고, 만기 레지스트리에 아무것도 남지 않아 백서 4.4절의 청산 사유가
사라집니다. 컨트랙트는 검증했는데 시나리오에 엮이지 않은 상태였습니다.

`RepoOpener`가 개시의 유일한 경로입니다. 게이트 통과(차입자와 대여자 양쪽)와 만기 기록이
차입과 한 트랜잭션에 묶입니다. 개시가 실패하면 만기 기록도 함께 되돌아갑니다.

**차입자 계정의 EVC operator로 등록되어야 합니다.** operator 권한은 동작별로 쪼갤 수 없고
계정 전체에 걸립니다(백서 7.1절). 방어는 컨트랙트를 좁게 유지하는 것뿐이며, 백서 4.1절이
RehypoManager에 요구한 것과 같습니다.

```
불변 배포. 업그레이드 경로 없음
노출 함수는 open 하나
호출 대상을 생성자에서 고정. 인자로 받은 임의 주소를 호출하지 않음
담보 볼트의 asset 을 확인해 임의 볼트 주입을 차단
```

**종료는 이 컨트랙트를 거치지 않습니다.** 백서 6.1절 출구 무검사입니다. 차입자는 부채
볼트와 담보 볼트를 직접 호출해 상환하고 인출합니다. 개시 컨트랙트에 버그가 있어도 담보가
갇히지 않고, operator 권한은 차입자가 언제든 취소할 수 있습니다.
`test_exitWorksEvenAfterLosingEligibility`가 화이트리스트에서 빠진 뒤에도 출구가 열려
있음을 확인합니다.

**순환 의존이 하나 있습니다.** 개시 컨트랙트는 생성자에서 레지스트리 주소를 받고,
레지스트리는 개시 컨트랙트를 registrar로 알아야 합니다. 레지스트리 쪽 registrar를 나중에
설정할 수 있게 두었습니다. 기록만 하는 컨트랙트라 registrar가 바뀌어도 자금이 걸리지
않지만, 감시 항목입니다.

### 검증된 시나리오

```
개시    게이트 통과 · 만기 기록 · 담보 예치 · 차입이 한 트랜잭션
        operator 없이 불가
        차입자 또는 대여자가 화이트리스트 밖이면 거부
        컴플라이언스가 제거되면 토큰은 통과시켜도 게이트가 거부
        실패 시 만기 기록도 롤백

잠김    부채가 있는 동안 담보 인출 불가 (부분·전액 모두)
        operator를 취소해도 담보는 잠긴 채

종료    상환 → 컨트롤러 해제 → 인출. 같은 호출이 부채 유무로 갈림
        화이트리스트에서 빠진 뒤에도 출구가 열림
        대여자가 원금과 이자 회수
```

## 다음 단계

M6는 S6 디폴트 청산입니다. EVK의 `liquidate`는 건전성이 깨져야 통과하는데 WTGXX는 $1
고정이라 만기가 지나도 깨지지 않습니다. 거버넌스가 `setLTV`를 낮춰 발동시키고, 만기
레지스트리의 기록이 "왜 낮췄는가"의 온체인 근거가 됩니다. 청산 후 담보 share를 받는 것과
실제 WTGXX를 손에 넣는 것이 다른 단계라는 점도 확인해야 합니다.
