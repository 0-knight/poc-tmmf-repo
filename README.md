# Radius PoC — M1 ~ M7

WTGXX를 담보로 USDC를 대여하는 고정 만기 레포의 개념 검증.

- **M1** 의존성이 없는 독립 컨트랙트 넷과 목업 스택
- **M2** KYC NFT를 받을 수 있는 담보 볼트
- **M3** 주소를 사전에 알 수 있는 볼트 팩토리와 훅
- **M4** 고정 금리 IRM과 스택 전체 배포 스크립트
- **M5** 게이트와 만기를 강제하는 개시 경로. 정상 종료 시나리오
- **M6** 디폴트 청산과 인출 사전검사
- **M7** 만기 후 이자 누적 측정

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

### 사다리 세 칸을 올리려면

`run()` 은 기반 스택과 부채 볼트 **하나**까지입니다. 사다리의 둘째·셋째 칸은 `runChain()` 이
올립니다. 배포가 끝나면 주소를 `broadcast/chain-state.json` 에 적어 다음 단계 스크립트가
읽어갑니다.

```bash
SCALE_UNIT=20 \
BORROWER_ADDRESS=0x346F46403f0E2Cb7461b2C0fBc23921b99789Db7 \
WTGXX_ADDRESS=0x0b2517eef907389F36fd87Add36E9118d364BD67 \
USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 \
MARKET_TERM=1800 MATURITY_NOTICE_WINDOW=300 MATURITY_RAMP_DURATION=300 \
forge script script/DeployStack.s.sol:DeployStack --sig "runChain()" \
  --rpc-url $SEPOLIA_RPC_URL \
  --account radius-deployer --sender 0x8CBF705774619d30965bE88648c6C5a68A48DE1e
```

**`--sender` 를 반드시 같이 주세요.** keystore로 배포하면 `PRIVATE_KEY` 가 없고, 그러면
스크립트는 `msg.sender` 를 배포자로 씁니다. `--account` 는 트랜잭션에 **서명할 지갑**만 정하고
스크립트 안의 `msg.sender` 는 바꾸지 않습니다. 빠뜨리면 Foundry 기본 발신자
`0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38` 가 모든 볼트의 거버너와 레지스트리 소유자가 됩니다.
아무도 그 키를 모르므로 되돌릴 수 없습니다.

위 명령에는 `--broadcast` 가 없습니다. 먼저 이대로 돌려 로그 첫 줄을 봅니다.

```
deployer                0x8CBF705774619d30965bE88648c6C5a68A48DE1e
```

이 주소가 맞게 찍히고 맨 아래 `Estimated amount required` 가 잔고 안에 들어올 때만 `--broadcast`
를 붙입니다.

### 사다리를 눌러 보여주려면

`script/Chain.s.sol` 이 단계마다 하나씩 있습니다. **단계마다 보내는 사람이 다릅니다** —
forge script 는 한 번에 한 발신자만 쓰므로 `--sender` 와 `--account` 를 바꿔 가며 부릅니다.
스크립트 안에 개인키는 없습니다.

참여자 주소를 먼저 세웁니다. 주소는 `broadcast/chain-state.json` 에서 읽으므로 안 넘겨도 됩니다.

```bash
export ADDR_A=0x346F46403f0E2Cb7461b2C0fBc23921b99789Db7
export ADDR_B=0x8CBF705774619d30965bE88648c6C5a68A48DE1e
export ADDR_C=0x861d0C765424B685254b5247c4d851478A9Be9FC
export ADDR_D=0x209ae17D61c299F91e8BE5365280dF0a9095fD19
export ADDR_L=0xc20aa1645047D128B899D724abC7303eC558BDCc

run() { forge script script/Chain.s.sol:RepoChain --sig "$1" \
  --rpc-url $RPC --account "$2" --sender "$3" --broadcast; }
```

**금액은 `SCALE_UNIT` 을 다시 세울 필요가 없습니다.** `runChain()` 이 배포할 때 쓴 값을
`chain-state.json` 에 적어 두고 단계 스크립트가 거기서 읽습니다.

이게 중요한 이유가 있습니다. 예전에는 단계마다 환경 변수를 다시 읽었고, 비어 있으면 기본값
100으로 **조용히** 돌아갔습니다. 10/04 리허설에서 여섯 단계가 그래서 죽었습니다
(`ERC20: transfer amount exceeds balance`). 지금은 상태 파일에 값이 없는 옛 배포만 환경
변수로 넘어가고, 그마저 비어 있으면 기본값으로 가지 않고 **멈춥니다.**

`MARKET_TERM` 만 `rollMaturity()` 에서 여전히 환경 변수입니다. 배포 때 쓴 기간이 아니라
지금 굴릴 기간이라 상태 파일에서 읽으면 안 됩니다. 안 세우면 역시 멈춥니다.

**넷 다 게이트를 통과해야 합니다.** `RepoOpener.open` 이 개시 때 차입자와 대여자 양쪽에
`canEnter` 를 겁니다. C·D 는 WTGXX 에 닿지 않지만 오프너가 참여자 자격으로 검사합니다.

```bash
forge script script/Chain.s.sol:RepoChain --sig "checkParties()" --rpc-url $RPC
```

여섯 줄이 전부 `0` 이어야 시작할 수 있습니다.

순서는 **위 칸부터**입니다. 꼭대기가 현금을 대야 아래 칸이 빌릴 수 있습니다.

```bash
run "rollMaturity()" radius-deployer $ADDR_B   # 시연 직전에. 사다리를 세우기 전에

run "supplyD()"  radius-d        $ADDR_D
run "supplyC()"  radius-c        $ADDR_C
run "openC()"    radius-c        $ADDR_C       # C 가 eV_C 를 걸고 D 에게서 빌린다
run "supplyB()"  radius-deployer $ADDR_B
run "openB()"    radius-deployer $ADDR_B       # B 가 eV_B 를 걸고 C 에게서 빌린다
run "openA()"    radius-borrower $ADDR_A       # A 가 WTGXX 를 걸고 B 에게서 빌린다
```

