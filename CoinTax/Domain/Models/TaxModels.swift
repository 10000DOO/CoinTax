import Foundation

struct DisposalRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var eventID: EventID
    var timestamp: Date
    var accountID: AccountID
    var asset: AssetSymbol
    var quantity: Decimal
    var proceedsKRW: Decimal
    var costKRW: Decimal
    var feesKRW: Decimal
    var pnlKRW: Decimal
    var method: CostBasisMethod
    var taxYear: Int
    // --- 감사 추적 (06-integrity §2.3) ---
    /// 양도가 환산에 쓴 USD/KRW (원화 직기입이면 nil)
    var fxRateUsed: Decimal? = nil
    /// 그 환율의 실제 고시일 (휴일 대체 시 직전 고시일)
    var fxSourceDate: String? = nil
    /// 이 자산 장부가 의제취득가로 재기동된 뒤의 처분인지
    var deemedApplied: Bool = false
}

struct DeemedPosition: Codable, Sendable {
    var accountID: AccountID
    var asset: AssetSymbol
    var quantity: Decimal
    var bookUnitKRW: Decimal
    var marketUnitKRW: Decimal?
    /// 채택 단가 (건별 방식이면 lot 가중 평균)
    var deemedUnitKRW: Decimal
    var reason: String
    /// 어느 비교 단위를 썼는지 (TQ-01)
    var basisMode: String = DeemedBasisMode.positionAverage.rawValue
    /// 재기동된 lot 개수 (건별 방식 확인용)
    var lotCount: Int = 1

    var totalDeemedKRW: Decimal { deemedUnitKRW * quantity }
}

/// 다른 의제 산정 방식으로 계산했을 때의 결과 (TQ-01 비교 표시용)
struct DeemedAlternative: Codable, Sendable {
    var basisMode: String
    var basisLabel: String
    var totalDeemedCostKRW: Decimal
    var netIncomeKRW: Decimal
    var totalTaxKRW: Decimal
}

struct HoldingsRow: Codable, Sendable {
    var accountID: AccountID?
    var asset: AssetSymbol
    var quantity: Decimal
    var averageUnitKRW: Decimal
    var totalCostKRW: Decimal
    var method: CostBasisMethod?
}

struct HoldingsSnapshot: Codable, Sendable {
    var asOf: Date
    var rows: [HoldingsRow]
    var aggregated: [HoldingsRow]
}

struct TaxYearSummary: Codable, Sendable {
    var projectID: ProjectID
    var taxYear: Int
    var status: SummaryStatus
    var policyBundleID: String
    var totalProceedsKRW: Decimal
    var totalCostsKRW: Decimal
    var netIncomeKRW: Decimal
    var basicDeductionKRW: Decimal
    var taxBaseKRW: Decimal
    var nationalTaxKRW: Decimal
    var localTaxKRW: Decimal
    var totalTaxKRW: Decimal
    var abandonedTransferCostKRW: Decimal
    /// 이 과세연도에 필요경비로 더한 전송 관련 추가 공제 (기본 정책에서는 0)
    var extraDeductibleKRW: Decimal = 0
    var disposals: [DisposalRecord]
    var deemed: [DeemedPosition]
    var disclaimers: [String]
    var calculatedAt: Date
    var verification: VerificationReport?
    /// 사용한 환율 출처 요약 (리포트·export 노출). 휴일 대체분은 실제 고시일을 함께 적는다.
    var fxSources: [String] = []
    /// 채택한 의제 산정 방식
    var deemedBasisMode: String = DeemedBasisMode.positionAverage.rawValue
    /// 다른 방식으로 계산했을 때의 결과 (TQ-01 미결이므로 항상 함께 보여준다)
    var deemedAlternative: DeemedAlternative? = nil
    /// `[법]` §37⑥ 필요경비 의제 50% 를 켠 자산 (없으면 빈 배열)
    var proxyExpenseAssets: [String] = []
    /// 그 의제를 **끄고** 계산했을 때의 값 — 「할 수 있다」라 유리한 쪽을 고르려면 둘 다 필요하다
    var proxyExpenseAlternative: DeemedAlternative? = nil

