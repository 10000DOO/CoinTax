# 바이낸스 — Spot Trade History 포맷 (실측)

| 항목 | 내용 |
|------|------|
| 실측일 | 2026-08-11 |
| 샘플 (로컬 only) | `docs/samples/raw/Binance-Spot Trade History-202602050001.xlsx` |
| 파일 형식 | **`.xlsx`** (CSV 아님) |
| 시트 | `sheet1` 단일 |
| 셀 타입 | 전부 `inlineStr` (문자열) |
| 타임존 | 컬럼명 `Date(UTC)` → **UTC** |

> 실파일은 git 커밋 금지. 아래는 스키마·합성 예시만.

---

## 1. 컬럼 (헤더 행 1)

| # | 헤더 | 의미 | 예 |
|---|------|------|-----|
| A | `Date(UTC)` | 체결 시각 UTC | `2025-12-25 14:00:15` |
| B | `Pair` | 마켓 | `BTC/USDT` |
| C | `Base Asset` | 기초 자산 | `BTC` |
| D | `Quote Asset` | 견적 자산 | `USDT` |
| E | `Type` | 방향 | `BUY` / `SELL` |
| F | `Price` | 체결가 (quote/base) | `87622.38` |
| G | `Amount` | **base 수량** | `0.00236` |
| H | `Total` | **quote 대금** (≈ Price×Amount) | `206.7888168` |
| I | `Fee` | 수수료 수량 | `0.00018534` |
| J | `Fee Coin` | 수수료 자산 | `BNB` 또는 base |

샘플에 **입출금/전송 행 없음** — 현물 체결만.

---

## 2. 정규화 매핑 → LedgerEvent

| LedgerEvent | 소스 |
|-------------|------|
| timestamp | `Date(UTC)` parse as UTC |
| type | `BUY`→`buy`, `SELL`→`sell` |
| baseAsset | `Base Asset` |
| quoteAsset | `Quote Asset` |
| quantity | `Amount` (buy +, sell − 규약 적용) |
| price | `Price` |
| quoteAmount | `Total` |
| feeAmount / feeAsset | `Fee` / `Fee Coin` |
| externalID | 파일에 **주문 ID 없음** → fingerprint: time+pair+type+amount+total+fee |

### 수수료 처리

- `Fee Coin == Base` → base 순취득 감소 가능  
- `Fee Coin == BNB` 등 제3자산 → 별도 fee 이벤트 또는 BNB 장부 차감 (엔진 정책: 취득 시 원가에 quote 환산 또는 BNB lot 소모)

---

## 3. 파서 구현 메모

- 확장자: `.xlsx` 우선. (CSV export 변형이 있으면 detect 분기)
- 의존: 시스템 `TabularData` / 경량 ZIP+XML / 또는 패키지 — **v1은 Foundation ZIP XML로 충분** (의존 최소화)
- 헤더 고정 문자열로 `detect`: `Date(UTC)`, `Base Asset`, `Fee Coin`
- 선물 파일과 분리: 파일명 `Spot Trade History` + 위 헤더

---

## 4. 합성 예시 (커밋용)

```text
Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
2025-12-25 14:00:15,BTC/USDT,BTC,USDT,BUY,87622.38,0.00236,206.7888168,0.00018534,BNB
```

---

## 5. 공백 / 추가 export 필요

| 데이터 | 이 파일 | 필요 |
|--------|---------|------|
| 현물 체결 | ✅ | |
| 출금 | ❌ (이 파일) | [binance-withdraw-history.md](./binance-withdraw-history.md) ✅ 실측 |
| 입금 | ❌ | **Deposit History** 아직 미수집 |
| 내부 이체 | ❌ | 별도 |

전송 매칭(빗썸↔바이낸스)을 하려면 **출금·입금 CSV를 추가 수집**해야 한다.
