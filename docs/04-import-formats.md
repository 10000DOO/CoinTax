# Import 포맷 설계 (실측 기준)

| 항목 | 내용 |
|------|------|
| 문서 버전 | 1.0 |
| 작성일 | 2026-08-11 |
| 상태 | 실측 반영 확정 |
| 상세 스키마 | [parsers/](./parsers/) |

> 초기 가정 “전부 CSV”는 **폐기**. 거래소·서류별로 **PDF / XLSX / CSV** 가 다르다.

---

## 1. 목표

거래소·서류 원본을 **표준 `LedgerEvent`** 로 정규화한다.

| 원칙 | 내용 |
|------|------|
| 포맷 분기 | 확장자·매직·헤더/제목으로 파서 선택 |
| 프리셋 우선 | 빗썸·바이낸스·OKX 실측 스키마 |
| 제네릭 | 표 형태(CSV/XLSX)만 컬럼 매핑 폴백 |
| 원본 보존 | 로컬 저장 가능, **git 금지** (PII) |
| 선물 제외 | 인식 시 `ignored` + 건수 고지 |

---

## 2. v1 지원 매트릭스 (실측)

| 거래소 | 서류/export | 파일 형식 | 포함 이벤트 | 원가 계정 | 상세 |
|--------|-------------|-----------|-------------|-----------|------|
| **빗썸** | 거래내역 확인서 | **PDF only** | 매수·매도·입금·출금 (KRW 포함) | 이동평균 | [parsers/bithumb-transaction-certificate.md](./parsers/bithumb-transaction-certificate.md) |
| **빗썸** | 이자·배당 원천징수영수증 | PDF | 이자 원천징수 | **엔진 외** | 위 문서 §5 |
| **바이낸스** | Spot Trade History | **XLSX** | 현물 체결만 | FIFO | [parsers/binance-spot-trade-history.md](./parsers/binance-spot-trade-history.md) |
| **바이낸스** | **Withdraw** History Report | **XLSX** | 출금 Completed | FIFO | [parsers/binance-withdraw-history.md](./parsers/binance-withdraw-history.md) |
| **바이낸스** | **Deposit** History Report | **XLSX** | 입금 Completed (Fee 컬럼 없음) | FIFO | [parsers/binance-deposit-history.md](./parsers/binance-deposit-history.md) |
| **OKX** | Trading History | **CSV** (1행 메타) | Spot + Transfer | FIFO | [parsers/okx-trading-history.md](./parsers/okx-trading-history.md) |
| **OKX** | **Funding History** | **CSV** (1행 메타) | Deposit/Withdrawal + 내부이동 + rebate 등 | FIFO | [parsers/okx-funding-history.md](./parsers/okx-funding-history.md) |

### 2.1 조합별 커버리지

| 조합 | 국내 매매 | 국내→해외 출금 | 해외 입금 | 해외 현물 | 해외 출금 |
|------|-----------|----------------|-----------|-----------|-----------|
| 빗썸 + OKX CSV | ✅ | ✅ | ✅ Transfer in | ✅ | ✅ Transfer out |
| 빗썸 + 바이낸스 Spot only | ✅ | ✅ (빗썸) | ❌ | ✅ | ❌ |
| 빗썸 + Spot + Withdraw + **Deposit** | ✅ | ✅ | ✅ | ✅ | ✅ |

**v1 스키마 실측 완료:** 빗썸 PDF + 바이낸스 Spot/Deposit/Withdraw + OKX Trading + OKX Funding.

---

## 3. 표준 필드 (`LedgerEvent` draft)

| 필드 | 필수 | 설명 |
|------|------|------|
| `timestamp` | ✅ | UTC 저장 (소스 TZ 적용 후) |
| `type` | ✅ | buy / sell / deposit / withdrawal / fee / income / other / ignored |
| `baseAsset` | ✅ | |
| `quantity` | ✅ | 부호 규약: 설계 도메인 문서 |
| `quoteAsset` | 매매 | |
| `price` | 권장 | |
| `quoteAmount` / `quoteAmountKRW` | 권장 | 빗썸 KRW 직사용 |
| `feeAmount` / `feeAsset` | 권장 | |
| `externalID` | 권장 | 중복 제거 |
| `memo` / `counterpartyHint` | 선택 | 빗썸 비고「바이낸스」등 |
| `sourceKind` | ✅ | `bithumb_pdf` / `binance_spot_xlsx` / `okx_history_csv` / … |
| `rawRef` | 권장 | 페이지·행 번호 (감사) |

---

## 4. 포맷별 정규화 규칙 (요약)

### 4.1 빗썸 PDF — 거래내역 확인서

```text
파일 → PDF 텍스트/테이블 추출 → 행 병합(일시·단위 2단) → 행 분류 → LedgerEvent
```

