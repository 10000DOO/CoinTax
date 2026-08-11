# CoinTax 구현 핸드북 (다른 세션용)

| 항목 | 내용 |
|------|------|
| 대상 | 이 문서 트리만 보고 앱을 **처음부터 구현**하는 에이전트/개발자 |
| 버전 | 1.0 |
| 일자 | 2026-08-11 |
| 플랫폼 | **macOS 15+**, Swift, SwiftUI, 로컬 개인 사용 |
| 금지 | 서버 백엔드, 선물/마진, App Store 배포(1차), 실거래 파일 git 커밋 |

---

## 0. 30초 제품 정의

국내(빗썸)에서 USDT 매수 → 해외(바이낸스/OKX) 전송 → 해외 현물 매매 → (현금화 시) 회수·국내 매도.  
원본 서류 import → 전송 매칭 → 원가·실현손익·의제취득가·예상 기타소득세.  
**Calculate → Verify 통과 전 export 금지.** 세무 자문 아님.

---

## 1. 읽기 순서 (필수)

구현 전 아래를 **이 순서**로 읽는다. 충돌 시 **아래 문서 우선순위**를 따른다.

| 우선 | 문서 | 역할 |
|------|------|------|
| 1 | 본 파일 `IMPLEMENTATION.md` | 잠긴 기본값·구현 계약 |
| 2 | [05-decisions.md](./05-decisions.md) | 제품 결정 |
| 3 | [04-import-formats.md](./04-import-formats.md) + [parsers/](./parsers/) | 원본 포맷 |
| 4 | [design/03-domain-model.md](./design/03-domain-model.md) | 타입 |
| 5 | [design/04-policies.md](./design/04-policies.md) | 플러그인 |
| 6 | [design/06-cost-basis-engine.md](./design/06-cost-basis-engine.md) + [07](./design/07-tax-deemed-holdings.md) | 원가·세금 |
| 7 | [design/09-import-and-matching.md](./design/09-import-and-matching.md) | Import·매칭 |
| 8 | [06-integrity.md](./06-integrity.md) | 검증 |
| 9 | [design/14-implementation-spec.md](./design/14-implementation-spec.md) | **알고리즘·고든·에러코드 상세** |
| 10 | [01-requirements.md](./01-requirements.md) §10 | MVP 수용 기준 |
| 11 | 나머지 design/* | UI·저장·로드맵 |

---

## 2. 잠긴 기본값 (구현 시 추측 금지)

| 키 | 값 |
|----|-----|
| deploymentTarget | macOS 15.0 |
| 언어 UI | 한국어 |
| 합산 통화 | KRW |
| 빗썸 원가법 | **이동평균** |
| 바이낸스·OKX 원가법 | **FIFO** |
| 전송 소실 원가 | **`abandon_lost_cost`**: 입고원가 = 출고원가×(입고수량/출고수량), 소실 분 **필요경비 미산입** |
| 전송 소실 고지 | 아래 §2.1 문구 **그대로** (`TaxCopy.transferCost`) |
| USDT | v1 **1 USDT = 1 USD**, 당일 **USD/KRW 기준환율** |
| 과세 시작 | 2027-01-01 00:00 **KST** |
| 의제 기준 | 2026-12-31 24:00 **KST** 스냅샷 후 `max(장부단가, 시가)` |
| 기본공제 | 2_500_000 KRW |
| 국세/지방 | 20% / 2% (과세표준 기준) |
| 선물 | import 시 **제외** + 건수 고지 |
| 빗썸 이자 원천징수 PDF | **거부** (거래내역 아님) |
| Decimal | `Decimal` / `NSDecimalNumber` only. Double 금지 |
| 네트워크 | 환율 **자동 조회 기본 ON**, 수동 입력은 옵션 (끄면 수동만) |
| 휴일·미고시 환율 | **직전 고시일** 기준환율 (`FXHolidayPolicy` / 서삼46015-11986 취지), `sourceDate` 기록 |
| 실원본 git | 금지 (`.gitignore` 준수) |

### 2.1 필수 고지 문자열

```text
// TaxCopy.notTaxAdvice
본 결과는 세무 자문이 아니며 예상 참고용입니다. 신고 전 전문가·국세청 안내를 확인하세요.

// TaxCopy.transferCost  — 변경 시 PolicyBundle id도 올릴 것
전송 소실 원가는 공개 세법 해설이 없어, 과다 공제를 피하기 위해 필요경비·도착 취득가에 넣지 않습니다. 세액이 다소 커질 수 있으며 세무 자문이 아닙니다.

// TaxCopy.usdtPeg
USDT는 USD 1:1로 가정한 뒤 해당일 USD/KRW 기준환율로 환산합니다.

// TaxCopy.costMethods
빗썸 계정은 이동평균법, 바이낸스·OKX 계정은 선입선출법으로 취득가액을 계산합니다.
```

---

## 3. 원본 포맷 요약 (상세는 parsers/)

| 파서 ID | 파일 | 이벤트 |
|---------|------|--------|
| `bithumb-certificate-pdf-v1` | PDF 거래내역 확인서 | 매수/매도/입/출 (엑셀 없음) |
| `binance-spot-xlsx-v1` | Spot Trade History xlsx | buy/sell |
| `binance-deposit-xlsx-v1` | Deposit History xlsx | deposit (Fee 컬럼 없음) |
| `binance-withdraw-xlsx-v1` | Withdraw History xlsx | withdrawal + Fee |
| `okx-trading-history-csv-v1` | Trading History csv | Spot + Transfer |
| `okx-funding-history-csv-v1` | Funding History csv | Deposit/Withdrawal/내부/rebate |

헤더·매핑: [parsers/](./parsers/) 를 **정본**으로 따른다.

---

## 4. 아키텍처 한 장

```text
SwiftUI Features
    → Application Services (Import, Matching, CalculationPipeline, FX, Report)
        → Domain (Models, Policies, CostBasis, Tax, Integrity)  // 순수, 테스트 중심
        → Import/ (Probe, Parsers PDF|XLSX|CSV)
        → Data/SwiftData + Infrastructure/FX|Export
```

- Domain에 SwiftUI/SwiftData import 금지.  
- 세금: `calculate` 후 **반드시** `verify`; critical 있으면 export 잠금.  
- 폴더: [design/02-module-structure.md](./design/02-module-structure.md)

---

## 5. 구현 Phase (이 순서 권장)

| Phase | 산출물 | 완료 조건 |
|-------|--------|-----------|
| **0** | 타깃 macOS 15, 폴더, `Money`/`Decimal`, `PolicyBundle.v1Default`, `TaxCopy` | 빌드 성공 |
| **1** | SwiftData Project/Account/Event/SourceFile CRUD | 프로젝트 저장·재실행 유지 |
| **2** | FormatProbe + 바이낸스 3파서 + OKX 2파서 (표 형태 우선) | 합성 fixture import 테스트 green |
| **3** | 빗썸 PDF 파서 | 합성 텍스트/미니 PDF fixture green |
| **4** | Transfer matching UI+엔진 | 1건 suggest→confirm |
| **5** | CostBasis MA+FIFO+TransferCost abandon | 단위+G1 일부 |
| **6** | FX 캐시+수동 입력 (원격은 스텁 가능) | 누락일 UI |
| **7** | Deemed + Holdings | max 로직 테스트 |
| **8** | TaxAggregator + Integrity **fail-closed** | V-* 테스트, export 게이트 |
| **9** | Report UI + CSV export + 고지 | MVP §10 체크리스트 |

**Verifier 없는 Tax/CostBasis PR 금지** (설계 규약).

---

## 6. 수량·금액 규약 (잠금)

### 6.1 LedgerEvent.quantity

저장: **부호 있는 Decimal**

| type | quantity |
|------|----------|
| buy, deposit, income | `> 0` |
| sell, withdrawal | `< 0` (절댓값이 수량) |
| fee (자산 차감) | `< 0` 또는 별도 fee 필드만 사용 (한 방식 고정: **fee는 feeAmount/feeAsset 필드**, quantity는 주 자산 변동만) |

### 6.2 KRW 환산 우선순위

1. `quoteAmountKRW` 또는 빗썸 정산금액 등 **이미 KRW**  
2. `quoteAsset == USDT` (또는 USD): `amount × fxUSDJPY` → **USD/KRW** rate on **KST calendar day** of event  
3. 기타 코인 견적: 가능하면 거래 행의 quote를 USDT로 환산 후 2; 불가 시 `needsFX` / 누락  

### 6.3 매수 취득원가 KRW

- 빗썸: **`abs(정산금액)`** (수수료 포함 유출)  
- 해외 buy: `abs(quantity) × price × USDT→KRW` + 수수료 KRW 환산  
  - Fee Coin == base: 취득 수량 순액 감소 또는 원가에 가산 (v1: **수량 순취득 = amount − fee_in_base**, 원가 = quote 지출 전액 KRW)  
  - Fee Coin == BNB 등: BNB 장부에서 dispose 후 그 원가를 취득 부대비용에 가산; BNB 없으면 quote 환산 근사 + warning  

### 6.4 매도 양도가 KRW

- 빗썸: **정산금액** (수수료 차감 후 유입, 양수)  
- 해외 sell: `abs(qty)×price×FX − feeKRW`  

### 6.5 반올림 (잠금)

| 용도 | 규칙 |
|------|------|
| 내부 원장 | Decimal 최대 정밀도 유지 |
| 표시·세액·리포트 KRW | **원 단위**, `NSDecimalNumber` rounding `.plain` (또는 banker's — **엔진과 Verifier 동일**; v1 채택: **`.plain` half up**) |
| 수량 비교 epsilon | `1e-10` 상대 또는 abs |
| 원가 비교 | abs 차이 ≤ 1 KRW 이면 동일 취급 (검증) |

---

## 7. 전송 매칭 (잠금 파라미터)

| 파라미터 | 값 |
|----------|-----|
| 시간 창 | 출금 시각 ± **72 hours** |
| 수량 | `abs(in) <= abs(out)` 이고 `abs(out)−abs(in) <= max(abs(out)*0.01, 1e-6)` 또는 출금 fee 별도 반영 |
| 점수 | asset 필수 + 시간 가까울수록 + 국내→해외 + 비고 거래소명 + tx 유사 |
| 확정 | 사용자 confirmed 만 원가 이전 |
| 미매칭 출금 | dispose 원가 발생, 상대 입고 없음 → **경고**; 계산은 진행 (block 옵션 기본 off) |

TransferCost:

```text
transferredCost = outboundCost * (receivedQty / withdrawnQty)
abandoned = outboundCost - transferredCost
deductibleExpense = 0
```

`withdrawnQty = abs(withdrawal.quantity)`  
`receivedQty = deposit.quantity` (양수)

---

## 8. 의제·세금 (잠금 절차)

상세 수도코드: [design/14-implementation-spec.md](./design/14-implementation-spec.md)

1. 전체 이벤트 시간순 (미매칭 포함, ignored 제외)  
2. t ≤ 2026-12-31 24:00 KST 재생 → 스냅샷  
3. 시가 테이블로 max  
4. books 리셋 후 의제 원가로 acquire  
5. 이후 이벤트 계속; **실현손익 집계는 timestamp ≥ 2027-01-01 00:00 KST 인 처분만**  
6. 연간 필터 taxYear  
7. income, taxBase, national, local  

시가 없으면 해당 자산 수량>0 시 **계산 blocked** (기본).

---

## 9. 보안

- 실 PDF/CSV/XLSX: 로컬 Application Support 또는 사용자 선택 경로  
- Address/TXID: 가능하면 **해시만** 저장  
- 로그에 주민·계좌·주소 전문 금지  
- `.gitignore` 유지  

---

## 10. MVP 완료 체크

[01-requirements.md](./01-requirements.md) §10 전체 + 아래:

- [x] `PolicyBundle.id == "cointax-v1.0"` 리포트 표시  
- [x] 고지 4종이 리포트·export에 포함  
- [x] G1 골든 (14-spec 수치) 테스트 통과  
- [x] Critical verify 시 export 버튼 disabled  

> 체크 갱신: 2026-08-11 (CoinTaxTests 30 pass).

---

## 11. 구현 시 하지 말 것

- 문서를 무시하고 “관례적 CSV 파서”만 만들기  
- 빗썸을 엑셀 전제로 구현  
- 전송 소실 원가를 취득가에 실어 세금 줄이기 (기본 정책 위반)  
- Verifier 없이 세액 화면 출시  
- 실거래 raw를 저장소에 커밋  

---

## 12. 다음 상세

→ **[design/14-implementation-spec.md](./design/14-implementation-spec.md)** (전체 알고리즘·타입 필드·골든 수치·에러 코드)
