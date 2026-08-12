# 바이낸스 — Deposit History Report 포맷 (실측)

| 항목 | 내용 |
|------|------|
| 실측일 | 2026-08-11 |
| 샘플 (로컬 only) | `docs/samples/raw/Binance-Deposit-History-Report-2026-02-04.xlsx` |
| 파일 형식 | **`.xlsx`** (sheet1, `inlineStr`) |
| 성격 | **입금(Deposit)** |
| 타임존 | 헤더 `Date(UTC+0)` → **UTC** |

---

## 1. 컬럼 (헤더 행 1)

| # | 헤더 | 의미 | 예 (개념) |
|---|------|------|-----------|
| A | `Date(UTC+0)` | 입금 시각 UTC | `25-12-25 13:59:10` |
| B | `Coin` | 자산 | `USDT` |
| C | `Network` | 네트워크 | `TRX`, `PLASMA` 등 |
| D | `Amount` | 입금 수량 | `100.500000` |
| E | `Address` | 수신 주소 | (민감) |
| F | `TXID` | 온체인 해시 | (민감) |
| G | `Status` | 상태 | `Completed` |

### Withdraw와의 차이

| | Deposit | Withdraw |
|--|---------|----------|
| Fee 컬럼 | **없음** | 있음 |
| type | `deposit` | `withdrawal` |
| 헤더 날짜 | `Date(UTC+0)` 동일 계열 | 동일 |
| detect | Address+TXID+Status, **Fee 없음** | Fee 있음 |

### 날짜

- `yy-MM-dd HH:mm:ss` (연도 2자리) — Withdraw와 동일 주의.

실측 샘플: USDT 입금 7건, Network TRX 다수 + PLASMA 1, Status 전부 Completed.

---

## 1.9 변형 B — 입출금 화면 CSV (실측 2026-08-12)

```text
Time,Coin,Network,Amount,Address,TXID,Status
```

- 날짜 열 이름이 `Date(UTC+0)` 이 아니라 **`Time`** 이고, 타임존은 **파일명 `…(UTC+9)…`** 에만 있다.
- 줄바꿈은 **CRLF**.
- 파서는 `Date(UTC+0)` → `Date(UTC)` → `Time` 순으로 날짜 열을 찾고,
  열 이름에 타임존이 없으면 파일명에서, 그것도 없으면 UTC 로 두고 **경고**한다.

---

## 2. 정규화 → LedgerEvent

| LedgerEvent | 소스 |
|-------------|------|
| timestamp | `Date(UTC+0)` UTC |
| type | `deposit` (`Completed`만) |
| baseAsset | `Coin` |
| quantity | `Amount` (+) |
| externalID | `TXID` |
| network | `Network` |
| addressHash | SHA256(Address) 권장 |

전송 매칭: **빗썸 출금** ↔ **이 Deposit** (자산·수량·시간·네트워크).

---

## 3. 파서 ID

```text
id: binance-deposit-xlsx-v1
detect: Date(UTC+0), Coin, Network, Amount, Address, TXID, Status
         AND no Fee column (vs withdraw)
```

---

## 4. 보안

Address/TXID 원문 로그·git 금지. raw gitignore.