사다리가 섰습니다. 여기서 한 화면을 보여줍니다.

```bash
forge script script/Chain.s.sol:RepoChain --sig "status()" --rpc-url $RPC
```

`WTGXX in V_A` 만 값이 있고 나머지 셋이 0인 것이 첫 번째 요점입니다 — **담보는 맨 아래 칸을
떠나지 않습니다.**

만기가 지나면 통지와 청산입니다.

```bash
run "notice()"         radius-deployer $ADDR_B   # 창 안에는 상대방인 B 만
run "liquidate()"      radius-liquidator $ADDR_L
run "withdrawSeized()" radius-liquidator $ADDR_L # 담보가 여기서 처음 볼트를 떠난다
```

청산 뒤 `status()` 를 다시 찍는 것이 두 번째 요점입니다. `V_B totalAssets` 는 안 움직이고
`B would redeem` 에서만 손실이 보입니다 — **부족분은 가격으로 번지지 않습니다.**

L 은 부채를 떠안고 곧바로 갚으므로 **USDC 를 들고 있어야 합니다.** 차입액만큼 미리
보내 두세요.

## 구성

```
src/
  interfaces/
    IWTGXX.sol                 Radius가 호출하는 함수만. 시그니처는 검증 소스에서 확인
    IEulerPriceOracle.sol      EVK 부채 볼트가 담보 환산에 쓰는 인터페이스
  oracle/
    FixedOneToOneOracle.sol    1대1 고정 + decimals 보정 (18 <-> 6)
  registry/
    MaturityRegistry.sol       시장 만기 공표 + 계정 만기·상대방 기록
                               registrar 집합 — 사다리 칸마다 개시 컨트랙트 하나
    ParticipantRegistry.sol    자격 판정의 단일 출처. 게이트 + 대비 승인 목록
  gate/
    WTGXXGate.sol              백서 6장 진입 게이트
  irm/
    FixedRateIRM.sol           이용률 무관 고정 금리
  repo/
    RepoOpener.sol             개시의 유일한 경로. 게이트·시장 만기 강제
    MaturityController.sol     만기 경과를 청산 가능 상태로. 부채 볼트의 거버너
                               closeMarket(누구나) / triggerMaturity(창 안에는 상대방만)
    LiquidationPrecheck.sol    인출 가능 여부 사전 확인
  vault/
    WTGXXCollateralVault.sol   EVault + onERC721Received
    DebtVaultAccessHook.sol    부채 볼트 입구. 자격 + 만기 기록 강제
    CollateralVaultFactory.sol CREATE2 배포. implementation immutable
    CollateralVaultHook.sol    share 전송 차단, 예치를 소유자로 제한
  mocks/
    MockERC20.sol              최소 ERC-20 베이스
    MockUSDC.sol               decimals 6
    MockWTGXX.sol              검증된 가드 배치 재현
    MockKycNFT.sol             소울바운드, safeMint
    MockComplianceOracle.sol   to만 판정, 비활성 시 false
    MockVariableOracle.sol     같은 쌍, 가격을 움직일 수 있음. 부족분 경로 시험용
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

레지스트리는 그 사유를 기록만 하고, 강제는 `MaturityController`가 합니다. 레지스트리의
기록은 "왜 청산됐는가"의 온체인 증거로 남습니다.

### 재담보를 올리는 데 새 컨트랙트가 필요 없는 이유

대여자의 채권이 이미 ERC-4626 지분입니다. B가 V_B에 USDC를 넣으면 eV_B를 받고, 그것을
그대로 V_C의 담보로 걸면 재담보입니다. 매니저 원장도, 포장 토큰도, 새 컨트랙트도
없습니다. `DeployStack.deployRung` 이 하는 일은 부채 볼트를 하나 더 만들고 아래 칸의
볼트를 담보로 등록하는 것뿐입니다.

가격도 한 줄입니다.

```
EulerRouter.govSetResolvedVault(V_B, true)
```

라우터가 `convertToAssets` 로 지분을 자산으로 풀고, 그 자산이 unitOfAccount와 같으면
그대로 통과시킵니다(`getQuote`: `if (base == quote) return inAmount`). 어댑터를 새로
쓸 일이 없습니다.

```
V_B   A가 WTGXX 100을 맡기고 USDC 80을 빌린다. B가 100을 댄다.  LTV 92/95, 연 50%
V_C   B가 eV_B 100을 담보로 걸고 USDC 80을 빌린다. C가 100을 댄다. LTV 85/90, 연 40%
V_D   C가 eV_C 100을 담보로 걸고 USDC 70을 빌린다. D가 100을 댄다. LTV 78/85, 연 30%
```

**중간 둘의 순투입은 20과 30입니다.** 체인이 A에게 보낸 돈은 80인데 그것을 받치는
순자본의 합은 150입니다. 중간에 선 참여자는 자기 돈을 거의 내지 않으면서 양쪽에 서
있습니다 — 전통 repo의 매치북입니다.

**WTGXX는 맨 아래 칸을 벗어나지 않습니다.** B와 C는 WTGXX를 쥔 적이 없습니다. V_C가
압류하는 것은 eV_B — V_B에 대한 청구권 — 이고, 이전 대리인 명부는 A와 V_A 사이에서
끝납니다. 백서 2.1절이 거부한 "자유롭게 유통되는 래퍼 토큰"이 생기지 않습니다.

### 중간이 무너져도 체인이 끊어지지 않는 이유 — 승계(step-in)

B가 C에게 갚지 못하면 C가 B를 청산하고 eV_B를 압류합니다. 그 지분을 받는 순간
**C가 V_B의 대여자가 됩니다.** A와의 계약은 그대로 살아 있고, A가 갚으면 그 현금이
이제 C에게 갑니다.

재연결 코드가 없습니다. 청산 한 번이 전부입니다. 지분의 주인이 바뀌면 대여자가
바뀌기 때문입니다.

백서 5.3절의 네팅(채무 고리의 현금 없는 상계)과는 다른 것입니다. 고리를 상계한 것이
아니라 대여자의 자리가 통째로 넘어간 것이고, 전통금융 용어로는 step-in 입니다.

한 가지 어긋남이 남습니다 — **레지스트리의 상대방 기록은 승계를 모릅니다.** A의
`counterpartyOf` 는 여전히 B이므로, 통지 창 안에서는 B만 A의 부도를 선언할 수 있습니다.
창이 지나면 C도 할 수 있어 포지션이 묶이지는 않지만, 승계를 기록에 반영하는 것은
남은 일입니다. `StepIn.t.sol` 의 `test_bottomRungMaturityStillWorksAfterStepIn` 이
이 성질을 고정해 둡니다.

### 사다리가 서려면 금리에 폭이 있어야 하는 이유

칸을 셋으로 늘리자 처음 드러났습니다. 모든 칸이 같은 금리 모델을 쓰면 **중간 참여자는
구조적으로 적자입니다.**

EVK는 볼트마다 이자의 10%를 수수료로 뗍니다(`Initialize.DEFAULT_INTEREST_FEE`). 받는
쪽에서 10%가 깎여 나가고 내는 쪽은 전액입니다. 같은 금리, 같은 원금이면 그 차이만큼
모자라고, 칸이 늘수록 쌓입니다.

그래서 `deployRung` 이 칸마다 금리를 받습니다. 아래에서 받는 금리가 위에 내는 금리보다
높아야 합니다. 50% → 40% → 30% 로 두었고, 7일 만기 한 바퀴를 돌리면 셋 다 흑자로
끝납니다(`ChainCycle.t.sol` 의 `test_everyRungKeepsASpread`).

스프레드 10%p는 수수료 10%를 덮고 남을 폭으로 고른 숫자입니다. 실물에서는 시장이
정하며, 그때 확인해야 하는 하한은 "수수료를 덮는가"입니다.

### 중간 참여자가 자기 계정으로 청산할 수 없는 이유

EVC는 계정당 컨트롤러를 하나만 허용합니다. 그리고 EVK의 청산은 컨트롤러 중립 연산이
아닙니다 — `CONTROLLER_NEUTRAL_OPS` 에 `OP_LIQUIDATE` 가 없으므로 청산인은 그 볼트를
자기 컨트롤러로 등록해야 합니다.

B는 이미 V_C의 차입자이고, 그래서 V_C가 B의 컨트롤러입니다. **B가 V_B를 두 번째
컨트롤러로 등록하면 `EVC_ControllerViolation` 입니다.** 즉 B는 자기 차입자 A를 자기
계정으로 청산할 수 없습니다. 사다리 중간에 선 참여자 전부에게 걸립니다.

칸이 둘일 때는 안 보였습니다. Wave 3에서 청산한 쪽은 꼭대기의 C였고 C는 차입자가
아니었습니다.

풀이는 EVC 서브계정입니다. 서브계정에는 개인키가 없으므로 둘을 소유자 계정으로
돌립니다 — 배치를 보내는 것과 상환 대금을 내는 것입니다. `repay(amount, receiver)` 의
지불자는 인증된 계정이고 수령자는 부채가 줄어드는 계정이라 그렇게 나눌 수 있습니다.

그 서브계정이 통지도 보냅니다. `MaturityController._mayServeNotice` 가
`haveCommonOwner` 를 받아들이기 때문입니다 — Wave 2.5에 넣어 둔 것이 여기서 값을
했습니다. 두 계정을 번갈아 쓸 필요가 없습니다.

운영에 붙는 조건입니다. 중간 참여자의 청산 러너는 **본계정이 아니라 서브계정으로**
돌아야 합니다.

### 부족분이 지분 가격으로 번지지 않는 이유

설계 문서의 전파 임계표는 "손실이 지분 가격을 떨어뜨리고, 떨어진 가격이 위 칸의
건전성을 깬다"는 전제로 만들어졌습니다. **그 전제가 성립하지 않습니다.**

EVK는 청산 후 담보가 바닥난 차입자의 남은 부채를 전체 예금자에게 분산합니다(debt
socialization). 그때 `totalBorrows` 가 줄고 `totalAssets` 도 줄어 지분 가격이
떨어집니다. 백서 4.5절이 그 분산을 거부하므로 우리는 `CFG_DONT_SOCIALIZE_DEBT` 를
켰고, 그래서 남은 부채가 차입자 계정에 그대로 남습니다. `totalBorrows` 가 줄지 않으니
`totalAssets` 도 그대로입니다.

```
가격 전파   일어나지 않는다. eV_B 는 부족분이 생겨도 같은 값을 유지한다
실제 전파   대여자가 환매하려 할 때 현금이 모자란 것으로 나타난다
```

WTGXX를 0.70으로 내려 A에게 부족분을 만들어 확인했습니다. V_B의 총자산이 1 wei도
움직이지 않고, 위 칸 둘은 숫자로는 멀쩡합니다. 손실은 B가 환매할 때 장부상 청구권과
볼트 현금의 격차로 드러나며, 그 격차가 정확히 A의 부실채권입니다
(`ChainDefault.t.sol`).

임계표가 틀린 것은 숫자가 아니라 **종류**입니다.

그리고 조건이 하나 붙습니다. 손실이 B에게 떨어지는 것은 B가 "직접 계약한 대여자"라서가
아니라 **B가 그 시장의 유일한 대여자**이기 때문입니다. 가격이 안 움직이므로 부족분은
마지막에 환매하는 사람이 먹습니다. 시장 하나에 대여자 하나인 설계에서는 그 둘이 같고,
여러 명이 섞이면 같지 않습니다. 백서 4.5절의 손실 귀속을 코드로 성립시키려면 한
시장의 대여자를 하나로 유지해야 합니다.

### 만기가 지나도 자동으로 청산되지 않는 이유

전통 repo는 만기 미지급을 자동 부도로 두지 않습니다. GMRA 2011 ¶10(a)(i)은 Repurchase
Price 미지급을 Event of Default로 적지만, 비부도 당사자가 **Default Notice**를 보내야
성립합니다. ¶10(b)는 그 통지까지 최대 20일을 줍니다. 대여자가 통지하지 않기로 선택하는
것 — forbearance — 이 차입자의 만회 기회입니다. 제3자가 끼어들어 부도를 선언하는 조항은
없습니다.

그래서 만기 후 길이 둘입니다. **갚는 길에는 관문이 없고, 가져가는 길에는 둘이 있습니다.**

```
                      관문 없음 ─────────────→  상환 완료
                    ↗
