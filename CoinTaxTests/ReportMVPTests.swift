import XCTest
@testable import CoinTax

final class ReportMVPTests: XCTestCase {
    func testPolicyBundleAndTaxCopyLocked() {
        let p = PolicyBundle.v1Default
        XCTAssertEqual(p.id, "cointax-v1.0")
        XCTAssertEqual(p.disclaimers.count, 4)
        XCTAssertEqual(p.disclaimers[0], TaxCopy.notTaxAdvice)
        XCTAssertEqual(p.disclaimers[1], TaxCopy.transferCost)
        XCTAssertEqual(p.disclaimers[2], TaxCopy.usdtPeg)
        XCTAssertEqual(p.disclaimers[3], TaxCopy.costMethods)
        XCTAssertEqual(p.transferCost.id, "abandon_lost_cost")
    }

    func testTaxYearSummaryFieldsForMVP() {
        let policies = PolicyBundle.v1Default
        let disp = DisposalRecord(
            id: UUID(), eventID: EventID(), timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            accountID: AccountID(), asset: AssetSymbol("USDT"), quantity: 1,
            proceedsKRW: 10_000_000, costKRW: 1_000_000, feesKRW: 0, pnlKRW: 9_000_000,
            method: .fifo, taxYear: 2027
        )
        let s = TaxAggregator.aggregate(
            projectID: ProjectID(), disposals: [disp], taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 100, deemed: [], policies: policies
        )
        XCTAssertEqual(s.totalProceedsKRW, 10_000_000)
        XCTAssertEqual(s.totalCostsKRW, 1_000_000)
        XCTAssertEqual(s.netIncomeKRW, 9_000_000)
        XCTAssertEqual(s.basicDeductionKRW, 2_500_000)
        XCTAssertEqual(s.taxBaseKRW, 6_500_000)
        XCTAssertEqual(s.nationalTaxKRW, 1_300_000)
        XCTAssertEqual(s.localTaxKRW, 130_000)
        XCTAssertEqual(s.totalTaxKRW, 1_430_000)
        XCTAssertEqual(s.abandonedTransferCostKRW, 100)
    }
}
