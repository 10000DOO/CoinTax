# 계산 로직 감사 및 수정 (2026-08-12, 2차)

| 항목 | 내용 |
|------|------|
| 대상 | 원장 재생 · 검증 파이프라인 · import 라우팅 전 구간 |
| 상태 | 수정 완료 · 실데이터 회귀 통과 (138 tests) |
| 선행 | [realdata-audit-2026-08-12.md](./realdata-audit-2026-08-12.md) (1차 — 파서·원장 붕괴) |

---

## 0. 한 줄 요약

1차 감사가 「파일을 못 읽는 문제」를 고쳤다면, 이번엔 **읽은 뒤 계산이 조용히 어긋나는 자리**를 찾았다.
수수료로 나간 코인이 보유에 남아 있었고, 연말을 걸친 전송이 아직 도착도 안 했는데 의제취득가를 받았고,
정상적인 소액 전송이 신고자료 export 를 잠그고 있었다. 그리고 **여러 거래소 파일을 한 번에 넣으면
전부 한 계정으로 들어갔다.**

---

## 1. 수수료로 나간 코인이 장부에 그대로 남았다

### A-01 (Critical) 과세 시작 전 매도의 수수료 자산이 장부에서 빠지지 않았다

- 위치: `CostBasisEngine.replay` `case .sell`
- 원인: 수수료 처리(`feeCostKRW`)가 `guard isTaxable else { continue }` **뒤**에 있었다.
  과세 시작(2027-01-01) 이전 매도는 그 줄에서 빠져나가므로 수수료 자산이 장부에 반영되지 않는다.
- 영향: 2026-12-31 보유 수량이 부풀고 → **의제취득가가 그만큼 틀어진다.**
  매수는 항상 수수료를 반영하므로 매수/매도가 비대칭이었고, 검증기의 독립 수량 재계산과도 어긋나
  정상 데이터에서 V-QTY-01·V-DEM-01 Critical 이 날 수 있었다.
- 수정: 수수료 반영은 과세 여부보다 앞선다. 필요경비 계상만 과세 대상일 때 한다.

### A-02 (High) 견적자산(USDT)으로 낸 수수료가 장부에서 빠지지 않았다

- 위치: `CostBasisEngine.feeCostKRW`
- 원인: 수수료 자산이 `isUSDTish` 면 환율로 **금액만 환산**하고 장부는 건드리지 않았다.
  BNB 같은 제3자산만 장부에서 처분했다.
- 영향: 수수료로 낸 USDT 가 보유에 계속 남는다 → 평단·의제취득가·이후 손익이 모두 어긋난다.
  바이낸스에서 BNB 수수료 할인을 쓰지 않으면 **수수료가 견적자산으로 붙는 것이 기본**이라 흔한 경우다.
  (1차 감사에서 「남은 한계 §4-6」으로 적어 둔 항목 — 실데이터에 없었을 뿐 결함이다.)
- 수정: 원화가 아닌 수수료는 종류를 가리지 않고 그 자산 장부에서 처분하고, **장부 원가**를 부대비용으로 쓴다.
  이 값은 「수수료 자산 처분손익 인식 + 시가를 필요경비로」와 결과가 같다
  (처분이익 = 시가 − 장부원가, 필요경비 = 시가 → 순효과 = −장부원가).
- 파급: 코인 수수료는 이제 환율이 필요 없다 → `FXService.missingDays` 에서 수수료 항목 제거.
  그대로 두면 쓰지도 않는 날짜 때문에 계산이 막힌다.

### A-03 (Medium) 매도 수수료가 기초자산일 때 그 수량이 사라지지 않았다

- 매수의 기초자산 수수료는 **받는 수량에서 차감**되고, 매도는 체결 수량과 **별도로** 빠진다. 방향이 반대다.
- 기존 구현은 매도도 「이미 반영됐다」고 보고 건너뛰어 보유가 그만큼 부풀었다.
- 수정: 매도는 처분하고 그 장부 원가를 필요경비로. 원본이 이미 순액인 판본(`quantityIsNetOfFee`)만 예외.
- 엔진과 검증기가 **같은 규칙 한 벌**을 쓰도록 `Verifier.feeReducesBook(_:feeAsset:)` 로 뽑았다.

---

## 2. 전송

### A-04 (High) 도착 원가를 「출금 시각」에 입고했다

- 위치: `CostBasisEngine.replay` `case .withdrawal` / `case .deposit`
- 원인: 확정 링크가 있으면 출금을 처리하는 자리에서 곧바로 도착 계정에 입고했다.
- 영향: **연말을 걸치는 전송**(예: 12/31 23:50 출금 → 1/2 09:00 입금)에서 아직 도착하지 않은 자산이
  2026-12-31 스냅샷에 잡혀 **의제취득가 max 가 잘못 적용**된다. 검증기는 이벤트 시각 기준으로 재계산하므로
  V-DEM-01 Critical 오탐도 함께 났다.