| 거래구분 | type | 원가/수량 |
|----------|------|-----------|
| 매수 | buy | qty=`거래수량`, **취득 KRW=`|정산금액|`** (수수료 포함) |
| 매도 | sell | qty=`거래수량`, 양도 KRW=`정산금액`(순액) |
| 입금 (코인) | deposit | qty=`거래수량` |
| 출금 (코인) | withdrawal | qty=`거래수량`, memo=비고 |
| 입금/출금 KRW | fiat_* | 코인 원장과 분리 태그 |
| 비고 예치금 이용료 | income/fiat | **가상자산 기타소득 엔진 외** |

- 엑셀 경로 **없음**.  
- 암호 PDF: 사용자 비밀번호.  
- PII(성명·계좌·주소) 파싱 후 **폐기**.

### 4.2 바이낸스 XLSX — Spot Trade History

```text
XLSX(sheet1, inlineStr) → 헤더 검증 → 1행=1 fill → LedgerEvent
```

| 컬럼 | 매핑 |
|------|------|
| Date(UTC) | timestamp UTC |
| Base/Quote Asset | base/quote |
| Type BUY/SELL | buy/sell |
| Amount | base qty |
| Total | quote amount |
| Fee / Fee Coin | fee |

- 체결만. externalID 없음 → fingerprint.

### 4.2b 바이낸스 XLSX — Withdraw History Report

```text
XLSX → Date(UTC+0), Coin, Network, Amount, Fee, Address, TXID, Status
     → withdrawal (Completed only)
```

| 컬럼 | 매핑 |
|------|------|
| Date(UTC+0) | UTC (`yy-MM-dd HH:mm:ss` 주의) |
| Coin / Amount | 출고 자산·수량 |
| Fee | 동일 Coin 수수료 (소실/보수 정책 연동) |
| TXID | externalID |
| Address | 해시만 저장 권장 |
| Status | Completed만 반영 |

- **출금 전용**.  
- 상세: [parsers/binance-withdraw-history.md](./parsers/binance-withdraw-history.md)

### 4.2c 바이낸스 XLSX — Deposit History Report

```text
XLSX → Date(UTC+0), Coin, Network, Amount, Address, TXID, Status
     → deposit (Completed only; Fee 컬럼 없음)
```

- 빗썸 출금 ↔ 바이낸스 입금 매칭 핵심.  
- 상세: [parsers/binance-deposit-history.md](./parsers/binance-deposit-history.md)

### 4.3 OKX CSV — Trading History

```text
행1 메타(UID, TZ) → 행2 헤더 → 데이터
  Spot: Order id 그룹 → Balance Change 우선 leg 해석
  Transfer: Balance Change → deposit/withdrawal
```

| Trade Type | Action | type |
|------------|--------|------|
| Spot | Buy/Sell (멀티레그) | buy/sell (그룹 합치기, 이중계산 금지) |
| Transfer | Transfer in/out | **transferInternal** (거래↔펀딩 내부 이동) |

- `Amount==0` 이어도 Transfer는 **Balance Change** 사용.  
- 메타 Time Zone 적용 (예: UTC+8).

### 4.4 OKX CSV — Funding History (입출금 전용 export)

```text
행1 메타 → 행2: id,Time,Type,Amount,Before Balance,After Balance,Symbol
```

| Type | type |
|------|------|
| Deposit, Received | deposit |
| Withdrawal | withdrawal (Amount 음수 → abs) |
| From/To unified trading account | transferInternal (펀딩↔트레이딩) |
| Fee rebate | income |

- 외부 브릿지 매칭: **Deposit / Withdrawal** — Trading History 의 Transfer 는 내부 이동이므로 쓰지 않는다.  
- Trading History와 병행 import (같은 내부 이동이 양쪽에 찍혀도 이중 반영되지 않는다).  
- 상세: [parsers/okx-funding-history.md](./parsers/okx-funding-history.md)

---

## 5. 파서 아키텍처

```swift
enum SourceFormat: String {
    case pdf, xlsx, csv
}

protocol ExchangeDocumentParser {
    var id: String { get }           // "bithumb-certificate-pdf-v1"
    var displayName: String { get }
    var acceptedFormats: Set<SourceFormat> { get }
    func detect(file: ImportFileProbe) -> Double   // 0...1
    func parse(file: ImportFile, account: Account) throws -> ParseResult
}

struct ImportFileProbe {
    var url: URL
    var format: SourceFormat
    var fileName: String
    var headerOrTitleSnippet: String  // 앞부분 텍스트
}

struct ParseResult {
    var events: [LedgerEventDraft]
    var errors: [ParseIssue]
    var warnings: [ParseIssue]
    var ignoredCount: Int            // 선물 등
    var meta: [String: String]       // timezone, accountType, period...
}
```

