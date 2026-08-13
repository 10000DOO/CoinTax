import XCTest
@testable import CoinTax

/// 신고서에 옮겨 적는 **세 숫자**가 서로 맞는지 검사가 실제로 도는가 (5차 감사 회차 20).
///
/// 리포트 화면·CSV·PDF 에는 「총수입금액 − 필요경비 = 소득금액」이 나란히 찍힌다.
/// 예전 `V-TAX-01` 은 `Σ pnl − 추가공제` 를 `netIncomeKRW` 와 비교했는데,
/// 집계기가 소득금액을 **글자 그대로 같은 식**으로 만들어서 **실패할 수 없는 검사**였다
/// (3차 감사 G-1 과 같은 모양). 이제 세 숫자를 묶어서 본다 — 그게 사용자가 보는 표다.
final class HeadlineNumbersTests: XCTestCase {

    private func summary(proceeds: Decimal, cost: Decimal, fees: Decimal) -> TaxYearSummary {
        let pid = ProjectID()
        let d = DisposalRecord(
            id: UUID(), eventID: EventID(),
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            accountID: AccountID(), asset: AssetSymbol("BTC"), quantity: 1,
            proceedsKRW: proceeds, costKRW: cost, feesKRW: fees,
            pnlKRW: proceeds - cost - fees, method: .fifo, taxYear: 2027
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
            replay: ReplayResult(disposals: s.disposals, holdings: HoldingsSnapshot(asOf: Date(), rows: [], aggregated: []), deemedPositions: [],
                                 abandonedTotal: 0, extraDeductible: 0, warnings: [],
                                 transferCostDetails: [], missingMarketAssets: [], missingFXDays: [],
                                 fxResolutions: []),
            policies: .v1Default, events: [], summaryRerun: s, links: []
        ))
    }

    /// 멀쩡한 요약에서는 조용해야 한다 (오탐 방지)
    func testConsistentSummaryIsQuiet() {
        let s = summary(proceeds: 60_000_000, cost: 40_000_000, fees: 100_000)
        XCTAssertEqual(s.netIncomeKRW, 19_900_000)
        XCTAssertFalse(verify(s).issues.contains { $0.id == "V-TAX-01" })
    }

    /// **필요경비만 어긋나면** 잡아야 한다.
    ///
    /// 옛 검사는 `Σ pnl` 만 봤으므로 필요경비 칸이 틀려도 절대 못 잡았다.
    /// 사용자는 그 칸을 신고서에 그대로 옮겨 적는다.
    func testWrongTotalCostIsCaught() {
        var s = summary(proceeds: 60_000_000, cost: 40_000_000, fees: 100_000)
        s.totalCostsKRW += 1_000_000   // 필요경비만 부풀린다 (소득·세액은 그대로)
        let report = verify(s)
        XCTAssertTrue(
            report.issues.contains { $0.id == "V-TAX-01" && $0.severity == "critical" },
            "필요경비가 총수입·소득과 안 맞는데 잡지 못했다: \(report.issues.map(\.id))"
        )
    }

    /// 총수입금액이 어긋나도 잡아야 한다
    func testWrongTotalProceedsIsCaught() {
        var s = summary(proceeds: 60_000_000, cost: 40_000_000, fees: 100_000)
        s.totalProceedsKRW -= 500_000
        XCTAssertTrue(verify(s).issues.contains { $0.id == "V-TAX-01" && $0.severity == "critical" })
    }

    /// 소실 원가의 **연도 분배**가 깨지면 잡아야 한다.
    ///
    /// 옛 검사는 파이프라인이 넣어 준 값을 그대로 되비교해서 실패할 수 없었다.
    /// 연도 귀속이 틀어지면 「다른 해 비용이 이 해 소득을 깎는」 사고가 난다.
    func testBrokenAbandonedYearSplitIsCaught() {
        let s = summary(proceeds: 60_000_000, cost: 40_000_000, fees: 100_000)
        var replay = ReplayResult(
            disposals: s.disposals, holdings: HoldingsSnapshot(asOf: Date(), rows: [], aggregated: []),
            deemedPositions: [], abandonedTotal: 1_000_000, extraDeductible: 0,
            warnings: [], transferCostDetails: [], missingMarketAssets: [], missingFXDays: [], fxResolutions: []
        )
        replay.abandonedByYear = [2027: 1_000_000]
        func run() -> [String] {
            Verifier.verify(VerifierInput(summary: s, replay: replay, policies: .v1Default,
                                          events: [], summaryRerun: s, links: []))
                .issues.filter { $0.id == "V-COST-03" }.map(\.severity)
        }
        XCTAssertTrue(run().isEmpty, "연도 합이 맞는데 잡았다")

        replay.abandonedByYear = [2027: 400_000]   // 60만이 어느 해에도 안 들어갔다
        XCTAssertTrue(run().contains("critical"), "연도 분배가 깨졌는데 잡지 못했다")
    }

    /// 1원 이하 차이는 나눗셈 찌꺼기라 잡지 않는다 (오탐 방지)
    func testOneWonDifferenceIsTolerated() {
        var s = summary(proceeds: 60_000_000, cost: 40_000_000, fees: 100_000)
        s.totalCostsKRW += 1
        XCTAssertFalse(verify(s).issues.contains { $0.id == "V-TAX-01" })
    }
}
