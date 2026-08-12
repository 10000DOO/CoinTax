# CoinTax 문서

가상자산 기타소득 신고 보조 · 예상 세액 macOS 앱 (Swift / SwiftUI).

## 다른 세션에서 구현할 때 (필독)

1. **[IMPLEMENTATION.md](./IMPLEMENTATION.md)** — 잠긴 기본값·Phase·금지 사항  
2. **[design/14-implementation-spec.md](./design/14-implementation-spec.md)** — 타입·알고리즘·골든 수치·에러 코드  
3. [parsers/](./parsers/) + [04-import-formats.md](./04-import-formats.md) — 원본 스키마  
4. [05-decisions.md](./05-decisions.md) · [06-integrity.md](./06-integrity.md)  
5. [design/README.md](./design/README.md) 나머지  

이 순서면 **문서만으로 MVP 구현**을 목표로 한다.

## 원본 포맷 (실측 · 설계 전제)

| 거래소 | 서류 | 형식 |
|--------|------|------|
| **빗썸** | 거래내역 확인서 | **PDF only** (엑셀 없음) |
| **바이낸스** | Spot Trade History | **XLSX** (체결만) |
| **바이낸스** | Deposit / Withdraw History | **XLSX** (입·출금) |
| **OKX** | Trading History | **CSV** (Spot + Transfer) |
| **OKX** | Funding History | **CSV** (Deposit/Withdrawal 등) |

상세 스키마: [`parsers/`](./parsers/) · Import 설계: [`04-import-formats.md`](./04-import-formats.md)

## 읽기 순서

### A. 요구·결정

| 문서 | 설명 |
|------|------|
| [01-requirements.md](./01-requirements.md) | 기능·비기능·MVP |
| [03-tax-rules.md](./03-tax-rules.md) | 세금 가정 |
| [04-import-formats.md](./04-import-formats.md) | **멀티 포맷 Import** |
| [05-decisions.md](./05-decisions.md) | 확정 결정 |
| [06-integrity.md](./06-integrity.md) | 검증 불변식 |

### B. 설계 (큰 틀 → 세부)

**→ [design/README.md](./design/README.md)** (v2.0)

### C. 거래소 스키마

| 문서 |
|------|
| [parsers/bithumb-transaction-certificate.md](./parsers/bithumb-transaction-certificate.md) |
| [parsers/binance-spot-trade-history.md](./parsers/binance-spot-trade-history.md) |
| [parsers/binance-withdraw-history.md](./parsers/binance-withdraw-history.md) |
| [parsers/binance-deposit-history.md](./parsers/binance-deposit-history.md) |
| [parsers/okx-trading-history.md](./parsers/okx-trading-history.md) |
| [parsers/okx-funding-history.md](./parsers/okx-funding-history.md) |

## 보안

실원본·첨부·`docs/samples/raw/` · `*.pdf/csv/xlsx` → **`.gitignore`**.  
스키마 문서만 커밋.

## 전송 소실 원가 고지

> 전송 소실 원가는 공개 세법 해설이 없어, 과다 공제를 피하기 위해 필요경비·도착 취득가에 넣지 않습니다. 세액이 다소 커질 수 있으며 세무 자문이 아닙니다.

## 저장소

로컬 개인 사용 프로젝트. 실거래 원본은 커밋하지 않는다 (`.gitignore` 참조).
