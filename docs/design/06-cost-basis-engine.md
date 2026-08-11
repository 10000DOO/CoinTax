# 06. 원가 엔진 상세

| 버전 | 2.0 |
|------|-----|
| 전체 루프 정본 | [14-implementation-spec.md](./14-implementation-spec.md) §5 |

---

## 1. 책임

시간순 `LedgerEvent` + confirmed `TransferLink` + `PolicyBundle`을 입력으로:

- 계정×자산 장부 갱신  
- 매도 시 `DisposalRecord` 생성  
- 전송 시 원가 이전 (`TransferCostPolicy`)  
- 중간·최종 `Holdings` 산출  

**하지 않는 일:** 세율 적용, 기본공제, UI, 영속화.

---

## 2. Book 인터페이스

```swift
protocol AssetBook {
    var method: CostBasisMethod { get }
    var quantity: Decimal { get }
    var totalCostKRW: Decimal { get }
    var averageUnitCostKRW: Decimal { get }  // qty==0 → 0

    mutating func acquire(qty: Decimal, costKRW: Decimal)
    mutating func dispose(qty: Decimal) throws -> (costKRW: Decimal)
    // dispose qty > 0 means reduce holdings by qty
}
```

### 2.1 MovingAverageBook (빗썸)

```text
acquire: totalCost += cost; qty += q; 
dispose: unit = totalCost/qty; costOut = unit * q; totalCost -= costOut; qty -= q
```

### 2.2 FIFOBook (바이낸스·OKX)

```text
lots: [(qty, unitCost)]
acquire: append lot
dispose: consume oldest lots until q filled; sum costOut
```

---

## 3. 엔진 루프

```text
books: [AccountID: [Asset: AssetBook]]
disposals: []
abandonedTotal = 0

for event in events.sorted(by: time):
  if event.timestamp crosses deemedBoundary:
      applyDeemed(books, prices, policy)   // see 07
  switch event.type:
    buy/income/deposit(unlinked): acquire with cost from KRW/FX
    sell: dispose → DisposalRecord
    withdrawal:
      if has confirmed link:
         costOut = dispose(full withdrawn qty)
         result = transferPolicy.apply(...)
         remote.acquire(receivedQty, result.transferredCost)
         abandonedTotal += result.abandoned
         // deductible from policy if any → tag for tax aggregator
      else:
         // treat as external out: dispose cost; no transfer (or hold as unmatched warning)
    ...
```

**매수 원가(KRW)**

1. `quoteAmountKRW` 있으면 사용 + 매수 수수료  
2. 없으면 qty × price × FX(USDT→KRW 등)

**매도 양도가(KRW)**

- 동일 규칙. 매도 수수료는 proceeds에서 차감 또는 필요경비 (정책상 동일 효과, 한 길로 고정).

---

## 4. 전송 적용 (`TransferApplier`)

```swift
struct TransferApplier {
    let policy: TransferCostPolicy
    func apply(link: TransferLink, outboundCost: Decimal) -> TransferCostResult
}
```

- 엔진은 결과의 `transferredCostKRW`만 입고.  
- `deductibleExpenseKRW`는 disposal이 아니라 **연간 필요경비 기타 항목**으로 TaxAggregator에 넘김 (v1 기본 0).  
- `abandonedCostKRW`는 메트릭·리포트 참고 전용.

---

## 5. 오류

| 상황 | 동작 |
|------|------|
| 매도 수량 > 보유 | throw → Verify Critical 경로 |
| 0 나누기 | qty==0 acquire/dispose 가드 |
| 미확인 전송 대량 | 경고; 정책에 따라 계산 계속 or block |

---

## 6. 테스트 포인트

- MA: 2회 매수 후 1회 매도 평단  
- FIFO: lot 소진 순서  
- Transfer abandon: 10 out / 9 in → transferred 90%  
- Transfer allocate (미래 정책): transferred 100%  
- 정책 교체 시 동일 이벤트 다른 결과 스냅샷

---

## 7. 다음

[07-tax-deemed-holdings.md](./07-tax-deemed-holdings.md)