만기 경과 ─────────
                    ↘
                      〈통지〉 ──→ 〈사다리〉 ──→  청산
```

갚는 길은 직선입니다. 만기 전이든 후든, 통지가 왔든 안 왔든, 돈만 구하면 끝납니다.
가져가는 길의 **첫 관문은 사람이** 엽니다 — 창 안에서는 그 계약의 상대방만. **둘째
관문은 시간이** 엽니다 — 사다리가 담보 여유를 다 먹을 때까지. 두 관문 사이의 시간이
cure period이고, 그동안 담보는 차입자에게 남아 있습니다.

운영자가 쥔 열쇠는 없습니다.

### 함수를 둘로 쪼갠 이유

```
closeMarket()                  누구나, 만기 즉시
                               부채 정지 + 신규 진입 차단
                               -> cure 가 시작된다. 갚을 금액이 고정된다

triggerMaturity(담보, 차입자)    통지 창 안에는 상대방만, 그 뒤 누구나
                               -> 부도 선언. 사다리 시작
```

부채를 멈추는 것은 **차입자에게 유리한** 조치라 아무나 불러도 됩니다. 차입자 본인이
부르는 것이 정상입니다. 부도를 선언하는 것은 **대여자의 권리**입니다. 한 함수였다면
"부채 정지"를 받으려면 "부도 선언"을 같이 받아야 했습니다.

**상대방은 개시 때 온체인에 적힙니다.** `RepoOpener.open`이 `lender`를 받으면서 이벤트로만
흘려보내고 있었습니다. `MaturityRegistry.counterpartyOf`가 그 자리입니다 — 백서 4.5절의
"손실은 그 차입자와 직접 계약한 대여자에게 귀속"이 가리키는 주소이고, 통지 권한 판정도
여기서 읽습니다. 기록이 0이면 창을 적용하지 않습니다. 누구를 기다려야 할지 모르는 계약이
영원히 안 풀리는 것보다 낫습니다.

**대리인은 EVC operator로 풀었습니다.** 새 레지스트리 없이 대여자 본인이
`evc.setAccountOperator(대여자, 에이전트, true)`로 위임하며, 서브계정도 함께 통과합니다.
권한은 끝까지 대여자가 쥡니다.

**창이 지나면 누구나 선언합니다.** 전통금융에 없는 백스톱이고, 필요한 이유는 둘입니다.
풀 볼트라 다른 대여자들 현금이 같이 묶이고, 대여자가 사라지면 포지션이 영원히 안 풀립니다.
전통금융은 법인과 법원이 뒤를 받치지만 프로토콜은 그렇지 않습니다.

**일부러 넣지 않은 것 둘.** 청산 자체는 통지자에게 묶지 않았습니다 — 사다리 때문에
선착순 상금이 없어(먼저 오는 자의 할인이 0) 경쟁이 생길 이유가 없습니다. 롤(roll)은
범위 밖입니다 — 백서 3.1대로면 롤은 "시장 #1을 갚고 시장 #2에서 빌리기"이고, 시장이
둘 있어야 성립합니다.

### 만기를 EVK 동작으로 옮긴 방법

M6까지는 거버너가 손으로 `setLTV(담보, 0.7, 0.7, 0)`을 불러 청산을 열었습니다. 그래서
성립하는 문장이 "만기가 지나면 청산된다"가 아니라 **"거버너가 마음먹으면 청산된다"**
였습니다. `MaturityController`가 그 자리를 대신합니다. 이 컨트랙트가 부채 볼트의
거버너이고, 만기 후에만, 누구나, 되돌릴 수 없게 발동합니다.

`triggerMaturity(담보)` 가 하는 일 넷.

```
1  setLTV(담보, 0, 개시LTV, 0)       청산선을 개시 한도까지 즉시
2  setLTV(담보, 0, 0, 1일)           거기서 0까지 선형으로
3  setInterestRateModel(0 반환 모델)  부채 정지. 연체 이자 없음
4  setHookConfig(0, 입금|발행|차입)   신규 진입 차단. 출구는 열린 채
```

**사다리의 출발점이 상수가 아닙니다.** 볼트에서 `LTVBorrow`를 읽습니다. 그래서 한도를
꽉 쓴 차입자는 종이 울리는 순간 조정담보와 부채가 같아져 **할인 0으로 청산 대상**이
되고, 여유를 남긴 차입자는 그 여유가 먼저 소진됩니다. 사다리에는 두 개의 시계가 있습니다.

```
청산이 열리는 시점      (1 - 부채/담보 ÷ 개시LTV) x 사다리
할인이 상한에 닿는 시점  그로부터 약 maxDiscount ÷ 개시LTV x 사다리
```

담보 100에 부채 80.8이면 첫 번째가 사다리의 약 12%(하루 중 2.9시간), 두 번째가 거기서
2% 남짓입니다. 사다리 범위의 대부분은 할인에 영향이 없습니다 — 할인은 2%에서 잘립니다.
그래도 0까지 내려야 합니다. 여유를 많이 남긴 차입자는 청산선이 그 비율 아래로 내려가야
비로소 잡히기 때문입니다. 실측값은 `MaturityController.t.sol`의 로그에 남습니다.

**`setInterestRateModel(address(0))`은 답이 아닙니다.** EVK의 `computeInterestRate`는
모델이 0 주소면 호출을 건너뛰고 `vaultStorage.interestRate`를 그대로 둡니다. 직전 금리가
박제되어 부채가 계속 자랍니다. 0을 반환하는 모델을 실제로 끼워야 합니다.

**`setHookConfig(address(0), ops)`는 그 연산을 비활성화합니다.** 훅 컨트랙트가 필요
없습니다 — `Base.invokeHookTarget`이 대상이 0 주소면 `E_OperationDisabled`로 되돌립니다.
막는 것은 입금·발행·차입뿐이고 상환·청산·인출·환매는 건드리지 않습니다. 백서 6.1절.

**되돌릴 경로를 두지 않았습니다.** 관리자 통로는 온보딩용 `configureCollateral` 하나이고
시장이 닫히거나 사다리가 시작된 뒤에는 막힙니다. `setGovernorAdmin`을 노출하지 않았으므로
관리자가 LTV를 다시 올려 청산을 취소할 수 없습니다.

대가가 둘입니다. 컨트랙트에 버그가 있으면 복구 경로가 없고, **한 번 닫힌 시장은 다시
열리지 않습니다.** 레지스트리의 `setMarketMaturity`는 다음 기간으로 굴러가지만 컨트롤러의
`marketClosedAt`을 되돌리는 경로가 없고, 거버넌스를 넘기는 함수도 없어 컨트롤러를 교체할
수도 없습니다. **이 PoC의 시장은 단일 기간입니다** — 다음 기간은 시장을 새로 배포해야
합니다. 7일 repo 한 번을 보이는 데모에는 문제가 없지만, 같은 볼트로 기간을 굴려야 하면
타임락을 거버너로 두고 컨트롤러를 교체 가능하게 바꿔야 합니다.
`test_closedMarketCannotReopenEvenAfterRoll`이 이 성질을 고정해 둡니다.

### 만기가 시장의 속성인 이유

전까지 차입자가 `open`의 인자로 아무 날짜나 넣을 수 있었습니다. 같은 부채 볼트를 쓰는
참여자들이 서로 다른 만기를 갖게 되니 백서 3.1절이 말하는 "시장 하나에 만기 하나"가
성립하지 않았고, 만기에 LTV를 내릴 컨트랙트가 어느 날짜를 봐야 할지 정할 수 없었습니다.

이제 레지스트리가 시장별 만기(`marketMaturity`)를 들고 있고, `RepoOpener`가 차입자가
제시한 날짜와 일치하는지 봅니다. 인자를 없애지 않은 이유는 하나입니다 — 차입자가 서명하는
트랜잭션에 자기가 동의한 날짜가 찍혀야 합니다. 레지스트리에서 꺼내 쓰면 거버넌스가 만기를
굴린 직후 들어온 트랜잭션이 본인이 모르는 날짜로 체결됩니다.

만기가 지나면 그 시장에서 새 개시가 멈춥니다. 거버넌스가 `setMarketMaturity`로 다음 기간
으로 굴려야 다시 열리며, 굴려도 이미 열린 계약의 계정별 만기는 그대로 남습니다.

### 손실이 확정되기 전에 경계를 확인하는 이유

M6에서 찾은 사실이 출발점입니다. **청산 성공이 담보 확보가 아닙니다.** EVK 압류는
`evc.controlCollateral(담보, 차입자, 0, transfer(수령자, 수량))` 으로 볼트 share만 옮기고
WTGXX를 만지지 않습니다. 그래서 이슈어의 화이트리스트가 발동하지 않고, 자격 없는 청산인이
share를 받은 뒤 **그다음 `withdraw` 에서 처음** 막힙니다. 그때는 이미 차입자의 부채를
인수해 버린 뒤입니다. 순서가 거꾸로였습니다.

Wave 2는 세 곳을 좁힙니다.

```
압류 수령자   CollateralVaultHook 이 transfer 의 첫 인자를 읽어 자격을 확인.
              없으면 청산 트랜잭션 전체가 되돌아가고 청산인은 부채를 떠안지 않음

