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
| **바이낸스** | Transaction History | **CSV** (`Change` 열 = 거래소가 적은 잔고 변동) |
| **OKX** | Trading History | **CSV** (Spot + Transfer) |
| **OKX** | Funding History | **CSV** (Deposit/Withdrawal 등) |
| **Trezor Suite** | 계정 내역 | **CSV** (하드웨어 지갑 · 온체인) |

상세 스키마: [`parsers/`](./parsers/) · Import 설계: [`04-import-formats.md`](./04-import-formats.md)

## 읽기 순서

### A. 요구·결정

| 문서 | 설명 |
|------|------|
| [00-tax-law-ssot.md](./00-tax-law-ssot.md) | **세법 백서 (SSOT).** 법령 원문 기반 사실만. 12장에 미결사항 24건(U-01~U-24), 11.1 에 「10월 고시 나오면 다시 볼 목록」 |
| [01-requirements.md](./01-requirements.md) | 기능·비기능·MVP |
| [03-tax-rules.md](./03-tax-rules.md) | 세금 가정 (근거는 00번 문서) |
| [04-import-formats.md](./04-import-formats.md) | **멀티 포맷 Import** |
| [05-decisions.md](./05-decisions.md) | 확정 결정 |
| [06-integrity.md](./06-integrity.md) | 검증 불변식 |

### A-2. 감사 기록 (실데이터로 확인한 결함과 수정)

| 문서 | 범위 |
|------|------|
| [realdata-audit-2026-08-12.md](./realdata-audit-2026-08-12.md) | 1차 — 파서(CRLF·BOM·타임존·PDF 좌표)·코인↔코인 견적 leg |
| [audit-2026-08-12-logic.md](./audit-2026-08-12-logic.md) | 2차 — 코인 수수료 장부 반영·전송 도착 시각·검증기 오탐·**거래소 자동 구분** |
| [audit-2026-08-12-verification.md](./audit-2026-08-12-verification.md) | 3차 — **2027 과세 경로 실데이터 검증** · 바이낸스 외부 정답지 · 리포트/export · 수수료 자산 넘겨짚기 |
| [audit-2026-08-13-report-and-rules.md](./audit-2026-08-13-report-and-rules.md) | 4차 — **1원 미만 단가가 export 에서 0원** · 출금 수수료의 마지막 넘겨짚기 · 무작위 생성기 확대 |
| [audit-2026-08-13-loop.md](./audit-2026-08-13-loop.md) | 5차 — **반복 루프 35회차 · 결함 19건.** 자료 입구(엑셀 셀 밀림·한글 인코딩·두 자리 연도) · 검증 장치(테스트가 죽어도 통과·실패할 수 없는 검사·먼지가 검사를 끔) · 화면과 파일이 실제와 다른 말을 하던 자리 |
| [audit-2026-08-14-total-average.md](./audit-2026-08-14-total-average.md) | 6차 — **폐지된 원가 규칙 발견 · 거주자별 총평균법 전환 · 결함 9건.** 가진 것보다 많은 원가 공제 · 같은 입력에 다른 세액 · Trezor 파서 신설 · 「2,026년 예상 세액」(UI 실행으로만 보임) |
| [audit-2026-08-14-cost-and-parser.md](./audit-2026-08-14-cost-and-parser.md) | 7차 — **연말 이동 중 전송이 의제취득가에서 빠지던 문제(세금 2,200만 원 과다) · Trezor 비트코인 입금을 출금으로 뒤집던 문제(수량 76.5%) · 토큰 전송 가스 누락 · 문서가 폐지된 원가법을 말하던 문제.** 결함 3 + 문서 1 + 그물 구멍 1 |

**→ [07-adversarial-audit-prompt.md](./07-adversarial-audit-prompt.md)** — 다음 회차 감사를
시작할 때 **새 AI 세션에 그대로 붙여 넣는 프롬프트.** 「내 코드를 내 테스트로 검사하는」
사각지대를 우회하도록, 정답을 코드 밖에서 가져오게 강제한다.

### B. 설계 (큰 틀 → 세부)

**→ [design/README.md](./design/README.md)** (v2.0)

### C. 거래소 스키마

| 문서 |
|------|
| [parsers/bithumb-transaction-certificate.md](./parsers/bithumb-transaction-certificate.md) |
| [parsers/binance-spot-trade-history.md](./parsers/binance-spot-trade-history.md) |
| [parsers/binance-withdraw-history.md](./parsers/binance-withdraw-history.md) |
| [parsers/binance-deposit-history.md](./parsers/binance-deposit-history.md) |
| [parsers/binance-transaction-history.md](./parsers/binance-transaction-history.md) |
| [parsers/okx-trading-history.md](./parsers/okx-trading-history.md) |
| [parsers/okx-funding-history.md](./parsers/okx-funding-history.md) |
| [parsers/trezor-suite-csv.md](./parsers/trezor-suite-csv.md) |

## 보안

실원본·첨부·`docs/samples/raw/` · `*.pdf/csv/xlsx` → **`.gitignore`**.  
스키마 문서만 커밋.

## 전송 소실 원가 고지

> 전송 소실 원가는 공개 세법 해설이 없어, 과다 공제를 피하기 위해 필요경비·도착 취득가에 넣지 않습니다. 세액이 다소 커질 수 있으며 세무 자문이 아닙니다.

## 저장소

로컬 개인 사용 프로젝트. 실거래 원본은 커밋하지 않는다 (`.gitignore` 참조).

## 실행하기 전에 (개발자)

```bash
./scripts/smoke.sh                              # PII 검사 + 빌드 + 테스트 (344건)
python3 scripts/binance-expected-balances.py    # 바이낸스 잔고 정답지 재생성 (실원본 필요)
```

`scripts/binance-expected-balances.py` 는 바이낸스 원본에서 **앱 코드를 전혀 쓰지 않고** 잔고를
다시 계산해 정답지를 만든다. 빗썸·OKX 는 원본에 잔고 열이 있어 앱이 자동으로 대조하지만
(V-BAL), 바이낸스 화면 CSV 에는 그 열이 없어 사각지대라서다.

> 3차 감사에서 **더 강한 근거**를 찾았다 — 바이낸스 **Transaction History** 의 `Change` 열은
> 거래소가 스스로 적은 잔고 변동이므로, 그냥 더하기만 하면 우리 해석이 들어가지 않는 정답지가 된다
> ([audit-2026-08-12-verification.md](./audit-2026-08-12-verification.md) §4).
