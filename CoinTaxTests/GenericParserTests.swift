import XCTest
@testable import CoinTax

final class GenericParserTests: XCTestCase {
    func testGenericTabularMapsStandardHeaders() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("docs/samples/synthetic/generic_tabular_sample.csv"),
            encoding: .utf8
        )
        let parser = GenericTabularMapper()
        let result = try parser.parse(
            text: text,
            fileName: "generic.csv",
            projectID: ProjectID(),
            accountID: AccountID()
        )
        XCTAssertEqual(result.parserID, "generic-tabular-v1")
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events[0].type, .buy)
        XCTAssertEqual(result.events[0].baseAsset.code, "BTC")
        XCTAssertEqual(result.events[1].type, .sell)
        XCTAssertEqual(result.events[1].quantity, Decimal(string: "-0.01"))
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testGenericDetectIsLowScoreFallback() {
        let probe = FormatProbe.probe(text: "Date,Type,Amount\n", fileName: "x.csv")
        let score = GenericTabularMapper().detect(probe)
        XCTAssertGreaterThan(score, 0.3)
        XCTAssertLessThan(score, 0.5)
    }
}
