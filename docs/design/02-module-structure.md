# 02. 모듈·폴더 구조

| 버전 | 2.0 |
|------|-----|

---

## 1. v1 타깃 전략

| 선택 | 이유 |
|------|------|
| **단일 app 타깃 + 폴더 경계** | YAGNI, 개인 로컬 앱 |
| Domain / **Import** 논리 분리 | PDF·XLSX·CSV 파서 확장 |
| 추후 SPM 분리 가능 | 폴더 이름 그대로 패키지로 승격 |

`CoinTaxTests`는 Domain 엔진·Verifier·파서를 집중 테스트.

---

## 2. 실제 소스 트리 (2026-08-11 기준)

> 아래는 **현재 저장소의 실제 파일 목록**이다. 설계상 분리를 예정했던 파일 중
> 실제로는 하나로 합쳐진 것이 있으므로(예: MA/FIFO 는 `AssetBook.swift` 안에, 검증기는 `Verifier.swift` 하나로)
> 이 문서를 정본으로 본다.

```text
CoinTax/
├── App/
│   ├── CoinTaxApp.swift                 # 저장소 열기 실패 시 메모리 모드 + 경고
│   ├── AppEnvironment.swift             # DI 컨테이너
│   └── Navigation/RootSplitView.swift
├── Features/
│   ├── Dashboard/DashboardView.swift
│   ├── Import/ImportView.swift · GenericMappingSheet.swift
│   ├── Ledger/LedgerView.swift
│   ├── Matching/MatchingView.swift      # 후보·수동 연결·연결 해제
│   ├── Holdings/HoldingsView.swift
│   ├── Report/ReportView.swift
│   └── Settings/SettingsView.swift
├── Application/
│   ├── ImportService.swift              # 파일 해시 중복 차단 포함
│   ├── MatchingService.swift            # confirm / linkManually / unlink
│   ├── CalculationPipeline.swift        # calc → verify → 스냅샷(최근 10개)
│   ├── FXService.swift
│   └── ProjectService.swift
├── Domain/                              # 순수 — SwiftUI/SwiftData import 금지
│   ├── Models/ Project · Account · LedgerEvent · TransferLink · Money
│   │           Identifiers · TaxTime · TaxModels · FXAndMarket
│   ├── Policies/ PolicyBundle · TransferCostPolicy ★ · CostMethodResolver
│   │             DeemedCostPolicy · TaxRatePolicy · RoundingPolicy
│   │             FXAssumptionPolicy · TaxCopy
│   ├── CostBasis/ AssetBook.swift        # MovingAverageBook + FIFOBook + disposeClamped
│   │              CostBasisEngine.swift  # replay 전체 루프 + 이슈 수집
│   ├── Tax/TaxAggregator.swift
│   ├── Holdings/HoldingsSnapshot.swift
│   ├── FX/FXHolidayPolicy.swift          # 미고시일 → 직전 고시일 (단일 지점)
│   └── Integrity/Verifier.swift          # V-* 전체
├── Import/
│   ├── Probe/FormatProbe.swift           # pdf 본문·xlsx 헤더까지 확인
│   ├── Parsing/ ExchangeDocumentParser · ParserRegistry · ParseResult
│   │            CSVUtil (headerIndex · stripBOM · readText) · Fingerprint · XLSXReader
│   ├── Parsers/ Bithumb/ · Binance/(Spot·Deposit·Withdraw) · OKX/(Trading·Funding) · Generic/
│   └── Matching/TransferMatchingEngine.swift   # 1:1 배정 · 거부 유지
├── Data/
│   ├── SwiftData/ ModelContainer+CoinTax.swift · Entities/Entities.swift
│   └── Mappers/EntityMappers.swift
└── Infrastructure/
    ├── FX/ ECOSFXClient.swift (+ PublicUSDKRWClient · CompositeFXClient)
    │        FXKeychain.swift · LocalFXCache.swift (FXClient · FXPreferences)
    └── Export/ ReportCSVExporter.swift · ReportPDFExporter.swift (다중 페이지)
```

**Xcode 프로젝트는 file-system synchronized group 을 쓴다** — 폴더에 `.swift` 를 추가하면 자동 포함된다.

---

## 2.1 (참고) 초기 설계안 트리

