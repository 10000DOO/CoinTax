# OKX — Funding History 포맷 (실측)

| 항목 | 내용 |
|------|------|
| 실측일 | 2026-08-11 |
| 샘플 (로컬 only) | `docs/samples/raw/OKX Funding History_…_1.csv` |
| 파일 형식 | **`.csv`** UTF-8 |
| 특수 | **1행 메타**, **2행 헤더** (Trading History와 동일 패턴) |
| 타임존 | 메타 `Time Zone:UTC+8` 등 |
| 성격 | **펀딩 계정** 입출금·내부 이동 (거래 체결 아님) |

> UID 등 식별자 포함 → git 커밋 금지.

---

## 1. 파일 구조

```text
행1: UID:…,Account Type:Main,Time Zone:UTC+8
행2: id,Time,Type,Amount,Before Balance,After Balance,Symbol
행3~: 데이터
```

`DictReader`는 **1행 skip 후** 헤더 사용.

---

## 2. 컬럼

| 헤더 | 의미 |
|------|------|
| `id` | 행 ID → externalID |
| `Time` | 시각 (메타 TZ 적용) |
| `Type` | 이벤트 종류 (아래) |
| `Amount` | 증감 (입금 +, 출금 **음수**) |
| `Before Balance` | 이전 잔고 |
| `After Balance` | 이후 잔고 |
| `Symbol` | 자산 (USDT, BTC, TRX …) |

실측 Type 값:

| Type | 대략 의미 | Ledger type (v1) |
|------|-----------|-------------------|
| `Deposit` | 외부→펀딩 입금 | `deposit` |
| `Withdrawal` | 펀딩→외부 출금 | `withdrawal` |
| `Received` | 수신(입금 계열) | `deposit` (세부 구분은 memo) |
| `From unified trading account` | 트레이딩→펀딩 | `transferInternal` (입금 쪽) |
| `To unified trading account` | 펀딩→트레이딩 | `transferInternal` (출금 쪽) |
| `Fee rebate` | 수수료 리베이트 | `income` (기타; 세금 태그 분리) |

실측 분포 예: Deposit / Withdrawal / 내부 이동 / Fee rebate / Received.

---

## 3. 정규화 규칙

```text
qty = abs(Amount)  또는 Amount 부호 유지 후 규약 적용
asset = Symbol
timestamp = Time + meta timezone
```

| Type | quantity 부호 규약 |
|------|-------------------|
| Deposit, Received, From unified… | 보유 + |
| Withdrawal, To unified… | 보유 − |
| Fee rebate | + (income) |

- Withdrawal: Amount가 이미 음수 (`-1.635673`) → abs로 qty, type=withdrawal.  
- **외부 브릿지 매칭** 후보: 주로 `Deposit` / `Withdrawal` (및 필요 시 `Received`).  
- `From/To unified trading account`: **거래소 내부** 펀딩↔통합거래 이동.  
  - 빗썸↔OKX 매칭에 쓰지 않음.  
  - 원장에서는 계정 내 지갑 이동으로 원가 이전(같은 사용자 OKX 계정).

### Trading History와의 관계

| 파일 | 역할 |
|------|------|
| **Trading History** | Spot 체결 + Transfer(거래 화면 쪽 이동) |
| **Funding History** | 펀딩 지갑 Deposit/Withdrawal + 트레이딩↔펀딩 |

둘 다 import. 동일 이동이 양쪽에 비슷하게 찍히면 **dedupe / 링크** 필요할 수 있음 (시간·수량·자산으로 검증).

---

## 4. 파서 ID · detect

```text
id: okx-funding-history-csv-v1
detect:
  - 파일명 "Funding History"
  - 1행 메타 Time Zone
  - 2행 헤더 id,Time,Type,Amount,Before Balance,After Balance,Symbol
  - Type 값에 Deposit/Withdrawal
```

Trading History 파서(`Balance Change` 등)와 **명확히 분리**.

---

## 5. 합성 예시 (커밋용)

```csv
UID:000,Account Type:Main,Time Zone:UTC+8
id,Time,Type,Amount,Before Balance,After Balance,Symbol
1,2025-12-28 18:26:32,Withdrawal,-1.5,1.5,0,USDT
2,2025-12-25 13:59:10,Deposit,200,0,200,USDT
3,2025-11-29 08:25:29,To unified trading account,-100,100,0,USDT
4,2025-11-29 08:26:00,From unified trading account,100,0,100,USDT
```

---

## 6. 보안

UID·실잔고 raw 커밋 금지.
