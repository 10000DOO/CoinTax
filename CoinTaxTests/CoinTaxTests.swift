import XCTest
@testable import CoinTax

final class CoinTaxTests: XCTestCase {
    func testAccountDefaults() {
        let p = ProjectID()
        let b = Account.defaults(for: .bithumb, projectID: p)
        XCTAssertEqual(b.costMethod, .movingAverage)
        XCTAssertEqual(b.venueKind, .domestic)
        let n = Account.defaults(for: .binance, projectID: p)
        XCTAssertEqual(n.costMethod, .fifo)
        XCTAssertEqual(n.venueKind, .overseas)
    }

    func testAbandonPolicy() {
        let p = AbandonLostCostPolicy()
        let r = p.apply(outboundCostKRW: 140_000, withdrawnQty: 10, receivedQty: 9.9, explicitFeeCostKRW: 0)
        XCTAssertEqual(r.transferredCostKRW, 138_600)
        XCTAssertEqual(r.abandonedCostKRW, 1_400)
        XCTAssertEqual(r.deductibleExpenseKRW, 0)
    }
}
