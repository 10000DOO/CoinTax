# 09. Import · 전송 매칭 (멀티 포맷)

| 버전 | 2.0 |
|------|-----|
| 작성 | 2026-08-11 (실측 포맷 반영) |
| 상위 | [../04-import-formats.md](../04-import-formats.md), [parsers/](../parsers/) |

---

## 1. 왜 CSV 전용이 아닌가

| 거래소 | 실제 원본 | 비고 |
|--------|-----------|------|
| 빗썸 | **PDF** 거래내역 확인서 | 엑셀 미제공 |
| 바이낸스 | **XLSX** Spot + Deposit + Withdraw | 입·출·체결 스키마 실측 완료 |
| OKX | **CSV** Trading + **Funding** History | 거래 + 펀딩 입출금 |

설계·코드 명칭: **Import** / `ExchangeDocumentParser` (CSV 한정 API 폐기).

---

## 2. 모듈 배치

```text
Import/
  Probe/
    FormatProbe.swift          // pdf / xlsx / csv
  Parsing/
    ExchangeDocumentParser.swift
    ParserRegistry.swift
    ParseResult.swift
  Parsers/
    Bithumb/
      BithumbCertificatePDFParser.swift
      BithumbPDFTableExtractor.swift
    Binance/
      BinanceSpotXLSXParser.swift
      BinanceDepositXLSXParser.swift
      BinanceWithdrawXLSXParser.swift
      XLSXInlineStringReader.swift
    OKX/
      OKXTradingHistoryCSVParser.swift
      OKXFundingHistoryCSVParser.swift
    Generic/
      GenericTabularMapper.swift
  Matching/
    TransferMatchingEngine.swift
    TransferScore.swift
```

---

## 3. 포맷 프로브

```text
URL
  ├─ .pdf / %PDF → pdf
  ├─ .xlsx / ZIP+xl/ → xlsx
  ├─ .csv / 텍스트 → csv
  └─ else → unknown (거부 또는 제네릭 시도)
```

PDF: 첫 페이지 텍스트에 `거래내역 확인서` 있으면 빗썸 후보 가점.  
XLSX: 1행 헤더 셀 읽기.  
CSV: 1~2행 peek (OKX 메타 구분).

---

## 4. 파서별 처리

### 4.1 빗썸 PDF

```text
PDFDecrypt?(password)
  → Extract text lines / table cells (PDFKit)
  → Merge split datetime + unit rows
  → Map 거래구분
  → Events
```

| 난점 | 대응 |
|------|------|
| 2단 단위 행 | 다음 줄 USDT/KRW 병합 |
| 콤마 숫자 | Decimal 파서 locale-aware |
| 암호 | 사용자 입력, 메모리만 |
| PII 상단 | 파싱 스킵 또는 즉시 폐기 |

구현 상세: [../parsers/bithumb-transaction-certificate.md](../parsers/bithumb-transaction-certificate.md)

### 4.2 바이낸스 XLSX — Spot

```text
Unzip sheet1.xml → inlineStr → 1 fill / row → buy/sell
```

입출금 없음 → warning `binance_spot_missing_deposits` (Deposit 없을 때).

### 4.2b 바이낸스 XLSX — Withdraw

```text
Date(UTC+0), Coin, Network, Amount, Fee, Address, TXID, Status
  → withdrawal (Completed)
  → Fee → 전송 수수료 경로
  → Address/TXID 해시만 저장
```

detect: 헤더 `Network`+`TXID`+`Status` (Spot과 구분).  
스키마: [../parsers/binance-withdraw-history.md](../parsers/binance-withdraw-history.md)

### 4.2c 바이낸스 XLSX — Deposit

```text
Date(UTC+0), Coin, Network, Amount, Address, TXID, Status
  → deposit (Completed)
  → Fee 컬럼 없음 (Withdraw와 detect 구분)
```

스키마: [../parsers/binance-deposit-history.md](../parsers/binance-deposit-history.md)  
매칭: 빗썸 출금 ↔ 바이낸스 Deposit.

