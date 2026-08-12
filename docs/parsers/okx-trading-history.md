# OKX — Trading History 포맷 (실측)

| 항목 | 내용 |
|------|------|
| 실측일 | 2026-08-11 |
| 샘플 (로컬 only) | `docs/samples/raw/OKX Trading History_…_1.csv` |
| 파일 형식 | **`.csv`** UTF-8 |
| 특수 | **1행 메타데이터**, **2행 헤더**, 3행~ 데이터 |
| 타임존 | 메타 `Time Zone:UTC+8` (파일마다 다를 수 있음) |

> 실파일에 **UID 등 식별자** 포함 → git 커밋 금지. 문서에는 스키마만.

---

## 1. 파일 구조

```text
행1: UID:…,Account Type:Main,Time Zone:UTC+8
행2: id,Order id,Time,Trade Type,Symbol,Action,...
행3~: 데이터
```

- `csv.DictReader`를 **1행부터** 돌리면 깨짐 → **skip 1줄 후** 헤더 사용.
- 메타 파싱: `Time Zone` → 이벤트 시각 해석에 사용.

---

## 2. 컬럼 (헤더 행)

| 헤더 | 의미 | 비고 |
|------|------|------|
| `id` | 행 고유 ID | externalID 후보 |
| `Order id` | 주문/이체 ID | Spot 체결 묶음 키 |
| `Time` | 시각 | 메타 Time Zone 적용 |
| `Trade Type` | `Spot` / `Transfer` 등 | 선물 타입 있으면 v1 ignore |
| `Symbol` | `BTC-USDT` | Transfer는 빈 값 |
| `Action` | `Buy` `Sell` `Transfer in` `Transfer out` | |
| `Amount` | 수량 필드 | **Transfer는 0인 경우 많음** |
| `Trading Unit` | 단위 힌트 | Transfer 시 `cont` 등 |
| `Filled Price` | 체결가 | Transfer 0 |
| `PnL` | | Spot 샘플은 0 |
| `Fee` | 수수료 (부호 있는 경우 있음, 음수=차감) | |
| `Fee Unit` | 수수료 자산 | |
| `Position Change` | | 샘플 0 |
| `Position Balance` | | 샘플 0 |
| `Balance Change` | **잔고 증감** | Transfer·정규화에 핵심 |
| `Balance` | 거래 후 잔고 | |
| `Balance Unit` | 잔고 자산 | |

실측 분포 예: Spot 28 / Transfer 24, Action Buy·Sell·Transfer in·out.

---

## 3. 행 유형별 해석

### 3.1 Spot (`Trade Type=Spot`)

한 **Order id**에 **여러 행**이 붙는다 (base 유입 + quote 유출 등).

예 (개념):

| Action | Amount / Trading Unit | Balance Change / Unit | 의미 |
|--------|----------------------|------------------------|------|
| Buy | base 수량 / BTC | +base / BTC | BTC 매수 취득 |
| Sell | (큰 숫자) / BTC | −quote / USDT | USDT 지급 측 |

> ⚠️ **`Balance Change` 가 수수료 차감 전인지 후인지는 실측으로 확정되지 않았다.**
> 아래 §6 합성 예시의 숫자(0.01 − 0.00001 = 0.00999)는 문서 작성자가 만든 값이므로 관례의 근거가 될 수 없다.
> 파서는 `Amount`·`Fee`·`Balance Change` 세 값의 관계로 **런타임 판정**한다
> (`|Balance Change| ≈ Amount − Fee` → 순액 / `≈ Amount` → 총액 / 그 외 → 경고 후 총액 처리).
> 실파일로 확인되면 이 문서에 실측 결과를 적고 판정 로직을 단순화할 수 있다.

**파서 권장 (v1):**