    /// 채택 방식의 의제 취득가 총액
    var totalDeemedCostKRW: Decimal {
        deemed.reduce(Decimal(0)) { $0 + $1.totalDeemedKRW }
    }
}

struct VerificationIssue: Codable, Identifiable, Sendable {
    var id: String
    var severity: String
    var message: String
    var context: String?
}

struct VerificationReport: Codable, Sendable {
    var runID: UUID
    var status: String
    var issues: [VerificationIssue]
    var calculatedAt: Date

    var isExportAllowed: Bool {
        status == "passed" || status == "passedWithWarnings"
    }
}

struct ReplayResult: Sendable {
    var disposals: [DisposalRecord]
    var holdings: HoldingsSnapshot
    var deemedPositions: [DeemedPosition]
    var abandonedTotal: Decimal
    var extraDeductible: Decimal
    /// 과세연도별 전송 소실 원가 · 추가 공제.
    ///
    /// 전 기간 합계를 특정 연도 소득에서 빼면 **다른 해 비용이 이 해 소득을 깎는다.**
    /// 기본 정책(`abandon_lost_cost`)에서는 추가 공제가 0이라 드러나지 않지만,
    /// 예약된 `deduct_as_expense` 로 바꾸면 바로 틀린 세액이 나온다.
    var abandonedByYear: [Int: Decimal] = [:]
    var extraDeductibleByYear: [Int: Decimal] = [:]
    var warnings: [String]
    var transferCostDetails: [TransferCostDetail]
    var missingMarketAssets: [AssetSymbol]
    var missingFXDays: [String]
    /// 휴일·미고시 대체 적용 기록 (V-FX-03)
    var fxResolutions: [FXResolvedRate]
    /// 엔진이 계산을 **중단하지 않고** 수집한 문제. 검증기가 그대로 병합한다.
    /// (재고 부족·환산 불가 등을 예외로 던지면 fail-closed 이슈 목록이 만들어지지 않는다 — 리뷰 1-7)
    var issues: [VerificationIssue] = []
    /// 사용한 환율 출처 요약 (design/08-fx-service §6 "리포트: 사용 환율 출처 요약")
    var fxUsageNotes: [String] = []
    /// 의제취득가로 재기동된 (계정, 자산) 키 — 감사 추적용
    var deemedAppliedKeys: Set<String> = []
    /// 재고가 부족해 **처분하지 못한 수량**을 (계정|자산)별로 모은 것.
    ///
    /// 수량 대조(V-QTY-01)는 이 값만큼만 차이를 봐준다.
    /// 예전에는 「부족이 났던 자산」을 통째로 면제했다 — 거래소 반올림 수준의
    /// 1e-8 짜리 먼지(앱이 「정상」으로 보는 값) 하나만 나도 그 자산의 마지막 그물이 꺼졌다.
    /// 바이낸스는 거래소 잔고 열이 없어 V-BAL 도 없으므로 그러면 아무도 못 잡는다.
    var shortfallQtyByKey: [String: Decimal] = [:]

    /// 과세 시작(2027-01-01 0시)**까지의** 부족량. 의제 스냅샷 수량 대조(V-DEM-01)가 쓴다 —
    /// 전체 기간 부족량을 쓰면 2027 이후에 난 부족까지 봐주게 되어 스냅샷의 진짜 차이를 놓친다.
    var preTaxShortfallQtyByKey: [String: Decimal] = [:]

    /// 과세 시작 시점에 **아직 도착하지 않은 전송**의 수량을 (도착 계정|자산)별로 모은 것.
    ///
    /// 이 수량은 어느 계정 장부에도 없지만 거주자는 보유하고 있어 의제취득가 대상이다(§37⑤).
    /// 검증기가 이걸 모르면 「스냅샷 수량이 이벤트 합과 다르다」로 정상 계산을 막는다.
    var inFlightQtyByKey: [String: Decimal] = [:]

    /// 재고가 부족했던 (계정|자산) 키
    var shortfallKeys: Set<String> { Set(shortfallQtyByKey.keys) }
}

struct TransferCostDetail: Sendable {
    var linkID: LinkID
    var outboundCostKRW: Decimal
    var transferredCostKRW: Decimal
    var abandonedCostKRW: Decimal
    var deductibleExpenseKRW: Decimal
    var ratio: Decimal
}
