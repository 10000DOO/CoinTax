# 01. 아키텍처 개요

| 버전 | 2.0 |
|------|-----|
| 상위 | [README.md](./README.md) |
| 비고 | 실측 포맷 반영 (PDF/XLSX/CSV) |

---

## 1. 시스템 한 줄

**로컬 macOS 앱**이 국내·해외 거래소 **원본 서류(PDF / XLSX / CSV)** 를 정규화·매칭하고, **계정별 원가 엔진**으로 손익·의제취득가·보유·예상 세액을 계산한 뒤, **검증 통과 시에만** 신고 보조 자료를 확정한다.

---

## 2. 컨텍스트 다이어그램

```text
                 ┌──────────────┐
                 │  사용자(개인) │
                 └──────┬───────┘
     PDF·XLSX·CSV / 매칭 / 환율 / 리포트
                        │
                        ▼
┌──────────────┐ ┌─────────────────────────────────────┐ ┌─────────────┐
│ 빗썸 확인서  │►│           CoinTax (macOS)            │►│ 화면 리포트  │
│ PDF          │ │  Multi-format Import · Match         │ │ export      │
│ 바이낸스     │►│  Ledger · Tax · Verify · Holdings    │ │ (검증 후)   │
│ Spot XLSX    │ │  Policy plugins · Local SwiftData    │ └─────────────┘
│ OKX History  │►└──────────────────┬──────────────────┘
│ CSV          │                    │ (옵트인 FX)
└──────────────┘                    ▼
                         ┌─────────────────────┐
                         │ 기준환율 공개 데이터  │
                         └─────────────────────┘
```

**경계**

| In | Out of scope (v1) |
|----|-------------------|
| 빗썸 PDF 확인서, 바이낸스 Spot XLSX, OKX Trading CSV | 선물/마진, API, 서버, 홈택스 |
| 바이낸스 입출금 파일(추가 수집 시) | 빗썸 이자 원천징수 영수증 → 코인 기타소득 엔진 |
| 사용자 확인 전송 매칭 | 완전 자동 신고 |
| 로컬 프로젝트 | 실원본 git · 클라우드 동기화 |

---

## 3. 품질 속성 (아키텍처 드라이버)

| 우선 | 속성 | 대응 |
|------|------|------|
| 1 | **정합성(세금)** | Calculate → Verify → Publish; Decimal; 정책 ID 감사 |
| 2 | **감사 가능성** | 원본 행·환율·의제·정책 버전 추적 |
| 3 | **정책 교체 용이** | 전송 수수료 등 Strategy 플러그인 |
| 4 | **프라이버시** | 거래 원본 비전송; 환율만 옵트인 |
| 5 | **확장** | `ExchangeDocumentParser` (PDF/XLSX/CSV) |
| 6 | **단순 배포** | 단일 앱 타깃, 로컬 실행 |

---

## 4. 논리 레이어

```text
┌──────────────────────────────────────────────────────────┐
│ Presentation (SwiftUI)                                   │
│  NavigationSplitView · Feature screens · ViewState       │
├──────────────────────────────────────────────────────────┤
│ Application (Use cases / Services)                       │
│  Import · Matching · RunCalculation · Verify · Export    │
│  FillFX · HoldingsQuery                                  │
├──────────────────────────────────────────────────────────┤
│ Domain (순수, 테스트 중심)                                 │
│  Models · CostBasis engines · Tax · Deemed · Policies    │
│  Verifiers (엔진과 분리)                                   │
├──────────────────────────────────────────────────────────┤
│ Infrastructure                                           │
│  SwiftData · CSV IO · FX clients · File export           │
└──────────────────────────────────────────────────────────┘
```

**규칙**

- Domain → UI / SwiftData **의존 금지**
- Infrastructure는 Domain 타입을 구현·매핑
- 세금 숫자는 Domain 엔진 + Domain Verifier만 산출·확정 판정

---

## 5. 핵심 런타임 파이프라인

```text
[CSV files] → Import/Normalize → LedgerEvents
                    ↓
            Transfer Matching (user confirm)
                    ↓
         PolicyBundle + FX table
                    ↓
    ┌───────────────────────────────────┐
    │  LedgerReplay / CostBasisEngine   │
    │  DeemedCost (2026-12-31 max)      │
    │  TaxAggregator + HoldingsSnapshot │
    └─────────────────┬─────────────────┘
                      ↓
              IntegrityVerifier
                 ╱         ╲
              fail          pass
               ↓             ↓
           blocked      PublishedReport
           (no export)  (UI + export)
```

상세: [05-pipelines.md](./05-pipelines.md), [09-import-and-matching.md](./09-import-and-matching.md), [../04-import-formats.md](../04-import-formats.md)

---

## 6. 계정·원가 이원 구조 (아키 수준)

```text
Project
  ├─ Account(Bithumb)     method=movingAverage
  ├─ Account(Binance)     method=fifo
  └─ Account(OKX)         method=fifo

TransferLink(confirmed): Bithumb.USDT out → Binance.USDT in
  → Cost moves per TransferCostPolicy (default: abandon lost cost)
```

원가 엔진은 **계정×자산** 원장을 시간순 재생한다. 전역 단일 원장 없음.

---

## 7. 정책 레이어 (교체 지점)

세법 해석이 바뀔 수 있는 부분은 **하드코딩 금지**, `PolicyBundle`로 주입:

| Policy | v1 기본 | 교체 시나리오 |
|--------|---------|----------------|
| `TransferCostPolicy` | AbandonLostCost (미공제) | 공식 해설 시 AllocateToArrival / DeductAsExpense |
| `CostMethodResolver` | 빗썸 MA / 해외 FIFO | 총평균 등으로 법령 변경 |
| `DeemedCostPolicy` | max(book, market) @ 2026-12-31 | 기준일·시가 정의 변경 |
| `TaxRatePolicy` | 20%+2%, 공제 250만 | 개정 |
| `RoundingPolicy` | 공유 반올림 | 국세 원단위 규칙 확정 시 |
| `FXPolicy` | USDT=USD, 기준환율 | 페그·소스 변경 |

상세: [04-policies.md](./04-policies.md)

---

## 8. 배포·런타임 환경

| 항목 | 값 |
|------|-----|
| OS | macOS 15.0+ |
| UI | SwiftUI |
| 저장 | SwiftData (Application Support) |
| 네트워크 | 기본 OFF; FX fetch 옵트인 |
| 배포 | 로컬 빌드 개인 사용 |

---

## 9. 관련 문서

- 모듈: [02-module-structure.md](./02-module-structure.md)  
- 도메인: [03-domain-model.md](./03-domain-model.md)  
- 결정: [../05-decisions.md](../05-decisions.md)  
