import XCTest
@testable import CoinTax

/// `[법]` 소득세법 §37⑥ · `[영]` §88④⑤ — 취득가를 증명 못 할 때 판 금액의 50%.
///
/// 손계산으로 고정한다. 조문이 요구하는 세 가지가 지켜지는지 본다.
///   1. 자산(종류)**별 일괄** — 건별 선택이 아니다
///   2. **부대비용 불산입** — 수수료를 따로 빼면 조문 후단 위반
///   3. **선택**("할 수 있다") — 기본은 꺼짐이고, 켰을 때·껐을 때를 함께 보여준다
final class ProxyExpenseTests: XCTestCase {

    private func disposal(_ code: String, proceeds: Decimal, cost: Decimal, fees: Decimal) -> DisposalRecord {
        DisposalRecord(
            id: UUID(), eventID: EventID(),
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            accountID: AccountID(), asset: AssetSymbol(code), quantity: 1,
            proceedsKRW: proceeds, costKRW: cost, feesKRW: fees,
            pnlKRW: proceeds - cost - fees, method: .totalAverage, taxYear: 2027
        )
    }

    private func aggregate(_ ds: [DisposalRecord], enabled: Set<String>) -> TaxYearSummary {
        var p = PolicyBundle.v1Default
        p.proxyExpense = StatutoryProxyExpensePolicy(enabledAssets: enabled)
        return TaxAggregator.aggregate(
            projectID: ProjectID(), disposals: ds, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0, deemed: [], policies: p
        )
    }

    /// 기본은 꺼져 있어야 한다 — 「할 수 있다」를 앱이 멋대로 켜면 안 된다
    func testOffByDefault() {
        XCTAssertTrue(PolicyBundle.v1Default.proxyExpense.enabledAssets.isEmpty)
        XCTAssertEqual(PolicyBundle.v1Default.proxyExpense.ratio, Decimal(string: "0.5"))
    }

    /// 손계산: BTC 를 1억에 팔았고 산 값 3천만·수수료 100만.
    ///   끄면 필요경비 3,100만 → 소득 6,900만
    ///   켜면 필요경비 1억×50% = 5,000만, **수수료는 안 뺀다** → 소득 5,000만
    func testFiftyPercentReplacesCostAndDropsFees() {
        let ds = [disposal("BTC", proceeds: 100_000_000, cost: 30_000_000, fees: 1_000_000)]

        let off = aggregate(ds, enabled: [])
        XCTAssertEqual(off.totalCostsKRW, 31_000_000)
        XCTAssertEqual(off.netIncomeKRW, 69_000_000)

        let on = aggregate(ds, enabled: ["BTC"])
        XCTAssertEqual(on.totalCostsKRW, 50_000_000, "1억 × 50%")
        XCTAssertEqual(on.netIncomeKRW, 50_000_000)
        XCTAssertEqual(on.disposals.first?.feesKRW, 0, "부대비용은 산입하지 않는다 (§37⑥ 후단)")
    }

    /// **자산별 일괄** — 켠 자산만 바뀌고 다른 자산은 그대로다
    func testAppliesPerAssetOnly() {
        let ds = [
            disposal("BTC", proceeds: 100_000_000, cost: 30_000_000, fees: 0),
            disposal("ETH", proceeds: 10_000_000, cost: 4_000_000, fees: 0)
        ]
        let s = aggregate(ds, enabled: ["BTC"])
        // BTC 5,000만 (의제) + ETH 400만 (실제) = 5,400만
        XCTAssertEqual(s.totalCostsKRW, 54_000_000)
        XCTAssertEqual(s.netIncomeKRW, 110_000_000 - 54_000_000)
        let eth = s.disposals.first { $0.asset.code == "ETH" }
        XCTAssertEqual(eth?.costKRW, 4_000_000, "안 켠 자산은 그대로여야 한다")
    }

    /// 같은 자산의 처분이 여러 건이면 **양도가액 비율대로** 나눠 담아야
    /// 표의 합계가 총액과 맞는다 (검증기 V-RE-02·V-COST-06)
    func testSplitsAcrossDisposalsByProceeds() {
        let ds = [
            disposal("BTC", proceeds: 30_000_000, cost: 9_000_000, fees: 0),
            disposal("BTC", proceeds: 70_000_000, cost: 21_000_000, fees: 0)
        ]
        let s = aggregate(ds, enabled: ["BTC"])
        XCTAssertEqual(s.totalCostsKRW, 50_000_000)
        let sorted = s.disposals.sorted { $0.proceedsKRW < $1.proceedsKRW }
        XCTAssertEqual(sorted[0].costKRW, 15_000_000, "3천만/1억 × 5천만")
        XCTAssertEqual(sorted[1].costKRW, 35_000_000, "7천만/1억 × 5천만")
        // 건별 손익 합 == 소득금액 (검증기가 보는 등식)
        let sum = s.disposals.reduce(Decimal(0)) { $0 + $1.pnlKRW }
        XCTAssertEqual(sum, s.netIncomeKRW)
        XCTAssertEqual(s.totalProceedsKRW - s.totalCostsKRW, s.netIncomeKRW)
    }

    /// 켠 자산이 있으면 **정책 번들 id 가 달라져야** 과거 스냅샷과 구분된다
    func testBundleIDChangesWhenEnabled() {
        let off = StatutoryProxyExpensePolicy()
        let on = StatutoryProxyExpensePolicy(enabledAssets: ["BTC", "ETH"])
        XCTAssertEqual(off.id, "proxy_expense_off")
        XCTAssertEqual(on.id, "proxy_expense_50_BTC-ETH", "어느 자산에 적용했는지 id 에 남는다")
    }

    /// 검증기가 의제 적용 결과를 정상으로 받아들여야 한다 (막으면 신고자료를 못 뽑는다)
    func testVerifierAcceptsProxyExpense() throws {
        let ds = [
            disposal("BTC", proceeds: 30_000_000, cost: 9_000_000, fees: 0),
            disposal("BTC", proceeds: 70_000_000, cost: 21_000_000, fees: 500_000)
        ]
        var p = PolicyBundle.v1Default
        p.proxyExpense = StatutoryProxyExpensePolicy(enabledAssets: ["BTC"])
        let s = aggregate(ds, enabled: ["BTC"])
        // 검증기는 **엔진 기록**으로 다시 센다 — 같은 처분을 담은 재생 결과를 넘겨야
        // 실제 경로를 검사한다 (빈 결과를 주면 검사 자체가 성립하지 않는다)
        let engine = CostBasisEngine(policies: p, accountsByID: [:], fxRates: [:], marketPrices: [:])
        var replay = try engine.replay(events: [], links: [])
        replay.disposals = ds
        let report = Verifier.verify(VerifierInput(
            summary: s, replay: replay, policies: p, events: [], summaryRerun: s
        ))
        let crit = report.issues.filter { $0.severity == "critical" }
        XCTAssertTrue(crit.isEmpty, crit.map { "\($0.id) \($0.message)" }.joined(separator: " / "))
    }
}
