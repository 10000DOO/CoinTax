import XCTest
@testable import CoinTax

/// V-COST-03 필요경비 합계 검사가 **실제로 불일치를 잡는지** 확인한다.
///
/// 감사 G-1: 예전에는 요약(`s.disposals`)으로 다시 더해 요약(`s.totalCostsKRW`)과 비교했다.
/// 집계기가 그 값을 만드는 식과 글자 하나까지 같아서 **정의상 실패할 수 없는 검사**였다.
/// 이제 엔진 결과에서 다시 더하므로, 집계가 틀어지면 잡힌다.
final class CostSumCheckTests: XCTestCase {

    private func scenario() throws -> (ReplayResult, TaxYearSummary) {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        let buy = LedgerEvent(
            projectID: pid, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 2, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "s1"
        )
        let sell = LedgerEvent(
            projectID: pid, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 70_000_000, sourceKind: "t", rawRef: "s2"
        )
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: [:], marketPrices: [:]
        )
        let r = try engine.replay(events: [buy, sell], links: [])
        let s = TaxAggregator.aggregate(
            projectID: pid, disposals: r.disposals, taxYear: 2027,
            extraDeductible: r.extraDeductibleByYear[2027] ?? 0,
            abandonedTransferCostKRW: r.abandonedByYear[2027] ?? 0,
            deemed: r.deemedPositions, policies: .v1Default
        )
        return (r, s)
    }

    private func verify(_ r: ReplayResult, _ s: TaxYearSummary) -> VerificationReport {
        Verifier.verify(VerifierInput(summary: s, replay: r, policies: .v1Default,
                                      events: [], summaryRerun: s))
    }

    func testNormalDataPasses() throws {
        let (r, s) = try scenario()
        XCTAssertFalse(s.disposals.isEmpty, "비교할 처분이 있어야 검사가 의미를 갖는다")
        XCTAssertFalse(verify(r, s).issues.contains { $0.id == "V-COST-03" })
    }

    /// 필요경비 합계가 틀어지면 잡아야 한다 — 소실 원가가 섞여 들어가는 경로가 이렇게 보인다.
    func testInflatedTotalCostIsCaught() throws {
        let (r, s) = try scenario()
        var broken = s
        broken.totalCostsKRW += 1_000_000
        let report = verify(r, broken)
        XCTAssertTrue(report.issues.contains { $0.id == "V-COST-03" && $0.severity == "critical" },
                      "필요경비 과대 계상을 놓쳤다")
    }

    /// 처분 건수가 엔진 결과와 다르면 잡아야 한다 (연도 필터가 틀어진 경우).
    func testDroppedDisposalIsCaught() throws {
        let (r, s) = try scenario()
        var broken = s
        broken.disposals = []
        let report = verify(r, broken)
        XCTAssertTrue(report.issues.contains { $0.id == "V-COST-03" },
                      "건수 불일치를 놓쳤다")
    }
}