부채 볼트     DebtVaultAccessHook 이 입금·발행·스킴·차입을 거름.
입구          입금 계열은 호출자와 수령자 둘 다. 차입은 만기 기록까지

압류 셀렉터   transferFrom 과 transferFromMax 는 압류 문맥에서도 차단.
              EVK 는 transfer 하나만 씀(EVCClient.sol:102)
```

**차입에 만기 기록을 요구하는 이유.** 자격만 보면 구멍이 남습니다. 자격 있는 차입자가
`borrow` 를 직접 불러 `RepoOpener` 를 건너뛰면 만기 레지스트리에 아무것도 남지 않고,
`MaturityController` 가 발동할 근거가 사라집니다. Wave 1까지 `test_openAndRepay` 가
실제로 그 경로로 돌고 있었습니다. 이제 차입 시점에 그 계정의 기록이 시장 만기와 같은지
봅니다 — `RepoOpener.open` 이 같은 트랜잭션에서 차입보다 먼저 기록하므로 정상 경로는
그대로 통과합니다.

### 승인 목록을 둔 이유, 그리고 그것이 할 수 없는 일

게이트는 이슈어의 실시간 판정입니다. WTGXX의 컴플라이언스 컨트랙트가 제거되거나 오라클이
꺼지면 `canEnter` 는 모두에게 false 를 돌려주고, 그러면 **진행 중인 청산이 영구히 막힙니다.**
백서 6.2절이 적은 상황입니다. `ParticipantRegistry` 는 게이트와 운영 승인 목록의 OR 이며,
승인 목록이 그 출구입니다.

승인이 열어 주는 것은 **볼트 share 수령**뿐입니다. 실제 WTGXX는 그다음 `withdraw` 에서
나가고 거기서 이슈어의 화이트리스트를 그대로 탑니다. 즉 이 목록은 "청구권을 들고 기다릴
수 있는 자"를 정하고, "토큰을 받을 수 있는 자"는 여전히 WisdomTree가 정합니다.
`isEligibleOnlyByApproval` 이 승인 경로로만 통과한 주소를 표시합니다 — 운영에서 감시할
신호입니다.

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

### 리시버 훅 하나가 Layer 1을 가른다 — Sepolia 실측

10/03 샌드박스에서 확인했습니다. **컨트랙트 주소도 화이트리스트에 오릅니다.**

`checkEntry` 열은 우리가 올린 `WTGXXGate`(`0x3081cdE0...`)를 읽은 값입니다. 게이트는 실물
WTGXX를 staticcall로 네 번 불러 사유 코드 하나로 모을 뿐이고, 판정 자체는 WisdomTree
컴플라이언스 오라클이 내립니다. "Sepolia 참조 주소" 절을 참조하세요.

```
주소                  리시버 훅   balanceOf   checkEntry
PROBE  (컨트랙트)      있음         1          0  Allowed
BADGATE(컨트랙트)      없음         0          5  NotWhitelisted
차주 EOA              —            1          0  Allowed
```

같은 조직, 같은 등록 경로, 같은 승인 방식입니다. 차이는 `onERC721Received` 하나뿐이고,
그 하나로 결과가 갈립니다. 막는 것은 "컨트랙트라서"가 아니라 **"ERC-721을 못 받아서"**
입니다. `safeMint`가 수신자 훅을 부르고 매직값이 안 오면 revert하기 때문입니다.

**리드타임은 승인 후 약 1분입니다.** 며칠이 아닙니다.

**민팅 실패는 조용합니다.** 훅이 없으면 발행이 revert하는데, 밖에서 보면 게이트가 계속
`NotWhitelisted`인 것과 구분이 안 갑니다. 실제로 몇 시간을 "승인 지연"으로 오진한 적이
있습니다. 그래서 **등록 파이프라인은 승인 확인만으로 끝내면 안 됩니다** — 온체인에서
`kycNFT.balanceOf`와 게이트 판정을 둘 다 찍어야 둘을 구분합니다.

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

WisdomTree가 올린 것:

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

우리가 올린 것:

```
WTGXXGate  0x3081cdE0A81B37440EB1Df83a42414b8Ed2F975e
배포자     0x8CBF705774619d30965bE88648c6C5a68A48DE1e
```

**이 게이트는 WisdomTree 것이 아닙니다.** `src/gate/WTGXXGate.sol`을 위 WTGXX 프록시를
가리키게 올린 우리 배포입니다. 생성자가 `token` 하나만 받고 immutable로 박으므로 거버넌스도
스위치도 없고, 모든 경로가 staticcall view입니다. 상태를 바꾸지 않습니다.

그래서 앞 절 실측 표의 `checkEntry` 판정은 **우리 규칙이 아니라 WisdomTree 상태를 읽어 온
값**입니다. 게이트가 하는 일은 네 호출(`getCompliance`, `isPaused`, `isFrozen`,
`isAddressWhitelisted`)을 한 사유 코드로 모으는 것뿐입니다. 토큰을 직접 네 번 불러도 같은
답이 나옵니다 — 게이트는 그걸 한 줄로 찍어 주는 계기판입니다.

이 주소를 외부에 인계할 때는 출처를 함께 적어야 합니다. 상대가 WisdomTree의 공식 게이트로
읽으면 안 됩니다. WisdomTree는 게이트를 따로 올리지 않았고, 컴플라이언스 판정은 토큰과
오라클에 있습니다.

## 확정된 파라미터

```
unitOfAccount   USDC
개시 LTV        92%      담보 대비 빌릴 수 있는 한도
청산 LTV        95%      이 선을 넘으면 청산 대상
만기 사다리     92% -> 0  부도 선언 후 1일에 걸쳐 선형 하강
통지 창         24시간    만기 후 이 기간에는 그 계약의 상대방만 부도를 선언
청산 할인 한도  2%       정부채 MMF 담보 기준
청산 쿨오프     0초
이율            연 50% 고정. 거버넌스가 변경 가능
차입            담보 대비 80%
만기            배포 + 7일. 시장의 속성이며 차입자가 고르지 않음
거버넌스        배포자 EOA. 존치
```

**기간 셋은 환경 변수로 바꿀 수 있습니다.** 기본값은 위 숫자 그대로입니다.

```
MARKET_TERM              만기까지 (기본 7일)
MATURITY_NOTICE_WINDOW   상대방만 선언할 수 있는 창 (기본 1일, 0이면 창 없음)
MATURITY_RAMP_DURATION   청산선이 0까지 내려가는 시간 (기본 1일)
```

기본값대로면 만기에서 청산까지 9일이 걸립니다. 로컬에서는 시간을 옮기면 되지만 Sepolia에서는
진짜로 기다려야 하므로, 한자리에서 전 과정을 보여주려면 분 단위로 줄여야 합니다. 30분 / 5분 /
5분이면 한 번에 돕니다.

숫자를 줄여도 논리는 같습니다. 사다리의 두 시계가 절대 시간이 아니라 비율로 돌기 때문입니다 —
청산이 열리는 시점은 `(1 − 부채/담보 ÷ 개시LTV) × rampDuration`, 할인이 상한에 닿는 데 걸리는
몫은 `maxDiscount ÷ 개시LTV` 입니다.

두 가지를 조심하세요. **빈 값으로 두면 안 됩니다** — `MARKET_TERM=` 처럼 비우면 숫자로 못 읽어
배포가 되돌아갑니다. 지우거나 주석으로 두어야 기본값이 쓰입니다. 그리고 **`forge test` 에는
세우지 마세요** — 테스트가 7일과 1일을 박아 두고 있어 환경 변수를 세우면 그쪽이 깨집니다.
배포와 시나리오 스크립트 전용입니다.

`forge test` 가 셸 환경을 그대로 읽어간다는 게 핵심입니다. 시연 준비 중에 `export` 해 둔 값이
테스트를 깨뜨립니다. 명령 앞에 붙이는 방식으로 쓰거나, 꼭 export 해야 하면 테스트는 이렇게
돌리세요.

```bash
env -u MARKET_TERM -u MATURITY_NOTICE_WINDOW -u MATURITY_RAMP_DURATION forge test
```

**금액도 환경 변수입니다.** 같은 이유입니다 — 샌드박스 잔고가 기본값에 못 미칩니다.

```
SCALE_UNIT               사다리 한 칸의 단위 (기본 100)
BORROWER_ADDRESS         담보를 거는 A. 안 세우면 배포자 자신
```

`SCALE_UNIT` 은 **개수**입니다. wei가 아닙니다. 20이면 담보 20 WTGXX, 칸마다 예치 20 USDC이고,
차입액은 코드에 적힌 숫자가 아니라 **비율에서 나옵니다** — A 16, B 16, C 14.

비율에서 끌어내는 이유가 중요합니다. 손으로 적으면 단위를 줄일 때 한 칸만 안 고쳐서 개시가
조용히 막힙니다. 지금은 어떤 단위에서도 각 칸의 개시 LTV 아래에 머뭅니다.
`test/unit/ScaleUnit.t.sol` 의 `test_everyRungStaysUnderItsBorrowLtv` 가 그걸 고정합니다.

기본값 100으로 사다리를 세우려면 대여자 셋이 100씩, 합쳐 300 USDC가 듭니다.

재담보 사다리의 칸별 파라미터입니다. 올라갈수록 LTV는 좁아지고 금리는 내려갑니다.

```
          담보      개시 LTV   청산 LTV   이율
