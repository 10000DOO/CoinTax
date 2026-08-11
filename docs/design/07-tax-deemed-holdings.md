# 07. 의제 취득가 · 세금 · 보유

| 버전 | 1.0 |
|------|-----|

---

## 1. 의제 취득가 (이력 자동)

### 1.1 목표

사용자가 **과거 전 거래**를 올리면:

```text
2026-12-31(KST) 스냅샷 보유에 대해
  deemedUnit = max(bookUnitCost, marketUnitPrice)
2027-01-01 이후 원장을 deemed 기준으로 재기동
```

### 1.2 알고리즘

```text
1. events를 시간순 정렬
2. t < T_deemed_end 구간만 재생 → snapshot S (account×asset: qty, totalCost)
3. for each position in S where qty > 0:
     market = prices[asset]  // 없으면 mark missing
     bookUnit = totalCost / qty
     deemedUnit = max(bookUnit, market)
     record DeemedPosition(book, market, deemed, reason)
4. books 리셋 후 acquire(qty, deemedUnit * qty) for each position
5. t >= T_tax_start 이벤트 계속 재생 (의제 전 구간 처분은 과세 집계 제외 정책)
```

| 시각 | 의미 |
|------|------|
| T_deemed_end | 2026-12-31 24:00 KST (구현 시 타임존 고정) |
| T_tax_start | 2027-01-01 00:00 KST |

### 1.3 시가 입력

- 자동 조회(선택) 또는 사용자 테이블: `asset, priceKRW, asOf`  
- 누락 자산 + 수량>0 → 계산 `blocked` (기본).  
- **실제 취득가는 수동 표가 아님** — 재생 결과만 사용.

### 1.4 UI 표시

| 자산 | 수량 | 실제 평단 | 시가 | 채택 평단 | 사유 |
|------|------|-----------|------|-----------|------|
| BTC | … | … | … | … | market / actual |

---

## 2. 세금 집계 (`TaxAggregator`)

### 2.1 입력

- `DisposalRecord` 중 `timestamp >= taxStart` 및 `taxYear` 일치  
- 정책상 허용된 `deductibleExpense` (전송 정책 v1 = 0)  
- `TaxRatePolicy`

### 2.2 공식

```text
income = Σ (proceedsKRW − costKRW − sellFeesKRW) + Σ otherDeductible? 
         // v1: otherDeductible from transfer policy usually 0

taxBase = max(0, income − basicDeduction)
national = taxBase × 0.20
local    = taxBase × 0.02
total    = national + local
```

반올림은 `RoundingPolicy` 1회 적용 후 Verifier 동일.

### 2.3 TaxYearSummary 필드

- 총수입, 필요경비, 소득, 공제, 과세표준, 국세, 지방세, 합계  
- disposals[]  
- abandonedTransferCostKRW (참고, 공제 아님)  
- policyBundleID, disclaimers[]  
- status: draft / verified / blocked  

---

## 3. 보유 현황 (`HoldingsSnapshot`)

원가 엔진 **최종 books**에서 생성 (세금 경로와 동일).

| 행 | 필드 |
|----|------|
| 합산 | asset, qty, avgKRW, totalCostKRW |
| 계정별 | account, asset, qty, avgKRW, method |

**평단가 표시 통화: KRW** (요구).  
USDT 수량 보유 시 평단도 KRW/USDT.

미실현 평가액(시가×수량)은 Should (선택 시가 있을 때).

---

## 4. 고지 필수 노출

1. 세무 자문 아님  
2. 전송 소실 원가 고지 (`TaxCopy.transferCostDisclaimer`)  
3. USDT=USD 가정  
4. 원가법: 계정별 MA/FIFO  
5. 의제 기준일·시가 출처  

---

## 5. 다음

[08-fx-service.md](./08-fx-service.md)
