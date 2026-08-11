# 10. 정합성 엔진 (설계 요약)

| 버전 | 1.0 |
|------|-----|
| 전문 | [../06-integrity.md](../06-integrity.md) |

---

## 1. 아키 위치

```text
CostBasisEngine  ──┐
TaxAggregator    ──┼──► IntegrityFacade.verify(output, input, policies)
HoldingsSnapshot ──┘              │
                                  ▼
                         VerificationReport
```

- Verifier는 **별 모듈** (`Domain/Integrity`).  
- 엔진 내부 메서드를 “믿기만” 하지 않고, 공개 결과 + 이벤트로 재검사.

---

## 2. 파이프라인 계약

```swift
func run(...) -> CalculationOutput {
    let raw = calculate(...)
    let report = verifier.verify(raw, input)
    var summary = raw.summary
    summary.status = report.status.toSummaryStatus()
    summary.verification = report
    // export gate reads summary.status
    return ...
}
```

`critical` ≥ 1 → `blocked`, export API throws/`false`.

---

## 3. 정책 인식 검증

전송 정책 ID에 따라 기대 불변식이 달라짐 → [04-policies.md](./04-policies.md) §2.5.

고지 문구 누락도 warning (abandon 정책인데 disclaimer 없으면).

---

## 4. 다음

[11-persistence.md](./11-persistence.md)
