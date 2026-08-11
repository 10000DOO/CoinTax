# 03. 도메인 모델

| 버전 | 2.0 |
|------|-----|
| 필드 정본 | [14-implementation-spec.md](./14-implementation-spec.md) §1 |

---

## 1. 개념 관계

```text
Project
  ├── accounts: [Account]
  ├── sourceFiles: [SourceFile]
  ├── events: [LedgerEvent]
  ├── links: [TransferLink]
  ├── fxRates: [FXRate]
  ├── marketPrices: [MarketPrice]
  ├── lastPolicyBundleID
  ├── lastVerification: VerificationReport?
  └── lastSummary: TaxYearSummary?
```

---

## 2. 핵심 규칙

### 2.1 수량 부호 (잠금)

| type | quantity |
|------|----------|
| buy, deposit, income, fiatDeposit | `> 0` |
| sell, withdrawal, fiatWithdraw | `< 0` |
| transferInternal | 부호로 방향 (+ 유입 / − 유출) |
| fee | **quantity에 넣지 않음** — `feeAmount`/`feeAsset` 필드 사용 |

### 2.2 계정 기본 원가법

| exchange | method | venue |
|----------|--------|-------|
| bithumb | movingAverage | domestic |
| binance, okx | fifo | overseas |

### 2.3 불변

1. confirmed link만 전송 원가 이전  
2. ignored 제외  
3. 음수 재고 Critical  
4. verified 전 export 금지  
5. 확정 요약에 policyBundleID 필수  

### 2.4 KRW / FX

[../IMPLEMENTATION.md](../IMPLEMENTATION.md) §6.

---

## 3. 타입 목록

`Project`, `Account`, `SourceFile`, `LedgerEvent`, `TransferLink`, `FXRate`, `MarketPrice`, `DisposalRecord`, `DeemedPosition`, `HoldingsSnapshot`, `TaxYearSummary`, `VerificationReport`

**전체 프로퍼티 목록·Codable 스케치:** [14-implementation-spec.md](./14-implementation-spec.md) §1

---

## 4. 다음

[04-policies.md](./04-policies.md) · [14-implementation-spec.md](./14-implementation-spec.md)
