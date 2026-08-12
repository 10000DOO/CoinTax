# 04. 정책 플러그인 (교체 용이 설계)

| 버전 | 1.0 |
|------|-----|
| 목적 | 세법 해석·고시 변경 시 **엔진 본체를 갈아엎지 않고** 정책 구현체만 교체 |

---

## 1. PolicyBundle

```swift
// 실제 구현: Domain/Policies/PolicyBundle.swift
// 프로토콜 존재 타입을 직접 담으므로 Codable 이 아니다. 감사 추적은 각 policy 의 `id` 문자열로 한다.
struct PolicyBundle: Sendable {
    var id: String                          // e.g. "cointax-v1.0"
    var transferCost: any TransferCostPolicy
    var costMethodResolver: any CostMethodResolver
    var deemed: any DeemedCostPolicy
    var taxRate: any TaxRatePolicy
    var rounding: any RoundingPolicy
    var fxAssumption: any FXAssumptionPolicy
    /// 사용자·리포트 노출용 한국어 고지 (정책별)
    var disclaimers: [String]
}

extension PolicyBundle {
    /// 제품 기본(잠금값). 세법 확정 시 여기(또는 새 bundle id)만 바꾸면 전 파이프라인 반영.
    static var v1Default: PolicyBundle { ... }

    /// 사용자 설정을 반영한 **현재** 번들. 화면·계산 파이프라인 모두 이것만 읽는다.
    /// 정책 사본을 여러 곳에서 들고 있으면 설정 변경이 한쪽에만 반영돼 표시와 계산이 어긋난다.
    /// 기본값이 아닌 선택은 id 에 표시한다 — 예: `cointax-v1.0+deemed_perLot`
    static var current: PolicyBundle { ... }
}
```

> **단일 출처 규칙**: 정책 번들은 `PolicyBundle.current` 에서만 만든다.
> `AppEnvironment.policies` 는 저장 프로퍼티가 아니라 계산 프로퍼티이고,
> `CalculationPipeline` 은 사본을 들지 않는다(테스트 고정용 `policiesOverride` 만 예외).

**교체 절차 (운영)**

1. 새 `TransferCostPolicy` 구현 추가 (기존 구현 삭제하지 않음)  
2. 단위 테스트·골든 fixture 추가  
3. `PolicyBundle.v1Default` 또는 `v1_1` 로 default 변경  
4. 리포트 고지 문구 배열 갱신  
5. Verifier의 정책 대응 불변식 갱신  

UI에 “실험적 정책 선택”을 넣을 필요는 v1에 없음. **코드 한곳 + 테스트**로 충분.

---

## 2. TransferCostPolicy ★

### 2.1 문제

전송 시 출고 수량 > 입고 수량(네트워크/출금 수수료 소실)일 때  
소실 분 원가를 어디로 보낼지 **공개 세법 해설이 없음**.

### 2.2 프로토콜

```swift
protocol TransferCostPolicy: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// 리포트·설정·export 하단 고정 고지
    var userDisclaimerKO: String { get }

    func apply(
        outboundCostKRW: Decimal,   // 출고 전체에 배분된 장부 원가
        withdrawnQty: Decimal,
        receivedQty: Decimal,
        explicitFeeCostKRW: Decimal // 별도 fee 행으로 잡힌 금액(있으면)
    ) -> TransferCostResult
}

struct TransferCostResult: Equatable {
    var transferredCostKRW: Decimal  // 도착 계정 입고 원가
    var abandonedCostKRW: Decimal    // 장부 소멸, 공제 여부 정책에 따름
    var deductibleExpenseKRW: Decimal // 필요경비로 인식할 금액 (v1 기본 0)
    var notes: String
}
```

### 2.3 v1 기본 구현: `AbandonLostCostPolicy`

```text
ratio = receivedQty / withdrawnQty   (withdrawnQty > 0)
transferredCost = outboundCost × ratio
abandonedCost   = outboundCost − transferredCost
                  + explicitFeeCostKRW
deductibleExpense = 0
```

