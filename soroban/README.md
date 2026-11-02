# poc-tmmf-repo → Soroban (WIP)

EVM 판 `poc-tmmf-repo` (M1~M7) 를 Soroban 으로 옮기는 중. 지금은 한 칸(A ← B)만 동작하고 재담보 사다리는 아직.

```bash
cargo test
```

soroban-sdk 29.0.1. 테스트는 호스트에서 돌아서 wasm 빌드 없이 됨. 배포용 빌드는 `stellar contract build`.

## 진행 상황

- [x] gate, participant-registry, maturity-registry
- [x] collateral-vault, repo-market (개시/상환/만기/통지 창/사다리 청산), fixed-oracle
- [~] vault-factory — 코드는 있음. 실배포 테스트는 wasm 빌드 후 (`#[ignore]`)
- [ ] 재담보: 대여 지분을 SEP-41 로 노출해서 위 칸 담보로 사용
- [ ] step-in 후 counterparty 갱신 (EVM 판에서도 남아 있던 것)
- [ ] 배포 스크립트, testnet 에서 실제 WTGXX/USDC 로 확인
- [ ] NAV 감시 오라클 (SEP-40 형태 Dataspan 어댑터)

## 구조

EVK/EVC 가 없어서 그대로 옮기지 않고 다시 짰음. EVM 판에서 EVK 동작을 끌어내려고 쓴 우회(거버너로 LTV 깎기, 0 금리 IRM, 훅으로 연산 끄기, 서브계정)는 빼고, 백서 요구사항만 남김.

| EVM | Soroban |
|---|---|
| WTGXXGate | gate |
| LiquidationPrecheck | gate::check_exit (진단용) |
| ParticipantRegistry | participant-registry |
| MaturityRegistry | maturity-registry |
| WTGXXCollateralVault + CollateralVaultHook | collateral-vault |
| CollateralVaultFactory | vault-factory |
| FixedOneToOneOracle | fixed-oracle |
| EVK 부채 볼트 + FixedRateIRM + DebtVaultAccessHook + RepoOpener + MaturityController | repo-market |
| EulerRouter, MockKycNFT, ReceiverProbe | 없음 |
| EVC operator | require_auth 인증 트리 + `set_agent` (통지만 위임) |

## EVM 판과 다른 점

**컴플라이언스.** Stellar 의 WTGXX 는 클래식 자산이라 화이트리스트 = 발행사 승인(`authorized`). KYC NFT 대신 발행사가 볼트 주소에 `set_authorized` 를 걸어줘야 함.

- `getCompliance() == 0` 검사 → 카나리아로 대체. AUTH_REQUIRED 가 꺼지면 승인 이력 없는 주소도 `authorized == true` 가 나옴 (테스트로 확인). 게이트 자기 주소를 카나리아로 씀. 발행사가 게이트 주소를 승인하면 안 됨.
- `isPaused()` 는 대응되는 게 없음.

**압류.** 볼트에 share 가 없고 압류 때 WTGXX 를 바로 옮김. 청산인이 발행사 미승인이면 SAC 에서 막혀서 청산 전체가 revert. M6 에서 봤던 "청산은 됐는데 인출이 막히는" 경우가 안 생김.

**권한.** `msg.sender` 대신 `caller.require_auth()`. 마켓이 자기 주소로 레지스트리에 기록. operator 위임이 필요 없고, 계정당 컨트롤러 하나 제약도 없어서 중간 참여자 청산에 서브계정이 필요 없음 (사다리 올릴 때 테스트로 확인 예정).

**숫자.** 금액 i128, 7 decimals 끼리라 18↔6 보정 불필요. 이자는 상호작용마다 지수에 곱하는 방식이라 EVK 연속 복리와 소수점 아래가 조금 다름. EVK 이자 수수료 10% 없음 — 프로토콜 수수료 둘지 결정 필요.

**TTL.** persistent 저장소에 수명이 있음. 지금은 쓸 때마다 ~30일 연장. 만기가 긴 마켓이면 연장 러너 필요.

**팩토리 주소.** Soroban 주소는 (네트워크, 배포자, salt) 로만 정해지고 코드 해시가 안 들어감. 볼트 주소 검증할 때 `wasm_hash()` 도 같이 확인해야 함. 볼트에 upgrade 함수는 안 넣음.

## 테스트 대응

| EVM | 여기 |
|---|---|
| WTGXXGate.t.sol | gate |
| ParticipantRegistry.t.sol | participant-registry |
| MaturityRegistry.t.sol | maturity-registry |
| RepoScenario.t.sol | `open_and_repay_round_trip`, `open_rejects_*` |
| MaturityController.t.sol | `close_market_*`, `ramp_*`, `discount_is_capped` |
| NoticeWindow.t.sol | `notice_window_*` |
| SeizureBoundary.t.sol | `seizure_*` |
| ChainDefault.t.sol | `bad_debt_is_not_socialized` (한 칸만) |
| ChainCycle, RehypoChain, StepIn | 재담보 작업 후 |

담보 100 / 부채 80.77 에서 청산이 열리는 지점이 사다리의 12.2% 로 EVM 판 수치(약 12%)와 맞음.

## 다음

1. repo-market 대여 지분에 SEP-41 인터페이스 (`balance`, `transfer`, `decimals`). 전송은 자격 있는 주소만
2. collateral-vault 가 아래 칸 지분도 담을 수 있게
3. 오라클에 지분 → 자산 환산 추가
4. ChainCycle / ChainDefault / StepIn 을 세 칸으로 옮기기
