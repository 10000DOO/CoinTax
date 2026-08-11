# 샘플 데이터

## 디렉터리

| 경로 | 용도 | git |
|------|------|-----|
| `raw/` | 사용자 실 export (분석용) | **무시** (UID·잔고 포함 가능) |
| `synthetic/` (예정) | 헤더만/가짜 행 fixture | 커밋 OK |
| `expected/` (예정) | 골든 세금 결과 JSON | 커밋 OK |

## 실측 완료 (2026-08-11)

로컬 `raw/` 기준:

| 파일 | 거래소 | 형식 | 문서 |
|------|--------|------|------|
| `Binance-Spot Trade History-*.xlsx` | 바이낸스 현물 체결 | XLSX | [../parsers/binance-spot-trade-history.md](../parsers/binance-spot-trade-history.md) |
| `Binance-Withdraw-History-Report-*.xlsx` | 바이낸스 **출금** | XLSX | [../parsers/binance-withdraw-history.md](../parsers/binance-withdraw-history.md) |
| `Binance-Deposit-History-Report-*.xlsx` | 바이낸스 **입금** | XLSX | [../parsers/binance-deposit-history.md](../parsers/binance-deposit-history.md) |
| `OKX Trading History_*.csv` | OKX 현물+Transfer | CSV (1행 메타) | [../parsers/okx-trading-history.md](../parsers/okx-trading-history.md) |
| `OKX Funding History_*.csv` | OKX 펀딩 입출금·내부이동 | CSV (1행 메타) | [../parsers/okx-funding-history.md](../parsers/okx-funding-history.md) |

### 파서 구현 시 주의

1. **바이낸스 Spot 파일만으로는 입출금 없음** → 전송 매칭용 Deposit/Withdrawal 별도 필요  
2. **OKX**는 Transfer in/out 포함, Spot은 Order id당 다수 행  
3. 실파일 **커밋 금지**

## 빗썸

| 종류 | 실측 | 문서 |
|------|------|------|
| **거래내역 확인서** (PDF only) | ✅ 2026-08-11 | [../parsers/bithumb-transaction-certificate.md](../parsers/bithumb-transaction-certificate.md) |
| 이자·배당 원천징수영수증 | ✅ (거래내역 아님) | 위 문서 §5 |

빗썸은 **엑셀 없음 → PDF 파서 필수**.  
실파일(`raw/`, `.dab-attachments/`, `*.pdf`)은 **전부 gitignore**.

## 바이낸스 스키마 실측

| 파일 | 상태 |
|------|------|
| Spot Trade History | ✅ |
| Withdraw History | ✅ |
| Deposit History | ✅ |
