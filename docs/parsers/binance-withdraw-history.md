# 바이낸스 — Withdraw History Report 포맷 (실측)

| 항목 | 내용 |
|------|------|
| 실측일 | 2026-08-11 |
| 샘플 (로컬 only) | `docs/samples/raw/Binance-Withdraw-History-Report-2026-02-04.xlsx` |
| 파일 형식 | **`.xlsx`** (sheet1, `inlineStr`) |
| 성격 | **출금(Withdraw)** — 입금(Deposit) 아님 |
| 타임존 | 헤더 `Date(UTC+0)` → **UTC** |

> 주소·TXID 전문은 문서·git에 넣지 않음. 파서는 매칭용 **해시**만 선택 저장.

---

## 1. 컬럼 (헤더 행 1)

| # | 헤더 | 의미 | 예 (합성) |
|---|------|------|-----------|
| A | `Date(UTC+0)` | 출금 시각 UTC | `25-12-21 00:51:45` |
| B | `Coin` | 자산 | `BTC` |
| C | `Network` | 네트워크 | `BTC` |
| D | `Amount` | 출금 수량 (수수료 별도인 경우가 많음) | `0.020485` |
| E | `Fee` | 네트워크/출금 수수료 | `0.000015` |
| F | `Address` | 수신 주소 | (민감) |
| G | `TXID` | 온체인 해시 | (민감) |
| H | `Status` | 상태 | `Completed` |

실측 샘플: 데이터 3행, 모두 BTC / Completed.

### 1.1 날짜 형식 주의

- 값이 `YY-MM-DD HH:mm:ss` 형태 (`25-12-21 …`) — **연도 2자리**.  
- 파서: `20YY` 가정 또는 명시 포맷 `yy-MM-dd HH:mm:ss` (UTC).

---

## 2. 정규화 → LedgerEvent

| LedgerEvent | 소스 |
|-------------|------|
| timestamp | `Date(UTC+0)` → UTC |
| type | `withdrawal` (`Status`가 Completed만 기본 포함; 그 외 skip/warning) |
| baseAsset | `Coin` |
| quantity | `Amount` (출고 −) |
| feeAmount / feeAsset | `Fee` / `Coin` (동일 자산 수수료) |
| externalID | `TXID` (있으면) 또는 fingerprint |
| network | `Network` |
| addressHash | SHA256(Address) — 원문 미저장 권장 |
| memo | (없음) |

### 2.1 수량·수수료

- 지갑에서 빠지는 총량 ≈ `Amount + Fee` 인 경우가 흔함 (실측 Fee 별도 컬럼).  
- 원가 엔진:  
  - withdrawal qty = `Amount` (도착 측과 매칭되는 수량)  
  - fee qty = `Fee` → **전송 소실/수수료** 경로 (`TransferCostPolicy` / 보수 abandon과 정합)  
- 매칭 시: 빗썸·상대 입금 수량은 보통 **`Amount`(순출금)** 과 비교, Fee는 tolerance.

### 2.2 Status

| Status | v1 |
|--------|-----|
| `Completed` | 반영 |
| 그 외 (Pending, Failed 등) | ignore + warning |

---

## 3. Spot History와의 관계

| 파일 | 역할 |
|------|------|
| Spot Trade History | 현물 체결 buy/sell |
| **Withdraw History** | 거래소 → 외부 **출금** |
| Deposit History | 외부 → 거래소 **입금** (**아직 샘플 없음**) |

전송 매칭 예:

```text
빗썸 USDT/BTC 출금  ──?──►  바이낸스 Deposit   (입금 파일 필요)
바이낸스 Withdraw   ──?──►  개인지갑 / 타소 입금
빗썸 출금(바이낸스) ──match──► 바이낸스 Deposit   ← 브릿지 핵심
```

**국내→바이낸스 입금**을 잡으려면 **Deposit History** export가 추가로 필요하다.  
본 Withdraw 파일만으로는 “빗썸에서 보낸 코인이 바이낸스에 들어온 행”을 직접 증명할 수 없다 (반대 방향 출금만 있음).

---

## 4. 파서 ID · detect

```text
id: binance-withdraw-xlsx-v1
format: xlsx
detect: 헤더 Date(UTC+0), Coin, Network, Amount, Fee, Address, TXID, Status
파일명: Withdraw-History / Withdraw History
```

Spot 파서와 별도 등록. 한 계정에 Spot + Withdraw (+ 추후 Deposit) 다중 import.

---

## 5. 합성 fixture 예 (커밋용)

```text
Date(UTC+0),Coin,Network,Amount,Fee,Address,TXID,Status
25-12-21 00:51:45,BTC,BTC,0.02,0.000015,addr_example,txid_example,Completed
```

---

## 6. 보안

- Address/TXID 로그·git·export 기본 제외  
- raw xlsx gitignore  
