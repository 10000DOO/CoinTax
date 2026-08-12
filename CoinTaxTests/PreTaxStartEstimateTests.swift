import XCTest
@testable import CoinTax

/// 2027 과세 시작 전에도 「지금까지 손익 + 27년 규정 적용 시 세금」이 나와야 한다.
///
/// 그전에는 2027년 처분만 집계해서 리포트가 늘 0원이었고, 존재할 수도 없는
/// 2027-01-01 시가를 요구하며 신고자료를 잠갔다.
final class PreTaxStartEstimateTests: XCTestCase {

    private func disposal(year: Int, proceeds: Decimal, cost: Decimal) -> DisposalRecord {
        DisposalRecord(
            id: UUID(),
            eventID: EventID(),
            timestamp: TaxTime.dateKST(year: year, month: 6, day: 1, hour: 12),
            accountID: AccountID(),
            asset: AssetSymbol("BTC"),
            quantity: 1,
            proceedsKRW: proceeds,
            costKRW: cost,
            feesKRW: 0,
            pnlKRW: proceeds - cost,
            method: .fifo,
            taxYear: year
        )
    }

    private func aggregate(_ year: Int, _ ds: [DisposalRecord]) -> TaxYearSummary {
        TaxAggregator.aggregate(
            projectID: ProjectID(), disposals: ds, taxYear: year,
            extraDeductible: 0, abandonedTransferCostKRW: 0, deemed: [], policies: .v1Default
        )
    }

    // MARK: 집계

    /// 과세 시작 전 연도를 고르면 그해 실제 처분이 그대로 잡힌다.
    func testPreStartYearAggregatesActualDisposals() {
        let ds = [disposal(year: 2026, proceeds: 10_000_000, cost: 4_000_000)]
        let s = aggregate(2026, ds)
        XCTAssertEqual(s.disposals.count, 1)
        XCTAssertEqual(s.netIncomeKRW, 6_000_000)
        // 기본공제 250만 → 과세표준 350만 → 22%
        XCTAssertEqual(s.basicDeductionKRW, 2_500_000)
        XCTAssertEqual(s.taxBaseKRW, 3_500_000)
        XCTAssertEqual(s.totalTaxKRW, 770_000)
    }

    /// 과세연도(2027)는 예전 그대로 — 과세 시작 전 처분이 섞여 들어오면 안 된다.
    func testTaxYearStillExcludesPreStartDisposals() {
        let s = aggregate(2027, [disposal(year: 2026, proceeds: 10_000_000, cost: 4_000_000)])
        XCTAssertTrue(s.disposals.isEmpty)
        XCTAssertEqual(s.totalTaxKRW, 0)
    }

    /// 연도별로 따로 잡힌다 (기본공제가 해마다 붙으므로 합산하면 세금이 달라진다).
    func testYearsAreSeparate() {
        let ds = [disposal(year: 2025, proceeds: 5_000_000, cost: 1_000_000),
                  disposal(year: 2026, proceeds: 9_000_000, cost: 2_000_000)]
        XCTAssertEqual(aggregate(2025, ds).netIncomeKRW, 4_000_000)
        XCTAssertEqual(aggregate(2026, ds).netIncomeKRW, 7_000_000)
    }

    /// 손익이 기본공제 이하면 세금 0.
    func testUnderBasicDeductionIsZeroTax() {
        let s = aggregate(2026, [disposal(year: 2026, proceeds: 3_000_000, cost: 1_500_000)])
        XCTAssertEqual(s.netIncomeKRW, 1_500_000)
        XCTAssertEqual(s.totalTaxKRW, 0)
    }

    // MARK: 과세 시작 판정

    // MARK: 검증기

    /// 예상 연도는 과세 시작 전 처분을 **일부러** 담는다 — V-TAX-05 로 막으면 안 된다.
    func testPreviewYearIsNotBlockedByPreStartRule() {
        let s = aggregate(2026, [disposal(year: 2026, proceeds: 10_000_000, cost: 4_000_000)])
        let replay = ReplayResult(
            disposals: s.disposals, holdings: HoldingsBuilder.empty(), deemedPositions: [],
            abandonedTotal: 0, extraDeductible: 0, warnings: [], transferCostDetails: [],
            missingMarketAssets: [], missingFXDays: [], fxResolutions: []
        )
        let report = Verifier.verify(VerifierInput(
            summary: s, replay: replay, policies: .v1Default,
            events: [], summaryRerun: s, links: []
        ))
        XCTAssertFalse(report.issues.contains { $0.id == "V-TAX-05" },
                       "예상 연도에서 과세 시작 전 처분을 막으면 손익을 볼 수 없다")
    }

    func testIsBeforeTaxStartBoundary() {
        XCTAssertTrue(TaxTime.isBeforeTaxStart(TaxTime.dateKST(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 59)))
        XCTAssertFalse(TaxTime.isBeforeTaxStart(TaxTime.dateKST(year: 2027, month: 1, day: 1)))
        XCTAssertFalse(TaxTime.isBeforeTaxStart(TaxTime.dateKST(year: 2028, month: 5, day: 3)))
    }
}
