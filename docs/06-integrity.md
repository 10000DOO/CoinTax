# 정합성·검증 설계 (Integrity)

| 항목 | 내용 |
|------|------|
| 문서 버전 | 0.1 |
| 작성일 | 2026-08-10 |
| 상태 | Confirmed — **세금 계산 필수 요건** |
| 관련 | [02-design.md](./02-design.md), [05-decisions.md](./05-decisions.md) |

> 세금이 걸린 숫자다. **한 번의 forward pass로 끝난 결과를 신뢰하지 않는다.**  
> 계산 결과와 불변식(invariant)이 맞을 때만 신고용 리포트를 “확정”한다.

## 구현 상태 (2026-08-11)

§3 의 v1 Must 항목은 **전부 `Domain/Integrity/Verifier.swift` 에 구현**되어 있다.
`design/14-implementation-spec.md` §7 의 표는 *최소 착수 범위*였고, 현재는 이 문서가 정본이다.

| 항목 | 구현 |
|------|------|
| V-QTY-01 / 02 / 03 / 04 | ✅ (이벤트만으로 수량 재계산 · 전송 1:1 · 링크 중복 감지) |
| V-COST-01 / 02 / 03 / 04 / 05 / 06 | ✅ |
| V-DEM-01 / 02 / 03 / 04 | ✅ |
| V-FX-01 / 02 / 03 | ✅ (02는 `DisposalRecord.fxSourceDate` 로 원천 대조) |
| V-TAX-01 ~ 05 | ✅ |
| V-RE-01 / 02 | ✅ (RE-02 는 `proceeds − cost − fees` 독립 재합산) |
| V-IMP-01 | ✅ (중복 fingerprint) |
| V-IMP-02 / 03 | 파서 단계 경고로 대체 (행 오류·제외 건수를 ParseResult 에 보고) |
| V-IMP-04 / 05 | ✅ (OKX 파일 짝 · 파일 간 중복) |
| V-RE-03 | 미구현 (Should) |

**엔진은 예외로 계산을 중단하지 않는다.** 재고 부족·환산 불가·시가 누락은
`ReplayResult.issues` 로 모아 검증기가 Critical 로 승계하고, 요약 상태를 `blocked` 로 만든다.
(예외로 던지면 이 문서가 요구하는 「Block + Issue list」 화면이 만들어지지 않는다.)

---

## 1. 파이프라인 (필수)

```text
┌─────────────┐    ┌──────────────┐    ┌─────────────────┐    ┌────────────┐
│  Ingest     │ →  │  Calculate   │ →  │  Verify         │ →  │  Publish   │
│  CSV/매칭   │    │  원장·손익   │    │  불변식·재계산  │    │  리포트    │
└─────────────┘    └──────────────┘    └─────────────────┘    └────────────┘
                                              │ fail
                                              ▼
                                       Block + Issue list
                                       (export 비활성)
```

| 단계 | 역할 |
|------|------|
| Calculate | 원장 재생, 의제 적용, 실현손익, 세액, 보유 스냅샷 |
| Verify | **독립 검사** + 가능하면 **이중 경로 재계산** |
| Publish | Verify `passed` 일 때만 UI “확정”, CSV/PDF export 허용 |

`TaxYearSummary.status`: `draft` \| `verified` \| `blocked`

---

## 2. 설계 원칙

1. **검증은 계산과 코드를 분리**  
   - `CostBasisEngine` / `TaxEngine` ≠ `LedgerVerifier` / `TaxVerifier`  
   - 검증기가 엔진 private 상태에만 의존하지 말고, **이벤트 로그 + 공개 결과**로 재구성 가능해야 함.

2. **실패 기본(fail-closed)**  
   - Critical 실패 → 신고용 숫자 숨김 또는 큰 경고 배너 + export 잠금.  
   - Warning만 있으면 표시는 하되 `verified` 아님.

3. **감사 추적**  
   - 각 실현 건: 사용 lot/평균 스냅샷 id, 환율 id, 의제 적용 여부.  
   - 검증 리포트 스냅샷을 프로젝트에 저장 (재현).

4. **Decimal only**  
   - 검증 시 허용 오차는 수량·금액 스케일에 맞는 **명시적 epsilon** (예: 수량 1e-10, KRW 1원 미만 반올림 정책 문서화).

5. **골든 테스트**  
   - 모든 불변식은 단위 테스트로 고정. 회귀 시 CI 실패.

---

## 3. 검증 항목 (v1 Must)

### 3.0 외부 대조 (V-BAL) — 이 앱 밖에서 온 정답지