```text
CoinTax/
├── App/
│   ├── CoinTaxApp.swift
│   ├── AppEnvironment.swift          # DI 컨테이너 (services, policies)
│   └── Navigation/
│       └── RootSplitView.swift
├── Features/
│   ├── Dashboard/
│   ├── Import/
│   ├── Ledger/
│   ├── Matching/
│   ├── Holdings/
│   ├── Report/
│   └── Settings/
├── Application/
│   ├── ImportService.swift
│   ├── MatchingService.swift
│   ├── CalculationPipeline.swift     # calc + verify orchestration
│   ├── FXService.swift
│   ├── HoldingsService.swift
│   ├── ReportExportService.swift
│   └── ProjectService.swift
├── Domain/
│   ├── Models/
│   │   ├── Project.swift
│   │   ├── Account.swift
│   │   ├── LedgerEvent.swift
│   │   ├── TransferLink.swift
│   │   ├── Money.swift
│   │   └── Identifiers.swift
│   ├── Policies/
│   │   ├── PolicyBundle.swift
│   │   ├── TransferCostPolicy.swift  # ★ 교체 포인트
│   │   ├── CostMethodResolver.swift
│   │   ├── DeemedCostPolicy.swift
│   │   ├── TaxRatePolicy.swift
│   │   ├── RoundingPolicy.swift
│   │   └── FXAssumptionPolicy.swift
│   ├── CostBasis/
│   │   ├── CostBasisEngine.swift
│   │   ├── MovingAverageBook.swift
│   │   ├── FIFOBook.swift
│   │   └── TransferApplier.swift
│   ├── Tax/
│   │   ├── DeemedCostApplier.swift
│   │   ├── TaxAggregator.swift
│   │   └── TaxYearSummary.swift
│   ├── Holdings/
│   │   └── HoldingsSnapshot.swift
│   └── Integrity/
│       ├── VerificationReport.swift
│       ├── LedgerVerifier.swift
│       ├── TaxVerifier.swift
│       └── DeterminismChecker.swift
├── Import/                             # 멀티 포맷 (CSV 전용 아님)
│   ├── Probe/FormatProbe.swift
│   ├── Parsing/
│   │   ├── ExchangeDocumentParser.swift
│   │   ├── ParserRegistry.swift
│   │   └── ParseResult.swift
│   ├── Parsers/
│   │   ├── Bithumb/BithumbCertificatePDFParser.swift
│   │   ├── Binance/BinanceSpotXLSXParser.swift
│   │   ├── Binance/BinanceDepositXLSXParser.swift
│   │   ├── Binance/BinanceWithdrawXLSXParser.swift
│   │   ├── OKX/OKXTradingHistoryCSVParser.swift
│   │   ├── OKX/OKXFundingHistoryCSVParser.swift
│   │   └── Generic/GenericTabularMapper.swift
│   └── Matching/TransferMatchingEngine.swift
├── Data/
│   ├── SwiftData/
│   │   ├── ModelContainer+CoinTax.swift
│   │   └── Entities/
│   ├── Repositories/
│   └── Mappers/
├── Infrastructure/
│   ├── FX/
│   │   ├── FXProvider.swift
│   │   ├── LocalFXCache.swift
│   │   └── RemoteFXClient.swift      # 옵트인
│   └── Export/
│       └── ReportCSVExporter.swift
└── Resources/
```

---

## 3. 의존 규칙

```text
Features  → Application, Domain(읽기 모델)
Application → Domain, Data(protocols)
Data / Infrastructure → Domain
Domain → (없음)
CSV → Domain drafts only
```

| 금지 |
|------|
| Domain에서 SwiftUI import |
| Domain에서 SwiftData `@Model` 직접 사용 |
| Feature에서 원가 공식 중복 구현 |
| Verifier가 Engine private 상태에만 의존 |

---

## 4. DI (`AppEnvironment`)

```swift
struct AppEnvironment {
    var policies: PolicyBundle           // 기본 = PolicyBundle.v1Default
    var importService: ImportService
    var matchingService: MatchingService
    var pipeline: CalculationPipeline
    var fxService: FXService
    var projectStore: ProjectRepository
}
```

- 설정 화면에서 **정책 프리셋 표시**(읽기 전용 + 고지).  
- v1 UI에서 전송 수수료 정책을 사용자가 마음대로 바꾸게 하지 않아도 됨.  
- **코드/설정 한곳**(`PolicyBundle.v1Default`)만 바꾸면 전 파이프라인 반영.  
- 리포트에 `policyBundleID` + 각 policy `id` 기록 → 과거 결과 재현.

---

## 5. 확장 시나리오

| 변화 | 손대는 곳 |
|------|-----------|
| 새 거래소·서류 | `Import/Parsers/*` + Registry |
| 전송 수수료 세법 확정 | `TransferCostPolicy` 구현체 추가 + default 교체 + 테스트 |
| 총평균법 도입 | `CostBasis` 새 Book + Resolver |
| 환율 벤더 변경 | `RemoteFXClient` 구현 교체 |

---

## 6. 다음

[03-domain-model.md](./03-domain-model.md)
