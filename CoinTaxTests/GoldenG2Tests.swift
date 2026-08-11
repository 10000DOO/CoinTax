import XCTest
@testable import CoinTax

final class GoldenG2Tests: XCTestCase {
    func testDeemedMaxBookMarket() {
        let policy = MaxBookMarketDeemedPolicy()
        XCTAssertEqual(policy.deemedUnit(bookUnit: 1000, marketUnit: 1500), 1500)
        XCTAssertEqual(policy.deemedUnit(bookUnit: 2000, marketUnit: 1500), 2000)
    }

    func testDeemedAppliedInReplay() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)

        // Pre-tax buy
        let buy = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 2, quoteAmountKRW: 2000, sourceKind: "test" // unit 1000
        )

        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: [bithumb.id: bithumb],
            fxRates: [:],
            marketPrices: ["USDT": 1500]
        )
        let replay = try engine.replay(events: [buy], links: [])
        XCTAssertEqual(replay.deemedPositions.count, 1)
        let d = try XCTUnwrap(replay.deemedPositions.first)
        XCTAssertEqual(d.bookUnitKRW, 1000)
        XCTAssertEqual(d.marketUnitKRW, 1500)
        XCTAssertEqual(d.deemedUnitKRW, 1500)
        XCTAssertEqual(d.reason, "market")

        // holdings after deemed should use 1500 unit
        let row = replay.holdings.rows.first { $0.asset.code == "USDT" }
        XCTAssertEqual(row?.quantity, 2)
        XCTAssertEqual(row?.totalCostKRW, 3000)
    }
}