V_B       eV_A       92%        95%      연 50%
V_C       eV_B       85%        90%      연 40%
V_D       eV_C       78%        85%      연 30%
```

LTV가 좁아지는 이유는 회수 시간입니다. eV_B를 현금으로 바꾸려면 V_B에서 환매해야 하고
그 환매는 A가 갚거나 청산되어야 가능합니다. 칸마다 한 단계가 더 걸립니다.

금리가 내려가는 이유는 볼트 수수료입니다. 아래 설명 참조.

**두 LTV를 벌린 이유.** 전까지 개시 한도와 청산선이 90%에 함께 붙어 있었습니다. 한도까지
빌린 계정은 이자가 1초 붙는 순간 청산 대상이었고, "빌릴 수 있는 선"과 "청산되는 선"을
구분할 수 없었습니다.

헤어컷으로 읽으면 개시 8%, 청산 5%입니다. 암호자산 관행이 아니라 전통 repo의 헤어컷에서
왔습니다 — 백서 4.2절이 "볼 것은 가격이 아니라 회수 시간"이라고 적고, WTGXX는 $1 고정에
환매가 T+1이므로 덮어야 하는 것은 가격 변동이 아니라 하루의 지연입니다.

전통금융의 정부채 MMF 헤어컷은 1~3%입니다. 우리가 더 넓게 잡은 이유는 둘입니다. 일일
마크와 마진콜이 아직 없어서 하루를 한 번에 덮어야 하고, 재담보 체인에서는 사다리 칸마다
헤어컷이 쌓여 아래 칸의 여유가 위 칸의 완충이 됩니다. 마진콜이 붙으면 이 숫자는 좁혀야
합니다.

**청산 할인을 20%에서 2%로 내린 이유.** EVK는 담보가 부채에 얼마나 모자라는지에 비례해
할인율을 계산하고(`Liquidation.calculateMaxLiquidation`), 설정값은 그 하한입니다. 정부채
MMF 담보에 20% 할인은 청산인에게 과한 보상이며, 백서 4.4절의 "할인은 0에서 시작해 선형으로
오른다"와도 어긋납니다.

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

**칸마다 자기 모델입니다.** `deployRung` 이 칸마다 `FixedRateIRM` 을 하나 더 배포합니다.
한 모델을 돌려 쓰면 중간 참여자가 볼트 수수료만큼 적자입니다 — "사다리가 서려면 금리에
폭이 있어야 하는 이유" 참조.

**볼트 수수료 10%.** EVK가 볼트마다 이자의 10%를 수수료로 떼고
(`Initialize.DEFAULT_INTEREST_FEE`), 절반은 프로토콜, 절반은 `feeReceiver` 로 갑니다.
지분으로 발행되므로 `totalAssets` 가 아니라 `totalShares` 가 늘어 대여자 몫이 희석됩니다.
사다리 수익 계산에서 칸마다 한 번씩 빠지는 몫입니다.

### 부실채권 사회화

`setConfigFlags(CFG_DONT_SOCIALIZE_DEBT)`로 끕니다. EVK 기본은 켜져 있어 청산 후 남은
부채를 전체 예금자에게 분산하는데, 백서 4.5절이 이를 명시적으로 거부합니다 — 손실은 그
차입자와 직접 계약한 대여자에게 귀속됩니다.

**이 플래그가 전파 메커니즘을 바꿉니다.** 분산을 끄면 지분 가격이 움직이지 않고, 손실은
환매 시점의 현금 부족으로만 드러납니다. 그리고 "직접 계약한 대여자"에게 귀속되는 것은
그 시장의 대여자가 한 명일 때만 성립합니다 — "부족분이 지분 가격으로 번지지 않는 이유"
참조.

### 개시 경로를 하나로 좁힌 이유

M4까지는 게이트가 장식이었습니다. 차입자가 부채 볼트의 `borrow`를 직접 부르면 화이트리스트
확인을 건너뛸 수 있고, 만기 레지스트리에 아무것도 남지 않아 백서 4.4절의 청산 사유가
사라집니다. 컨트랙트는 검증했는데 시나리오에 엮이지 않은 상태였습니다.

`RepoOpener`가 개시의 유일한 경로입니다. 게이트 통과(차입자와 대여자 양쪽), 시장 만기와의
일치, 만기 기록이 차입과 한 트랜잭션에 묶입니다. 개시가 실패하면 만기 기록도 함께
되돌아갑니다.

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

사다리  세 칸이 서고 만기 하나를 공유. 순자본 20·30·100이 80을 받침
        칸마다 자기 금리·자기 만기 컨트랙트·자기 개시 컨트랙트
        담보로 잡힌 지분은 위 칸에 갚기 전까지 꼼짝 안 함
        풀려도 볼트에 현금이 없으면 환매 불가 — 잠금과 유동성은 다른 문제
        한 바퀴 돌면 대여자 셋 다 흑자 (스프레드가 수수료를 덮음)
        아래 칸을 닫아도 위 칸 시계는 돈다. 닫힌 칸에서도 상환·환매는 됨

부족분  WTGXX 0.70 → A의 담보가 전량 넘어가고 부족분이 A 계정에 남음
        V_B 총자산과 eV_B 가격이 움직이지 않음 (사회화 해제)
        위 칸 둘은 숫자로 멀쩡. 격차는 B의 환매에서 드러남
        청산인은 할인 2%만큼 벌고, WTGXX는 맨 아래 칸을 안 벗어남
        꼭대기 부도가 아래로 번지지 않음

승계    중간 참여자는 자기 계정으로 청산 불가 (EVC_ControllerViolation)
        서브계정으로는 가능. 그 서브계정이 통지도 보냄
```

