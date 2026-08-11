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
}

struct DeemedPosition: Codable, Sendable {
    var accountID: AccountID
    var asset: AssetSymbol
    var quantity: Decimal
    var bookUnitKRW: Decimal
    var marketUnitKRW: Decimal?
    var deemedUnitKRW: Decimal
    var reason: String
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
    var disposals: [DisposalRecord]
    var deemed: [DeemedPosition]
    var disclaimers: [String]
    var calculatedAt: Date
    var verification: VerificationReport?
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
    var warnings: [String]
    var transferCostDetails: [TransferCostDetail]
    var missingMarketAssets: [AssetSymbol]
    var missingFXDays: [String]
    /// 휴일·미고시 대체 적용 기록 (V-FX-03)
    var fxResolutions: [FXResolvedRate]
}

struct TransferCostDetail: Sendable {
    var linkID: LinkID
    var outboundCostKRW: Decimal
    var transferredCostKRW: Decimal
    var abandonedCostKRW: Decimal
    var deductibleExpenseKRW: Decimal
    var ratio: Decimal
}