| Parser ID | Format | detect 힌트 |
|-----------|--------|-------------|
| `bithumb-certificate-pdf-v1` | pdf | 제목 `거래내역 확인서`, `정산금액` |
| `binance-spot-xlsx-v1` | xlsx | 헤더 `Date(UTC)`,`Fee Coin` |
| `binance-withdraw-xlsx-v1` | xlsx | `Date(UTC+0)`,`Network`,`Fee`,`TXID`,`Status` |
| `binance-deposit-xlsx-v1` | xlsx | `Date(UTC+0)`,`Network`,`TXID`,`Status` (**Fee 없음**) |
| `okx-trading-history-csv-v1` | csv | 1행 `Time Zone:`, 2행 `Balance Change` |
| `okx-funding-history-csv-v1` | csv | 파일명 Funding + 헤더 `Before Balance`,`After Balance` |
| `generic-tabular-v1` | csv/xlsx | 사용자 컬럼 매핑 |

~~`ExchangeCSVParser`~~ → **`ExchangeDocumentParser`** (이름 변경).

### 계정 자동 배정 (`ImportRouter`)

여러 거래소 파일을 한 번에 넣어도 **파일마다 계정을 따로 정한다.** 사용자가 계정을 하나 고르게 두면
빗썸 파일이 해외 계정으로 들어가 **원가법이 뒤바뀌고**(이동평균↔선입선출),
거래소 간 전송이 같은 계정 안 이동이 되어 **매칭에서 빠지고 취득원가가 소멸한다**
([audit-2026-08-12-logic.md](./audit-2026-08-12-logic.md) A-06).

```text
FormatProbe → ParserRegistry.bestPreset(제네릭 제외) → parserID → ExchangeCode
  score ≥ 0.6  → 그 거래소 계정 (없으면 생성)
  그 미만·제네릭·미인식 → nil → 사용자에게 묻는다 (조용히 아무 계정에나 넣지 않는다)
```

| Parser ID | 계정 |
|-----------|------|
| `bithumb-certificate-pdf-v1` | 빗썸 (이동평균법) |
| `binance-*` | 바이낸스 (선입선출법) |
| `okx-*` | OKX (선입선출법) |
| `generic-tabular-v1` | **자동 배정 없음** |

한계: 같은 거래소의 부계정 여러 개는 v1 범위 밖 — 거래소당 계정 하나로 합쳐진다.

---

## 6. Import 파이프라인

```text
[사용자 파일 선택 / Drop]
        │
        ▼
  FormatProbe (pdf|xlsx|csv|unknown)
        │
        ▼
  ParserRegistry.detect → 후보 정렬 → 사용자 확인
        │
        ▼
  parser.parse ──► ParseResult
        │
        ├─ errors → 행/페이지 리포트
        ├─ ignored futures → 카운트
        ▼
  Deduper — ① 파일 SHA-256 동일 → 거부  ② 내용키(행 번호 제외) 개수 비교 → 초과분만 삽입
        │
        ▼
  Persist LedgerEvent (+ SourceFile meta: format, parserId, sha256)
        │
        ▼
  MatchingService.suggest (입출금 있을 때)
```

실패 정책: 행/페이지 단위 스킵 + 로그. 파일 fatal(암호 실패, 빈 파일)만 롤백.

---

## 7. 전송 매칭 입력

| 소스 | withdrawal | deposit |
|------|------------|---------|
| 빗썸 PDF | 코인 출금 | 코인 입금 |
| OKX Trading CSV | Transfer out | Transfer in |
| OKX Funding CSV | Withdrawal | Deposit |
| 바이낸스 Spot | — | — |
| 바이낸스 Withdraw | withdrawal | — |
| 바이낸스 Deposit | — | deposit |

점수: 자산·수량 tolerance·시간창·비고 거래소 힌트(`바이낸스`).

---

## 8. 보안

| 규칙 | |
|------|--|
| git | `*.pdf` `*.csv` `*.xlsx` `docs/samples/raw/` `.dab-attachments/` 무시 |
| 앱 | 원본 로컬 Application Support만, 네트워크 업로드 없음 |
| 로그 | 주소·주민·계좌 전문 금지 |

---

## 9. 테스트 fixture

| 종류 | git |
|------|-----|
| 합성 CSV/XLSX/PDF 텍스트 | `docs/samples/synthetic/` 만 (개인정보 무) |
| 실거래 raw | 로컬 only |

골든 G-import:

1. 빗썸 PDF 합성 5행 (매수·출금)  
2. 바이낸스 xlsx 합성 2 fill  
3. OKX csv 메타+Spot 그룹+Transfer  

---

## 10. 관련

- 설계 상세: [design/09-import-and-matching.md](./design/09-import-and-matching.md)  
- 구 문서명 `04-csv-import.md` → 본 문서로 대체  