### 청산에서 드러난 것

**백서 4.4절이 EVK에 없습니다.** 백서는 담보가 충분해도 만기 미상환이면 청산 사유라고
합니다. EVK의 `liquidate`는 건전성이 깨져야 통과하고, WTGXX는 $1 고정에 수익으로 늘기만
해서 만기가 지나도 깨지지 않습니다. `test_positionStillHealthyAfterMaturity`와
`test_liquidateRejectedWhileHealthy`가 그 증거입니다.

Wave 1에서 `MaturityController`가 그 번역을 맡습니다. 만기 후에만, 누구나 발동할 수
있으며, 청산선이 개시 한도에서 0까지 선형으로 내려갑니다. 온체인 이벤트에는 여전히
"담보 부족"으로 남으므로 만기 레지스트리의 기록이 "왜 낮췄는가"의 근거가 되고, M5에서
만기를 개시와 원자적으로 묶은 것이 여기서 값을 합니다.

**청산 성공이 담보 확보가 아닙니다.** EVK 청산은 볼트 share만 이전하고 WTGXX를 만지지
않습니다. 화이트리스트도 동결도 일시정지도 타지 않습니다. 실제 토큰은 그다음 인출에서
나오고, 거기서 처음 규제 자산 제약에 부딪힙니다.
`test_liquidationSucceedsEvenWhenTokenTransferWouldFail`이 이 간극을 보여줍니다 — 담보
볼트를 동결해도 청산은 성공하고, 인출에서 막혀 대여자가 share만 들고 앉습니다.