거래소가 원본에 **직접 찍어준 잔고**와 매 거래마다 맞춘다.
다른 검사는 전부 우리 코드가 우리 코드를 검사하므로, 같은 오해를 공유하면 다 같이 통과한다.
이 검사만이 그 고리 밖에 있다 ([audit-2026-08-12-logic.md](./audit-2026-08-12-logic.md) §3.7).

대조 단위는 계정이 아니라 **`(계정, 원본 종류, 자산)` = 명세서 하나**다.
OKX 는 펀딩 계정과 트레이딩 계정의 잔고를 각각 다른 파일에 찍어 주는데 앱은 둘을 한 계정으로 합친다.

| ID | 검사 | Critical |
|----|------|----------|
| V-BAL-01 | 거래소가 찍어준 잔고 == 우리 계산 (매 거래) | ✅ |
| V-BAL-02 | 첫 잔고가 0에서 시작하지 않음 = **자료 시작 전 보유분** (취득원가를 알 수 없다) | ✅ |
| V-BAL-03 | 잔고 열이 있는 원본이 하나도 없음 → 외부 대조를 못 함 | 경고 |

잔고 열이 없는 원본(바이낸스 화면 CSV)은 `scripts/binance-expected-balances.py` 로
**앱과 무관하게** 계산한 정답지를 만들어 회귀 테스트에서 대조한다.

### 3.1 원장·수량 불변식

| ID | 검사 | Critical |
|----|------|----------|
| V-QTY-01 | 계정×자산: Σ(이벤트 부호 수량) == 현재 보유 수량 | ✅ |
| V-QTY-02 | 보유 수량 ≥ 0 (음수 재고 금지; dust 정책 예외는 문서화) | ✅ |
| V-QTY-03 | confirmed 전송: 입고 ≤ 출고 (초과면 잘못 연결) | ✅ |
| V-QTY-03 | confirmed 전송: 소실이 허용 범위(출고 1%·기재 수수료) 초과 | 경고 — 소액 전송은 네트워크 수수료가 1%를 훌쩍 넘는 게 정상이라, Critical 로 막으면 정상 자료의 export 가 잠긴다 |
| V-QTY-04 | 미매칭 전송이 원가 이전에 쓰이지 않음 | ✅ |

### 3.2 원가·금액 불변식

| ID | 검사 | Critical |
|----|------|----------|
| V-COST-01 | 매도 출고 원가 ≤ 해당 계정 매도 직전 총 장부원가 (허용 오차 내) | ✅ |
| V-COST-02 | 전송: 입고 원가 == 출고 원가 × (입고수량/출고수량) (보수 정책) | ✅ |
| V-COST-03 | 소실 수수료 원가가 **필요경비·세액 공제에 포함되지 않음** | ✅ |
| V-COST-04 | 이동평균 계정: 평단 × 수량 ≈ 총원가 | ✅ |
| V-COST-05 | FIFO 계정: open lots 합 수량·원가 == 포지션 | ✅ |
| V-COST-06 | 실현손익 건별: proceeds − cost − fees == recorded PnL | ✅ |
| V-COST-07 | 수량이 있는 매수의 취득가액이 0원 (원본 금액 칸을 못 읽었다는 뜻) | ✅ |

### 3.3 의제 취득가

| ID | 검사 | Critical |
|----|------|----------|
| V-DEM-01 | 2027-01-01 0시 스냅샷 수량 == 그 시점까지 재생 결과 | ✅ |
| V-DEM-02 | 의제 단가 == max(실제 장부 단가, 시가) — **매입 건별 방식에서 lot 이 둘 이상이면 `≥`** (lot 별 max 의 가중평균이라 하한보다 커진다). 단가는 나눗셈에서 나오므로 상대 허용오차로 본다 | ✅ |
| V-DEM-03 | 2027-01-01 이후 첫 원장 총원가 == 의제 총액 | ✅ |
| V-DEM-04 | 시가 누락 포지션이 있으면 verified 불가 | ✅ |
| V-DEM-05 | 과세 시작 시점에 도착하지 않은 전송이 있음 (그 수량은 의제 대상에서 빠진다) | 경고 |

### 3.4 환율

| ID | 검사 | Critical |
|----|------|----------|
| V-FX-01 | KRW 환산이 필요한 모든 건에 rate 존재 | ✅ |
| V-FX-02 | 사용된 rate가 캐시/수동 입력 원천과 일치 (id 추적) | ✅ |
| V-FX-03 | 휴일 대체 시 `fxSourceDate` 기록됨 | Warning if missing |

