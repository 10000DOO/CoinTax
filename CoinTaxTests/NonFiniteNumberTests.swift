import XCTest
@testable import CoinTax

/// 숫자가 **값이 아닌 것**(NaN)이 되면 어떻게 되는가 (5차 감사 회차 34).
///
/// `Decimal` 은 자릿수를 넘기면 오류를 내지 않고 조용히 `NaN` 이 된다. 그리고 `NaN` 은
/// 어떤 비교에서도 `false` 를 돌려준다 — 그래서 **모든 검사를 그냥 통과한다.**
///
/// 하필 세액 계산의 마지막 단계가 `max(0, 소득 − 공제)` 다.
/// `max(0, NaN)` 은 **0** 이므로 결과는 **세액 0원**이 된다.
/// 즉 어딘가에서 자릿수가 넘치면 **세금이 0원으로 조용히 나온다.**
final class NonFiniteNumberTests: XCTestCase {

    /// **집계기를 그대로 통과시켜** 만든다.
    ///
    /// 요약의 한 칸만 손으로 NaN 으로 바꾸면 다른 칸과 어긋나서 엉뚱한 검사(V-TAX-02)가 걸린다 —
    /// 실제 자릿수 넘침에서는 소득·과세표준·세액이 **모두 NaN 에서 유도되어 서로 맞는다.**
    /// 그 상태를 그대로 재현해야 「아무도 못 잡는다」를 확인할 수 있다.
    private func summary(overflowed: Bool) -> TaxYearSummary {
        let pid = ProjectID()
        let proceeds: Decimal = overflowed ? Decimal.nan : 60_000_000
        let pnl: Decimal = overflowed ? Decimal.nan : 20_000_000
        let d = DisposalRecord(
            id: UUID(), eventID: EventID(),
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            accountID: AccountID(), asset: AssetSymbol("BTC"), quantity: 1,
            proceedsKRW: proceeds, costKRW: 40_000_000, feesKRW: 0,
            pnlKRW: pnl, method: .fifo, taxYear: 2027
        )
        return TaxAggregator.aggregate(
            projectID: pid, disposals: [d], taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: [], policies: .v1Default
        )
    }

    private func verify(_ s: TaxYearSummary) -> VerificationReport {
        Verifier.verify(VerifierInput(
            summary: s,
            replay: ReplayResult(
                disposals: s.disposals, holdings: HoldingsSnapshot(asOf: Date(), rows: [], aggregated: []),
                deemedPositions: [], abandonedTotal: 0, extraDeductible: 0, warnings: [],
                transferCostDetails: [], missingMarketAssets: [], missingFXDays: [], fxResolutions: []
            ),
            policies: .v1Default, events: [], summaryRerun: s, links: []
        ))
    }

    /// 먼저 사실 확인 — `max(0, NaN)` 은 0 이고, 그래서 세액이 0 이 된다
    func testNaNCollapsesTaxToZero() {
        let p = KROtherIncomeTaxRatePolicy()
        let computed = p.compute(incomeKRW: Decimal.nan, rounding: PlainKRWRoundingPolicy())
        XCTAssertEqual(computed.taxBaseKRW, 0, "max(0, NaN) 이 0 이 된다는 사실을 고정한다")
        XCTAssertEqual(computed.totalTaxKRW, 0, "즉 세액이 0원으로 나온다")
    }

    /// 그 상태를 **검증기가 잡아야** 한다 — 안 잡으면 세금 0원짜리 신고자료가 나간다
    func testNonFiniteSummaryIsBlocked() {
        let bad = summary(overflowed: true)
        // 자릿수가 넘치면 세액이 0 으로 접힌다 — 그 사실부터 고정한다
        XCTAssertEqual(bad.taxBaseKRW, 0)
        XCTAssertEqual(bad.totalTaxKRW, 0)

        let report = verify(bad)
        XCTAssertTrue(
            report.issues.contains { $0.severity == "critical" },
            "소득금액이 값이 아닌데 어떤 검사도 걸리지 않았다 — 세액 0원짜리 신고자료가 나간다: \(report.issues.map(\.id))"
        )
        XCTAssertFalse(report.isExportAllowed, "이 상태로 신고자료가 나가면 안 된다")
    }

    /// 멀쩡한 요약은 그대로 통과해야 한다 (오탐 방지)
    func testFiniteSummaryStaysQuiet() {
        let ok = summary(overflowed: false)
        XCTAssertFalse(verify(ok).issues.contains { $0.id == "V-TAX-07" })
    }
}