그래서 `LiquidationPrecheck`을 **청산 전과 인출 직전 두 번** 부릅니다. 청산은 되돌릴 수
없으므로 앞에서 걸러야 합니다.

**청산인이 부채를 인수합니다.** 백서 4.3절의 "대여자가 담보를 가져가 이슈어에 환매"와
형태가 다릅니다. 인수 직후 건전성이 깨지므로 청산과 상환을 EVC 배치로 묶습니다. 대여자가
자기 볼트의 채권자이자 채무자가 되어 상쇄되는 구조입니다.

### 훅이 청산을 막을 뻔했습니다

M3에서 share 전송을 무조건 차단했는데, EVK는 담보 압류를
`evc.controlCollateral(collateral, violator, 0, transfer(receiver, amount))`로 수행합니다
(`EVCClient.sol:102`). 무조건 막으면 **대여자가 담보를 회수할 방법이 사라집니다.** 백서
6.1절이 "collateral recovery still go through"라고 못박은 지점을 위반한 것입니다.

`evc.isControlCollateralInProgress()`가 이 문맥을 구분합니다. 참이면 등록된 컨트롤러가
압류하는 중이고 EVC가 이미 자격을 검증했습니다. 임의 전송은 이 플래그가 거짓이라 계속
막힙니다.

