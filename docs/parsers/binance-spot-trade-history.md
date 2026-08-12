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
| F | `Price` | 체결가 (quote/base) | `80000.00` |
| G | `Amount` | **base 수량** | `0.00100` |
| H | `Total` | **quote 대금** (≈ Price×Amount) | `80.0000000` |
| I | `Fee` | 수수료 수량 | `0.00010000` |
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

## 2.9 변형 B — 거래내역 화면 CSV (실측 2026-08-12)

바이낸스는 **두 가지 다른 포맷**을 내려준다. 위 §1 은 리포트센터 XLSX 이고,
거래내역 화면에서 바로 내려받으면 컬럼이 완전히 다르다.

```text
Time,Pair,Side,Price,Executed,Amount,Fee
2026-01-02 18:31:37,XAUTUSDT,BUY,4000.00,0.1234XAUT,493.60000000USDT,0.0006100BNB,,,
```

| 헤더 | 의미 | 주의 |
|------|------|------|
| `Time` | 체결 시각 | **타임존이 컬럼명에 없다.** 파일명 `…(UTC+9)…` 에만 있다 |
| `Pair` | 마켓 | **구분자 없음** (`XAUTUSDT`) → 쪼개는 위치가 모호하다 |
| `Side` | `BUY` / `SELL` | |
| `Price` | 체결가 | 단위 없음 |
| `Executed` | base 수량 **+ 단위** | `0.1234XAUT` |
| `Amount` | quote 대금 **+ 단위** | `493.6USDT` |
| `Fee` | 수수료 **+ 단위** | `0.0006100BNB` |

행 끝에 빈 필드가 몇 개 더 붙는다. 줄바꿈은 **CRLF**.

### 파서 규칙

1. base/quote 심볼은 `Pair` 를 추측해 쪼개지 않고 **`Executed`/`Amount` 의 단위 접미사**에서 얻는다.
   (`ADAUSDT` 처럼 어디서 갈라지는지 알 수 없는 쌍에서 안전하다.)
2. 시각은 **파일명의 `(UTC±H)`** 로 해석한다. UTC 로 단정하면 최대 하루가 밀려
   환율 적용일과 과세연도 귀속(2027-01-01 00:00 KST 경계)이 틀어진다.
3. `Executed` 는 수수료 차감 **전** 체결 수량 → `quantityIsNetOfFee = false`.

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
2025-12-25 14:00:15,BTC/USDT,BTC,USDT,BUY,80000.00,0.00100,80.00000,0.0001,BNB
```

---

## 5. 공백 / 추가 export 필요

| 데이터 | 이 파일 | 필요 |
|--------|---------|------|
| 현물 체결 | ✅ | |
| 출금 | ❌ (이 파일) | [binance-withdraw-history.md](./binance-withdraw-history.md) ✅ 실측 |
| 입금 | ❌ (이 파일) | [binance-deposit-history.md](./binance-deposit-history.md) ✅ 실측 |
| 내부 이체 | ❌ | 별도 |

전송 매칭(빗썸↔바이낸스)을 하려면 **Deposit·Withdraw History 파일을 함께 import** 해야 한다 (둘 다 실측·파서 구현 완료).