**사용자 고지 (확정 문구):**

> 전송 소실 원가는 공개 세법 해설이 없어, 과다 공제를 피하기 위해 필요경비·도착 취득가에 넣지 않습니다. 세액이 다소 커질 수 있으며 세무 자문이 아닙니다.

이 문자열은:

- `AbandonLostCostPolicy.userDisclaimerKO`  
- `PolicyBundle.v1Default.disclaimers`  
- 리포트 화면·CSV/PDF 푸터  
- Settings → “세금 계산 가정”  

에 **동일 상수**로 연결 (복붙 분기 금지: `TaxCopy.transferCostDisclaimer`).

### 2.4 예약 구현 (아직 default 아님 — 교체 대비)

| ID | 동작 | 언제 쓸 수 있나 |
|----|------|----------------|
| `allocate_to_arrival` | 소실 원가를 입고 수량 단가에 안분 (`transferred = full outbound`) | 공식 해설이 “취득부대비용”으로 명시할 때 |
| `deduct_as_expense` | `deductibleExpense = abandoned` | 전송 관련 비용을 필요경비로 인정한다는 해설 시 |
| `abandon_lost_cost` | v1 기본 | 현재 |

```swift
// 예시: 이후 교체 한 줄
// PolicyBundle.v1Default.transferCost = .allocateToArrival
```

엔진(`TransferApplier`)은 **프로토콜만** 의존. switch 난립 금지.

### 2.5 Verifier 연동

| Policy id | 검증 |
|-----------|------|
| abandon | `deductible == 0`, 입고원가 ≈ outbound×ratio, abandoned 합이 세금 필요경비에 없음 |
| allocate | 입고원가 ≈ outbound 전체, abandoned == 0 |
| deduct | 필요경비에 abandoned 포함, 이중 공제 없음 |

정책 ID가 리포트와 불일치하면 Critical.

---

## 3. CostMethodResolver

```swift
protocol CostMethodResolver {
    var id: String { get }
    func method(for account: Account) -> CostBasisMethod
}

// v1: Bithumb → movingAverage; Binance/OKX/unknown overseas → fifo
```

법령이 총평균 등으로 바뀌면 새 Resolver + Book 구현.

---

## 4. DeemedCostPolicy

```swift
protocol DeemedCostPolicy {
    var id: String { get }
    var asOf: Date { get }  // 2026-12-31 end KST
    func deemedUnit(bookUnit: Decimal, marketUnit: Decimal?) -> Decimal?
    // market nil → nil (확정 불가)
}
// v1: max(book, market)
```

---

## 5. TaxRatePolicy

```swift
struct TaxRatePolicyV1 {
    var basicDeduction: Decimal // 2_500_000
    var nationalRate: Decimal   // 0.20
    var localRate: Decimal      // 0.02
    var taxStart: Date          // 2027-01-01
}
```

---

## 6. RoundingPolicy

엔진과 Verifier가 **동일 인스턴스** 사용.

| 대상 | v1 초안 |
|------|---------|
| KRW 금액 저장 | 소수점 유지 가능, 표시·세액 시 원 단위 |
| 세액 | 원 미만 반올림 방식 1종 고정 후 테스트 |

---

## 7. FXAssumptionPolicy

```swift
// v1: USD-pegged stables (USDT/USDC/USD) treated as USD 1:1; convert via USD/KRW official rate
// 대상 판정은 `AssetSymbol.isUSDPegged` 한 곳에서만 한다 — 페그 없는 코인은 넣지 않는다
var treatUSDTAsUSD: Bool // true
```

고지: “USDT=USD 페그 가정”.

---

## 8. 감사 필드

모든 `TaxYearSummary` / export:

```text
policyBundleID=cointax-v1.0
transferCostPolicy=abandon_lost_cost
costMethodResolver=vasp_ma_else_fifo
deemedPolicy=max_book_market_2026-12-31
```

---

## 9. 다음

[05-pipelines.md](./05-pipelines.md)