- 수정: 출금 시점에 이전 원가를 보류(`pendingArrivals`)했다가 **입금 이벤트 시각**에 입고한다.
  거래소 시계 차이로 입금이 먼저 기록된 전송은 기존처럼 출금 시각에 입고한다(원가가 사라지지 않게).
- 추가: 과세 시작 시점에 아직 이동 중인 전송이 있으면 `V-DEM-05` 경고 —
  그 수량은 의제취득가 대상에서 빠지므로(세액이 커지는 방향) 사용자가 알아야 한다.

### A-05 (Critical) 정상적인 소액 전송이 신고자료 export 를 잠갔다

- 위치: `Verifier` V-QTY-03
- 원인: 「출금 − 입금」 차이가 출금액의 1%(또는 기재된 수수료)를 넘으면 무조건 Critical 이었다.
  그런데 매칭 화면은 손실률 50%까지 후보로 제시한다 — **두 규칙이 서로 모순**이었다.
- 영향: 10 USDT 를 보내 9 USDT 를 받는 전송(네트워크 수수료 10%)은 흔하다. 사용자가 확인해 연결했는데
  검증기가 Critical 로 막아 계산 상태가 `blocked` 이 되고 export 가 잠긴다.
  **실데이터에서 실제로 발생한다** — OKX→바이낸스 USDT 전송의 수수료가 출금액의 약 8%다.
- 수정: 손실률이 크면 **경고**로 내리고 손실률·수량을 문구에 적는다.
  「입금이 출금보다 많다」(잘못 연결)는 여전히 Critical.

---

## 3. Import — 여러 거래소를 한 번에

### A-06 (Critical) 한꺼번에 넣은 파일이 전부 한 계정으로 들어갔다

- 위치: `ImportView` — 사용자가 고른 계정 하나로 모든 파일을 넣었다. 파서만 자동이고 계정은 수동이었다.
- 영향 두 가지가 동시에 터진다.
  1. **원가법이 뒤바뀐다** — 빗썸은 이동평균, 해외는 선입선출이다 (05-decisions §1.2).
     빗썸 파일이 바이낸스 계정으로 들어가면 국내 취득가액 계산 방식 자체가 달라진다.
  2. **거래소 간 전송이 사라진다** — 매칭은 계정이 서로 달라야 후보로 잡는다
     (`TransferMatchingEngine.suggest` 의 `d.accountID == w.accountID` 제외).
     같은 계정이 되면 전송이 「미매칭 출금 = 원가 소멸」 + 「미매칭 입금 = 취득가 0」으로 처리돼
     **세금이 크게 부풀려진다.**
- 수정:
  - `ImportRouter` 신설 — 파일 내용으로 찾은 **파서 ID → 거래소** 를 확정한다.
  - `ParserRegistry.bestPreset(for:)` — 제네릭 폴백을 제외하고 거래소 프리셋 중에서만 고른다.
    제네릭은 열 이름에 `date`·`amount` 만 있어도 0.35 를 내므로 섞으면 근거 없이 배정된다.
  - `ProjectService.ensureAccount(_:in:)` — 해당 거래소 계정이 없으면 만든다.
  - `ImportService.resolveAccount(url:project:)` — 신뢰도 0.6 이상일 때만 자동 배정.
    그 아래·제네릭·미인식은 `nil` 로 두고 사용자에게 묻는다. **틀린 계정으로 조용히 들어가지 않는다.**
  - `ImportView` — 거래소 선택 기본값이 **「자동으로 구분」**. 파일별 결과를 한 줄씩 쌓아 보여준다
    (`빗썸 ← 132건`, `바이낸스 ← 106건` …). 시트(제네릭 매핑·PDF 비밀번호)를 거치는 파일은
    그 파일의 계정을 따로 들고 있는다.

한계: 같은 거래소의 **계정 여러 개**(부계정)는 v1 범위 밖이다. 거래소당 계정 하나로 합쳐진다.

---

## 3.5 환율

### A-08 (High) 한국은행 인증키로 채운 환율이 「참고 시세」로 표시됐다

- 위치: `FXService.fillMissingFromRemote` → `CalculationPipeline`
- 원인: `CompositeFXClient` 로 조회하면 출처를 날짜별이 아니라 **한 덩어리로** `remote-ecos-or-public`
  이라고 붙였다. 리포트 판정은 `source.contains("public")` 이라 **ECOS 로 정상 조회한 날짜까지 걸린다.**