1. `Order id`로 그룹.  
2. 각 행의 **`Balance Change` + `Balance Unit`** 을 우선 신뢰 (지갑 실변동).  
3. `Action=Buy` 이고 Balance Unit이 base면 → `buy` (base +).  
4. `Action=Sell` 이고 Balance Unit이 quote면 → quote 유출 (매수 대금).  
5. `Fee`/`Fee Unit`: 절댓값 수수료, 해당 자산 차감.  
6. `Filled Price` + base 수량으로 교차 검증.

동일 Order를 **하나의 buy/sell pair**로 합치거나, balance-leg 단위 이벤트로 넣되 **이중 계산 금지**.

### 3.2 Transfer (`Trade Type=Transfer`)

| Action | 정규화 |
|--------|--------|
| `Transfer in` | `transferInternal` (+) — 내부 이동 |
| `Transfer out` | `transferInternal` (−) — 내부 이동 |

- `Amount`가 0이어도 **`Balance Change` 절댓값 = 수량**.  
- 자산 = `Balance Unit` (또는 Fee Unit과 동일 계열).  
- `Symbol` 비어 있음.  
- 전송 매칭에는 **쓰지 않는다** (내부 이동). 국내↔해외 매칭은 Funding History 의 Deposit/Withdrawal 담당.

---

## 4. LedgerEvent 매핑 요약

| Trade Type + Action | type | quantity source | asset |
|---------------------|------|-----------------|-------|
| Spot + Buy (base leg) | buy | Balance Change 또는 Amount | Balance Unit / base |
| Spot + Sell (quote leg) | (buy의 대금 또는 sell) | Balance Change | quote |
| Transfer in | **transferInternal** (+) | abs(Balance Change) | Balance Unit |
| Transfer out | **transferInternal** (−) | abs(Balance Change) | Balance Unit |

> Trading History 의 Transfer 는 **거래 계정 ↔ 펀딩 계정 내부 이동**이다 (OKX 는 외부 입출금이 펀딩 지갑에서 일어난다).
> 외부 입출금은 Funding History 의 `Deposit`/`Withdrawal` 을 쓴다.
> Funding History 없이 Trading History 만 가져오면 **국내↔해외 전송이 누락**되므로 검증기가 `V-IMP-04` Critical 로 차단한다.

`externalID` = `id` (행) 또는 `Order id`+leg.

---

## 5. 파서 구현 메모

```text
detect:
  - 파일명 "OKX Trading History" 또는
  - 2행 헤더에 "Trade Type","Balance Change","Fee Unit"
parse:
  - 1행 메타 → timezone
  - DictReader from line 2
  - futures/swap Trade Type → ignored + count
```

---

## 6. 합성 예시 (커밋용, 식별자 가짜)

```csv
UID:000,Account Type:Main,Time Zone:UTC+8
id,Order id,Time,Trade Type,Symbol,Action,Amount,Trading Unit,Filled Price,PnL,Fee,Fee Unit,Position Change,Position Balance,Balance Change,Balance,Balance Unit
1,100,2025-11-29 08:25:29,Spot,BTC-USDT,Buy,0.01,BTC,90000,0,-0.00001,BTC,0,0,0.00999,0.00999,BTC
2,100,2025-11-29 08:25:29,Spot,BTC-USDT,Sell,900,BTC,90000,0,0,USDT,0,0,-900,100,USDT
3,200,2025-11-29 08:27:50,Transfer,,Transfer out,0,cont,0,0,0,BTC,0,0,-0.01,0,BTC
4,201,2025-11-29 09:00:00,Transfer,,Transfer in,0,cont,0,0,0,USDT,0,0,1000,1000,USDT
```

---

## 7. Funding History와의 관계

| 파일 | 역할 |
|------|------|
| **Trading History** (본 문서) | Spot 체결 + Transfer |
| **Funding History** | 펀딩 계정 Deposit/Withdrawal 등 → [okx-funding-history.md](./okx-funding-history.md) |

둘 다 import. 외부 입출금은 Funding의 Deposit/Withdrawal가 더 직접적일 수 있음.