### 만기 후 이자 (M7)

```
원금            80.000000 USDC
7일 후 부채      80.770299        이자 0.770299 (0.963%)
8일 후 부채      80.880946        초과 0.110647 (0.138%)
```

EVK는 만기 개념이 없어 부채가 계속 누적됩니다. 백서 4.4절은 만기에 부채가 멈추고 지연의
대가를 할인으로 물리라고 합니다. 부채가 자라면 담보 부족 경로가 연체 경로보다 먼저 발동해
두 청산 사유가 경합하기 때문입니다.

**이 숫자가 프로덕션에서 4.4절을 그대로 갈지 정하는 근거입니다.**

## 다음 단계

M8은 Sepolia 실물 전환입니다. 한동안 "WisdomTree 답변 넷이 선행"이라고 적어 뒀는데,
**그 넷은 10/03 샌드박스 실측으로 정리됐습니다.**

```
컨트랙트 주소 등록      된다. 승인까지 확인 ("리시버 훅 하나가 Layer 1을 가른다" 참조)
KYC NFT 발행 리드타임   승인 후 약 1분
샌드박스 조직·크리덴셜   확보
테스트 WTGXX 확보       Connect API 소액 Purchase. settlement_wallet 에 볼트 지정
```

**담보 볼트 설계를 다시 볼 일이 없어졌습니다.** `WTGXXCollateralVault`가 `EVault +
onERC721Received`인 것이 그대로 답이었습니다 — 리시버 훅이 없는 컨트랙트는 같은 경로로
승인받아도 화이트리스트에 못 오릅니다.

M8의 한 조각은 이미 서 있습니다. `WTGXXGate`가 Sepolia에서 실물 WTGXX를 보고 있고
(`0x3081cdE0...`), 위 실측 표가 그 배포로 찍은 값입니다. 목업이 아닌 상태로 게이트 경로가
도는 것은 확인됐습니다.

남은 것은 답을 기다리는 종류가 아니라 준비하는 종류입니다. 체인 데모용 승인 주소 다섯
(A·B·C·D + 청산인), 샌드박스 child org 추가, 그리고 기간 상수를 줄인 배포입니다.

M9(환매 분리 테스트)는 M8과 독립이며 크리덴셜만 있으면 지금도 가능합니다.