- 영향: 인증키를 제대로 등록한 사용자에게 「공식 기준환율이 아닌 참고 시세가 N일 사용되었습니다」 경고가
  붙고, 계산 상태가 `verified` 로 올라가지 못해 항상 `draft` 로 남는다.
- 수정: `FXClient` 에 `sourceTag` / `fetchWithSources(days:)` 를 두어 **날짜마다** 출처를 기록한다.
  판정도 `source == "remote-public"` 정확 비교로 바꿨다.
- 덧붙임: 인증키가 있는데 한 건도 못 받으면 「수동으로 넣으세요」가 아니라
  **「인증키가 유효한지 확인하세요」**로 안내한다 (`FXService.lastRemoteFilledECOS`).

## 4. 표기

### A-07 (Medium) 「2026-12-31 시가」가 법령 기준시점과 다르게 읽힌다

- 소득세법 시행령 제88조제2항의 기준 시점은 **2027-01-01 0시** 공시가격이다.
  화면·리포트가 「2026-12-31 시가」라고만 적으면 사용자가 **12월 31일 종가**를 넣기 쉽다.
  같은 순간을 가리키지만 **입력하는 값이 달라진다.**
- 수정: `TaxCopy.deemedAsOfLabel` / `deemedAsOfDetail` 한 곳에서 정의하고 설정·홈·리포트·PDF·엔진 메시지에 반영.
  저장 키(`MarketPriceEntity.asOf = "2026-12-31"`)는 같은 시점이므로 그대로 둔다 (기존 데이터 보존).

---

## 5. 회귀 테스트

`CoinTaxTests/AuditFixTests.swift` (신규 · 커밋됨)

| 테스트 | 확인 |
|--------|------|
| `testPreTaxSellFeeAssetLeavesBook` | 과세 전 매도의 BNB 수수료가 의제 스냅샷 수량에서 빠지고 검증기와 일치 |
| `testQuoteAssetFeeLeavesBookAndUsesBookCost` | USDT 수수료가 USDT 장부에서 빠지고, 부대비용은 장부 원가 |
| `testTransferArrivesAtDepositTimeNotWithdrawalTime` | 연말 경계 전송이 의제 대상에서 빠지고 원가는 이전됨 · V-DEM-05 |
| `testTransferWithDepositRecordedBeforeWithdrawalStillCarriesCost` | 시각 역전 전송에서도 원가가 사라지지 않음 |
| `testHighFeeTransferIsWarningNotCritical` | 손실 10% 전송이 경고이고 export 가 열림 |
| `testDepositLargerThanWithdrawalStaysCritical` | 잘못 연결은 여전히 Critical |
| `ImportRoutingTests` 5건 | 파서→거래소 매핑 · 합성 파일 라우팅 · 제네릭 자동배정 금지 · 계정 분리 · 계정 자동 생성 |
| `FXSourceTagTests` 2건 | 날짜별 출처 태그 저장 · 기본 태그 적용 |

`CoinTaxTests/GapHuntTests.swift` — `testCryptoFeeDoesNotRequireFX` · `testUSDTFeeReducesUSDTBook`

`CoinTaxTests/RealDataTests.swift` (git 제외 · 로컬 실파일 필요)

| 테스트 | 확인 |
|--------|------|
| `testAutoRoutingSplitsRealFilesByExchange` | 실파일 6개를 폴더째 넣어 3개 계정으로 자동 분리 · 원가법 유지 · 전송 후보 발생 |
| `testRealProjectVerificationHasOnlyExpectedCriticals` | **검증기 전 항목** 실행. 예상 Critical(시가 누락·이력 공백) 외 0건 · 전송 손실은 경고 |

> 이전 `testEndToEndRealProject` 는 V-QTY-01 만 봤다. 그래서 A-05(정상 전송을 Critical 로 막는 문제)가
> 이번 감사 전까지 드러나지 않았다. **검증기 일부만 보는 테스트는 통과해도 안전하지 않다.**

전체: 138 tests, 0 failures (`scripts/smoke.sh`).

---

## 6. 남은 한계

1. **같은 거래소 계정 여러 개** — 부계정은 하나로 합쳐진다.
2. **개인지갑 출금** — 1차 감사 §4 그대로. 지갑 계정·수동 이벤트 입력이 없다.
3. **2027-01-01 0시 시가** — 사용자 입력이 필요하다 (환율은 ECOS 인증키로 자동).
4. **과세 시행일 하드코딩** — `TaxTime.taxStartDate`. 유예되면 의제 스냅샷 시점까지 함께 움직여야 한다 (TQ-15).
5. **거래소 잔고 열 대조(V-BAL)** — 1차 감사 §5 그대로. 이력 공백을 지금은 내부 정합성으로만 추정한다.
