import XCTest
@testable import CoinTax

/// V-RE-01 (같은 입력 두 번 → 같은 값) 이 **실제로 불일치를 잡는지** 확인한다.
///
/// 감사 G-2: 모든 테스트가 재실행 자리에 같은 객체를 넣어(`summaryRerun: summary`)
/// 이 검사가 한 번도 확인된 적이 없었다. 앱 파이프라인만 진짜로 두 번 돌린다.
/// 검사가 죽어 있으면 「두 번 돌려 같았다」는 근거가 통째로 거짓이 되므로 여기서 고정한다.
final class DeterminismCheckTests: XCTestCase {

    private func scenario() -> (events: [LedgerEvent], accounts: [Account], projectID: ProjectID) {
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
        return ([buy, sell], [acc], pid)
    }

    private func replayAndSummarize(_ s: (events: [LedgerEvent], accounts: [Account], projectID: ProjectID))
        throws -> (ReplayResult, TaxYearSummary) {
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(uniqueKeysWithValues: s.accounts.map { ($0.id, $0) }),
            fxRates: [:], marketPrices: [:]
        )
        let r = try engine.replay(events: s.events, links: [])
        let summary = TaxAggregator.aggregate(
            projectID: s.projectID, disposals: r.disposals, taxYear: 2027,
            extraDeductible: r.extraDeductibleByYear[2027] ?? 0,
            abandonedTransferCostKRW: r.abandonedByYear[2027] ?? 0,
            deemed: r.deemedPositions, policies: .v1Default
        )
        return (r, summary)
    }

    /// **진짜로 두 번** 돌려 비교한다 — 같은 객체를 두 번 넘기지 않는다.
    func testTwoIndependentRunsAgree() throws {
        let s = scenario()
        let (r1, first) = try replayAndSummarize(s)
        let (_, second) = try replayAndSummarize(s)
        XCTAssertFalse(first.disposals.isEmpty, "비교할 처분이 있어야 검사가 의미를 갖는다")

        let report = Verifier.verify(VerifierInput(
            summary: first, replay: r1, policies: .v1Default,
            events: s.events, summaryRerun: second
        ))
        XCTAssertFalse(report.issues.contains { $0.id == "V-RE-01" },
                       "같은 입력을 두 번 돌렸는데 불일치가 나면 계산이 결정적이지 않다")
    }

    /// 일부러 다른 값을 넣으면 **반드시 잡혀야 한다** (변이 테스트).
    /// 이게 없으면 「검사가 통과했다」가 「검사가 아무것도 안 한다」와 구별되지 않는다.
    func testMutatedRerunIsCaught() throws {
        let s = scenario()
        let (r1, first) = try replayAndSummarize(s)

        var mutated = first
        mutated.netIncomeKRW += 1          // 1원만 틀어도 잡혀야 한다
        let byIncome = Verifier.verify(VerifierInput(
            summary: first, replay: r1, policies: .v1Default,
            events: s.events, summaryRerun: mutated
        ))
        XCTAssertTrue(byIncome.issues.contains { $0.id == "V-RE-01" && $0.severity == "critical" },
                      "소득금액 불일치를 놓쳤다")

        var dropped = first
        dropped.disposals = []             // 처분 건수가 달라진 경우
        let byCount = Verifier.verify(VerifierInput(
            summary: first, replay: r1, policies: .v1Default,
            events: s.events, summaryRerun: dropped
        ))
        XCTAssertTrue(byCount.issues.contains { $0.id == "V-RE-01" },
                      "처분 건수 불일치를 놓쳤다")
    }

    /// 세액만 틀어진 경우도 잡아야 한다.
    func testMutatedTaxIsCaught() throws {
        let s = scenario()
        let (r1, first) = try replayAndSummarize(s)
        var mutated = first
        mutated.totalTaxKRW += 100
        let report = Verifier.verify(VerifierInput(
            summary: first, replay: r1, policies: .v1Default,
            events: s.events, summaryRerun: mutated
        ))
        XCTAssertTrue(report.issues.contains { $0.id == "V-RE-01" }, "세액 불일치를 놓쳤다")
    }
}
