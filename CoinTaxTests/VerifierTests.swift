import XCTest
@testable import CoinTax

final class VerifierTests: XCTestCase {
    func testFailClosedOnTaxBaseMismatch() {
        let policies = PolicyBundle.v1Default
        var summary = TaxYearSummary(
            projectID: ProjectID(),
            taxYear: 2027,
            status: .draft,
            policyBundleID: policies.id,
            totalProceedsKRW: 100,
            totalCostsKRW: 0,
            netIncomeKRW: 100,
            basicDeductionKRW: 2_500_000,
            taxBaseKRW: 999, // wrong
            nationalTaxKRW: 0,
            localTaxKRW: 0,
            totalTaxKRW: 0,
            abandonedTransferCostKRW: 0,
            disposals: [],
            deemed: [],
            disclaimers: policies.disclaimers,
            calculatedAt: Date(),
            verification: nil
        )
        let replay = ReplayResult(
            disposals: [], holdings: HoldingsBuilder.empty(), deemedPositions: [],
            abandonedTotal: 0, extraDeductible: 0, warnings: [], transferCostDetails: [],
            missingMarketAssets: [], missingFXDays: []
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: policies, events: [], summaryRerun: summary
        ))
        XCTAssertEqual(report.status, "failed")
        XCTAssertTrue(report.issues.contains { $0.id == "V-TAX-02" })
        XCTAssertFalse(report.isExportAllowed)
        summary.verification = report
        XCTAssertThrowsError(try ReportCSVExporter.exportCSV(summary))
    }

    func testAbandonNotDeductibleCritical() {
        let policies = PolicyBundle.v1Default
        let summary = TaxYearSummary(
            projectID: ProjectID(), taxYear: 2027, status: .draft, policyBundleID: policies.id,
            totalProceedsKRW: 0, totalCostsKRW: 0, netIncomeKRW: 0, basicDeductionKRW: 2_500_000,
            taxBaseKRW: 0, nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
            abandonedTransferCostKRW: 100, disposals: [], deemed: [], disclaimers: [],
            calculatedAt: Date(), verification: nil
        )
        let detail = TransferCostDetail(
            linkID: LinkID(), outboundCostKRW: 100, transferredCostKRW: 90,
            abandonedCostKRW: 10, deductibleExpenseKRW: 10, ratio: Decimal(string: "0.9")!
        )
        let replay = ReplayResult(
            disposals: [], holdings: HoldingsBuilder.empty(), deemedPositions: [],
            abandonedTotal: 100, extraDeductible: 10, warnings: [], transferCostDetails: [detail],
            missingMarketAssets: [], missingFXDays: []
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: policies, events: [], summaryRerun: summary
        ))
        XCTAssertEqual(report.status, "failed")
        XCTAssertTrue(report.issues.contains { $0.id == "V-COST-03" })
    }
}
