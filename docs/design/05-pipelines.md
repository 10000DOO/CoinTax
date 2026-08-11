# 05. 엔드투엔드 파이프라인

| 버전 | 2.0 |
|------|-----|

---

## 1. 전체 시퀀스

```text
사용자
  │
  ├─① Import 원본 (PDF | XLSX | CSV)
  │     FormatProbe → ParserRegistry → parse → Dedupe → Persist
  │     (빗썸 PDF / 바이낸스 XLSX / OKX CSV)
  │
  ├─② Match transfers ──► Suggest ──► User confirm links
  │     (빗썸 출금 ↔ OKX Transfer in 등)
  │
  ├─③ Fill FX ──► Cache / manual missing dates
  │
  ├─④ Run Calculation (버튼)
  │     │
  │     ├─ Replay ledger (per account book)
  │     ├─ Apply transfers (TransferCostPolicy)
  │     ├─ Snapshot @ deemed date → apply DeemedCostPolicy
  │     ├─ Continue replay from tax era
  │     ├─ Aggregate disposals → TaxYearSummary (draft)
  │     ├─ Build HoldingsSnapshot
  │     └─ Run IntegrityVerifier
  │           ├─ fail → status=blocked, issues[]
  │           └─ pass → status=verified
  │
  └─⑤ Export only if verified (or warnings-allowed)
```

Import 상세: [09-import-and-matching.md](./09-import-and-matching.md)

---

## 2. CalculationPipeline API

```swift
struct CalculationInput {
    var projectID: UUID
    var taxYear: Int
    var policies: PolicyBundle
    var events: [LedgerEvent]
    var links: [TransferLink]      // confirmed only for cost move
    var fx: FXProvider
    var marketPricesAtDeemed: [AssetSymbol: Decimal] // KRW per unit
}

struct CalculationOutput {
    var summary: TaxYearSummary
    var holdings: HoldingsSnapshot
    var deemed: [DeemedPosition]
    var verification: VerificationReport
    var abandonedTransferCostKRW: Decimal
}
```

```swift
protocol CalculationPipeline {
    func run(_ input: CalculationInput) throws -> CalculationOutput
}
```

구현 내부 순서 **고정** (테스트가 순서 의존 가정):

1. `preflight` — 필수 FX·시가 누락 목록  
2. `replay` — CostBasisEngine  
3. `aggregate` — TaxAggregator  
4. `holdings` — 현재 스냅샷  
5. `verify` — Integrity  
6. `attach` — status, policy IDs, disclaimers  

---

## 3. 상태 머신 (프로젝트)

```text
empty → imported → matching → ready_to_calc
                ↘              ↓
                  calc_running → verified
                              → blocked (fix issues, re-calc after fix)
```

| 상태 | export | 보유 표시 |
|------|--------|-----------|
| ready_to_calc 이전 | 불가 | 가능(부분) |
| blocked | 불가 | 마지막 성공 스냅샷 or 재계산 결과 |
| verified | 가능 | 가능 |

---

## 4. 실패 처리

| 단계 | 실패 | 사용자 액션 |
|------|------|-------------|
| Import | 행/페이지 오류, 암호 PDF 실패 | 오류 표·비밀번호 재입력 |
| Import | 바이낸스 Spot only | 입출금 파일 추가 안내 |
| Match | 미매칭 | 수동 연결 |
| FX | 날짜 누락 | 수동 입력 / 자동 채우기 |
| Deemed | 시가 없음 | 시가 입력 |
| Verify | Critical | 이슈 목록 따라 수정 후 재계산 |

---

## 5. 멱등·결정성

- 동일 `CalculationInput` → 동일 `CalculationOutput` (시간 필드 제외).  
- `DeterminismChecker`: 엔진 2회 호출 비교 (Verify 단계).

---

## 6. 다음

[06-cost-basis-engine.md](./06-cost-basis-engine.md)
