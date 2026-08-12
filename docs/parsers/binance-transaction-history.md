# 바이낸스 — Transaction History 포맷 (실측)

| 항목 | 내용 |
|------|------|
| 실측일 | 2026-08-12 |
| 샘플 (로컬 only) | `docs/samples/raw/입출금 내역/바이낸스-…/Binance-Transaction-History-…csv` |
| 합성 샘플 (커밋용) | `docs/samples/synthetic/binance_transaction_history_sample.csv` |
| 파일 형식 | `.csv` UTF-8 (BOM) |
| 타임존 | 파일명 `(UTC+9)` 표기 |
| 성격 | **계정의 모든 잔고 변동 원장** |
| 받는 곳 | 지갑 → 거래 기록(Transaction History) → 기간 지정 후 내려받기 |

> User ID 포함 → git 커밋 금지.

---

## 1. 왜 이 파일이 필요한가

거래내역·입금내역·출금내역 3개로는 **잔고가 닫히지 않는다.**

실데이터에서 두 곳이 막혔다.

| 증상 | 실제 원인 |
|------|-----------|
| 매수 시점에 USDT 가 1 미만 부족 | 며칠 전 `Binance Convert` 로 그만큼의 USDT 유입 |
| 출금 시점에 BTC 가 dust 만큼 부족 | 그 전 `Binance Convert` 로 그만큼의 BTC 유입 |

리퍼럴 보상으로 받은 USDC 를 「코인 바꾸기」로 USDT·BTC 로 바꾼 것이었다.
(실제 수량은 개인정보라 적지 않는다 — `docs/samples/raw` 의 원본을 볼 것)
**그 기록은 거래내역·입금내역·출금내역 어디에도 없다.** 이 파일에만 있다.

이 파일을 넣으면 USDT·BTC 잔고가 한 번도 음수로 내려가지 않고 소수점까지 0 으로 닫힌다.

---

## 2. 파일 구조

```text
행1: User ID,Time,Account,Operation,Coin,Change,Remark
행2~: 데이터
```

| 헤더 | 의미 |
|------|------|
| `Time` | 시각 (파일명 타임존 적용) |
| `Account` | 지갑 구분 (Spot / Funding …) |
| `Operation` | 변동 종류 (아래) |
| `Coin` | 자산 |
| `Change` | 증감 (유입 +, 유출 −) |
| `Remark` | 비고. 출금은 `Withdraw fee is included` |

---

## 3. Operation 매핑

실측 분포 (약 390행):

| Operation | 건수 | Ledger type | 비고 |
|-----------|------|-------------|------|
| `Transaction Buy` | 105 | **제외** | Spot 거래내역과 같은 거래 |
| `Transaction Spend` | 105 | **제외** | 〃 |
| `Transaction Fee` | 110 | **제외** | 〃 |
| `Transaction Sold` | 5 | **제외** | 〃 |
| `Transaction Revenue` | 5 | **제외** | 〃 |
| `Deposit` | 14 | `deposit` | |
| `Withdraw` | 7 | `withdrawal` | `Change` 가 수수료 합산 총액 → `quantityIsNetOfFee = true` |
| `Referral Commission` | 32 | `income` | 취득가 0원 (V-COST-01) |
| `Binance Convert` | 8 | `buy` (2행 → 1건) | 아래 §4 |

보상 계열은 같은 취급(`income`)으로 함께 인식한다: `Commission Rebate`, `Distribution`,
`Airdrop Assets`, `Simple Earn Flexible Interest`, `Simple Earn Locked Rewards`,
`Staking Rewards`, `Cashback Voucher`, `Card Cashback`, `Launchpool Interest`.

계정 안 지갑 이동은 `transferInternal` (총원가·수량 불변).

**모르는 `Operation` 은 제외하고 경고를 남긴다.** 조용히 버리면 잔고가 안 닫히고,
그 결과가 엉뚱한 곳에서 「보유보다 많이 썼다」로 터진다.

### 매매 행을 왜 버리는가

Spot 거래내역과 **같은 거래**다 — 실측에서 매수 105건·매도 5건이 시각까지 정확히 겹치고
한쪽에만 있는 건은 0건이다. 둘 다 읽으면 거래가 두 배로 잡혀 세액이 완전히 틀어진다.
체결 가격(`Price`)은 Spot 파일에만 있으므로 매매는 그쪽에서 읽는다.

**역할 분담: 거래내역 = Spot Trade History · 입출금·보상·Convert = 이 파일.**

---

## 4. 코인 바꾸기(Binance Convert) 짝짓기

두 행으로 찍힌다 — 내보낸 코인(−)과 받은 코인(+).

```text
2026-01-05 13:00:01  Binance Convert  USDT   2.49   ← 받은 것
2026-01-05 13:00:02  Binance Convert  USDC  -2.50   ← 내보낸 것
```
(합성 예시. 실측 값은 개인정보라 적지 않는다)

시간차는 같은 초 ~ 31초(실측). 순서는 (+,−) 도 (−,+) 도 나온다.

부호가 반대이고 자산이 다르며 **120초 이내**인 가장 이른 줄과 짝지어 `buy` 한 건으로 만든다
(base = 받은 코인, quote = 내보낸 코인). 한 건으로 묶어야 엔진이 견적자산 leg 을 처리해
**내보낸 코인을 처분하고 받은 코인에 원가를 얹는다.** 따로 두면 내보낸 쪽 취득원가가
사라지고 받은 쪽이 취득가 0원이 된다.

짝을 못 찾으면 받은 것은 `income`(취득가 0), 내보낸 것은 `withdrawal`(원가 소멸)로 두고
경고한다 — 둘 다 세금이 커지는 쪽이고, 무엇보다 **잔고는 맞는다.**

---

## 5. 파서 ID · detect

```text
id: binance-transaction-history-csv-v1
detect:
  - 파일명 "transaction-history" / "transaction history"  → 0.96 (헤더까지 맞으면)
  - 헤더에 Operation + Change + Coin + Account + User ID  → 0.90
```

`Operation` 열은 바이낸스 파일 중 이 파일에만 있어 다른 프리셋과 겹치지 않는다.

---

## 6. 예전 입금/출금 내역과 같이 넣으면 안 된다

**같은 입출금을 다르게 적는다.**

| | 입금내역 / 출금내역 | Transaction History |
|---|---|---|
| 입금 시각 | 입금 감지 시각 | 잔고 반영 시각 — 실측 **20초** 차 |
| 출금 시각 | 출금 요청 시각 | 잔고 반영 시각 — 실측 **26분** 차 |
| 출금 금액 | `Amount` 와 `Fee` 가 **따로** | `Change` 하나에 **합산** |

시각·금액이 달라 내용 기준 중복 제거(`Fingerprint.contentKey`)에 걸리지 않는다.
셋 다 넣으면 입출금이 두 번 잡혀 보유 수량과 취득원가가 부풀고 세액이 크게 틀어진다.

→ 검증기 **V-IMP-05** 가 Critical 로 막는다. 가져오기 화면에서도 붉게 알린다.

---

## 7. 보안

User ID·실잔고 raw 커밋 금지.
