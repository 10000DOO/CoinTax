import XCTest
@testable import CoinTax

final class TransferMatchingTests: XCTestCase {
    func testSuggestDomesticToOverseas() {
        let projectID = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)
        let binance = Account.defaults(for: .binance, projectID: projectID)
        let t0 = TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 10)
        let t1 = TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 12)

        let w = LedgerEvent(
            projectID: projectID, accountID: bithumb.id, timestamp: t0, type: .withdrawal,
            baseAsset: AssetSymbol("USDT"), quantity: -10, counterpartyHint: "binance", sourceKind: "t"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: binance.id, timestamp: t1, type: .deposit,
            baseAsset: AssetSymbol("USDT"), quantity: 9.9, sourceKind: "t"
        )
        let engine = TransferMatchingEngine(accountsByID: [bithumb.id: bithumb, binance.id: binance])
        let cands = engine.suggest(events: [w, d], existing: [])
        XCTAssertEqual(cands.count, 1)
        XCTAssertGreaterThanOrEqual(cands[0].score, 0.35)
        XCTAssertEqual(cands[0].fromEventID, w.id)
        XCTAssertEqual(cands[0].toEventID, d.id)
    }
}