### 4.3 OKX CSV

```text
Read UTF-8 (BOM 제거 · 실패 시 인코딩 폴백)
  → Line0 meta → timezone, accountType
  → Line1 header (중복·빈 열 이름 허용 — 첫 열 채택)
  → Rows
       ├ Spot → group by Order id → synthesize buy/sell
       │        (Balance Change 는 수수료 차감 후 → quantityIsNetOfFee = true)
       └ Transfer → **transferInternal** (거래↔펀딩 내부 이동)
```

⚠️ Trading History 의 `Transfer in/out` 을 외부 입출금으로 잡으면 Funding History 와 함께
import 했을 때 같은 이동이 이중 반영된다. 외부 브릿지는 **Funding History 의 Deposit/Withdrawal** 만 쓴다.

Spot 이중 계산 방지: Order 단위로 base leg + quote leg 한 쌍.

### 4.4 OKX CSV — Funding History

```text
id, Time, Type, Amount, Before Balance, After Balance, Symbol
  Deposit / Withdrawal → 외부 입출금
  From/To unified trading account → 내부 이동
  Fee rebate → income
```

스키마: [../parsers/okx-funding-history.md](../parsers/okx-funding-history.md)

---

## 5. Import UX (포맷 인지)

```text
Import 화면
  [+ 파일 추가]  PDF / XLSX / CSV
  자동 인식 배지: 빗썸 확인서 | 바이낸스 Spot | OKX History | 제네릭
  미리보기: 상위 N 이벤트
  경고:
    - 바이낸스 Spot only → 입출금 추가 안내
    - 빗썸 원천징수 PDF → “거래내역 아님” 거부 또는 별도 분류
```

원천징수영수증: `detect` 시 `bithumb-withholding-pdf` → **거부** + “이자 원천징수는 v1 미지원”.

---

## 6. 전송 매칭

### 6.1 입력 이벤트

`type ∈ {withdrawal, deposit}` 이고 자산이 가상자산(KRW 제외).

### 6.2 점수

| 요소 | 가중 |
|------|------|
| 동일 asset | 필수 |
| qty tolerance (전송 수수료) | 필수 창 |
| 시간 ≤ 72h | 가점 |
| domestic→overseas 방향 | 가점 |
| 빗썸 비고에 상대 거래소명 | 가점 |
| tx 주소 힌트 (저장 시 해시만) | 최우선 |

Confirmed link만 원가 이전 (`TransferCostPolicy`).

**1:1 배정 필수.** 후보 생성 시 점수 높은 순으로 출금·입금을 한 번씩만 배정한다.
같은 입금이 두 출금에 제안되면 사용자가 둘 다 확정할 수 있고, 그러면 입고 원가가 이중 계상된다.
`MatchingService.confirm` 도 이미 쓰인 출금·입금을 거부하며, 엔진은 중복 링크를 Critical(V-QTY-04)로 보고한다.

거부(`rejected`)한 쌍은 다시 제안하지 않는다. 수동 연결·연결 해제는 `linkManually` / `unlink`.

### 6.3 조합 시나리오

```text
빗썸 USDT 출금  ──match──►  OKX Transfer in
빗썸 USDT 출금  ──match──►  바이낸스 Deposit (파일 있을 때)
OKX Transfer out ──match──► 빗썸 USDT 입금
```

바이낸스 Spot만 있으면 해외 쪽 deposit 후보 부족 → 미매칭 경고 유지.

---

## 7. SourceFile 메타 (SwiftData)

| 필드 | 예 |
|------|-----|
| fileName | (표시용, 경로 전체 저장 지양) |
| format | pdf / xlsx / csv |
| parserId | bithumb-certificate-pdf-v1 |
| sha256 | 중복 import |
| importedAt | |
| extraJSON | timezone, queryPeriod, ignoredCount |

---

## 8. 다음

[10-integrity-engine.md](./10-integrity-engine.md)  
Import 검증: 파서 버전·포맷·선물 제외 수 일치.
