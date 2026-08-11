import XCTest
@testable import CoinTax

final class MoneyRoundingTests: XCTestCase {
    func testPlainHalfUp() {
        XCTAssertEqual(Money.roundKRW(Decimal(string: "1.4")!), 1)
        XCTAssertEqual(Money.roundKRW(Decimal(string: "1.5")!), 2)
        XCTAssertEqual(Money.roundKRW(Decimal(string: "1.6")!), 2)
        XCTAssertEqual(Money.roundKRW(Decimal(string: "7361400")! * Decimal(string: "0.2")!), 1_472_280)
        XCTAssertEqual(Money.roundKRW(Decimal(string: "7361400")! * Decimal(string: "0.02")!), 147_228)
    }

    func testTaxCopyExact() {
        XCTAssertEqual(TaxCopy.notTaxAdvice, "본 결과는 세무 자문이 아니며 예상 참고용입니다. 신고 전 전문가·국세청 안내를 확인하세요.")
        XCTAssertEqual(PolicyBundle.v1Default.id, "cointax-v1.0")
        XCTAssertEqual(PolicyBundle.v1Default.transferCost.id, "abandon_lost_cost")
    }
}