### 3.5 세금 집계

| ID | 검사 | Critical |
|----|------|----------|
| V-TAX-01 | Σ 건별 소득 == 연간 소득금액 (필터 동일) | ✅ |
| V-TAX-02 | 과세표준 == max(0, 소득 − 공제) | ✅ |
| V-TAX-03 | 국세 == 과세표준 × 20% (반올림 정책 적용 후) | ✅ |
| V-TAX-04 | 지방세 == 과세표준 × 2% (동일 반올림) | ✅ |
| V-TAX-05 | taxStartDate 이전 처분이 과세 합계에 없음 | ✅ |

### 3.6 이중 경로·재현 (강력 권장 → v1 Must 일부)

| ID | 검사 | Critical |
|----|------|----------|
| V-RE-01 | **동일 입력으로 엔진 2회 실행 → 바이트 단위 동일 요약** (결정성) | ✅ |
| V-RE-02 | 독립 구현의 “단순 재합산기”로 건별 PnL 재합산 == 엔진 합계 | ✅ |
| V-RE-03 | 샘플 구간 이벤트만으로 부분 재생 시 중간 스냅샷 일치 | Should |

`V-RE-02` 예: Verifier가 events+links를 읽어 **별도 모듈**에서 건별 손익만 다시 더함 (평균/FIFO는 공유 라이브러리 쓰되, 집계 루프는 분리).

### 3.7 Import·매칭

| ID | 검사 | Critical |
|----|------|----------|
| V-IMP-01 | 중복 fingerprint 없음 | ✅ |
| V-IMP-04 | OKX Trading 내부 이동만 있고 Funding History 누락 시 차단 | ✅ |
| V-IMP-05 | 같은 거래가 서로 다른 파일에 중복 존재 | Warning |
| V-IMP-02 | 파서 error 행이 ledger에 없음 | ✅ |
| V-IMP-03 | 선물 제외 건수가 import 로그와 일치 | Warning |

---

## 4. 결과 모델

```swift
struct VerificationReport {
    var runID: UUID
    var calculatedAt: Date
    var status: VerificationStatus  // passed, passedWithWarnings, failed
    var issues: [VerificationIssue]
    var metrics: [String: String]   // e.g. abandonedTransferCostKRW
}

struct VerificationIssue {
    var id: String          // "V-QTY-02"
    var severity: Severity  // critical, warning, info
    var message: String     // 한국어
    var context: String?    // account, asset, eventID
}
```

UI:

- 리포트 상단: **검증 통과 / 경고 / 실패** 배지  
- 실패 목록 클릭 시 관련 거래로 이동  
- export: `status == passed || passedWithWarnings` 이고 설정이 경고 허용일 때만. **critical 있으면 잠금.**

---

## 5. 반올림·허용 오차 (문서 고정)

구현 시 코드 상수로 두고 테스트:

| 대상 | 정책 (초안, 구현 시 확정 후 여기 갱신) |
|------|----------------------------------------|
| KRW 표시 | 원 단위 **plain half-up** (`Money.roundKRW`) — 엔진·검증 동일 |
| 세액 | 원 단위 |
| 수량 비교 | abs(a-b) ≤ 1e-10 또는 자산 decimals |
| 원가 비교 | abs ≤ 1 KRW (누적 후) |

검증기와 엔진이 **다른 반올림**을 쓰면 안 된다. 공유 `MoneyRounding` 사용.

---

## 6. 테스트 의무

| 종류 | 내용 |
|------|------|
| Unit | 각 V-* 에 대해 pass/fail fixture |
| Golden G1 | 빗썸↔해외 USDT 왕복 + 매매 + 수수료 소실 |
| Golden G2 | 의제 max(실제, 시가) 두 갈래 |
| Property (가능 시) | 임의 이벤트열에서 음수 재고 없음 등 |
| Mutation | 고의로 수량을 깨면 verifier가 fail |

**Verifier 없는 Calculate PR은 머지하지 않는다** (개발 규약).

---

## 7. 성능

검증은 계산과 같은 O(n) 목표.  
10만 건에서도 “계산+검증” 합이 요구사항 예산 내.  
필요 시 검증을 백그라운드 Task로 돌리고, 완료 전 publish 비활성.

---

## 8. 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-08-10 | 초안. fail-closed 검증 파이프라인 필수화 |
| 2026-08-11 | v1 Must 전 항목 구현. 엔진 예외 → 이슈 승계 방식으로 변경 |
