import XCTest
@testable import CoinTax

/// 04-import-formats G-import + §10-1: 합성 fixture 파서 파이프라인
final class ImportPipelineTests: XCTestCase {
    private func synthetic(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/samples/synthetic/\(name)")
    }

    func testGImport_BithumbSynthetic() throws {
        let text = try String(contentsOf: synthetic("bithumb_certificate_sample.txt"), encoding: .utf8)
        let result = try BithumbCertificatePDFParser().parse(
            text: text, fileName: "bithumb.txt",
            projectID: ProjectID(), accountID: AccountID()
        )
        XCTAssertGreaterThanOrEqual(result.events.count, 3)
        XCTAssertTrue(result.events.contains { $0.type == .buy })
        XCTAssertTrue(result.events.contains { $0.type == .withdrawal })
    }

    func testGImport_BinanceSpotAndDeposit() throws {
        let spot = try String(contentsOf: synthetic("binance_spot_sample.csv"), encoding: .utf8)
        let dep = try String(contentsOf: synthetic("binance_deposit_sample.csv"), encoding: .utf8)
        let s = try BinanceSpotXLSXParser().parse(text: spot, fileName: "spot.csv", projectID: ProjectID(), accountID: AccountID())
        let d = try BinanceDepositXLSXParser().parse(text: dep, fileName: "dep.csv", projectID: ProjectID(), accountID: AccountID())
        XCTAssertEqual(s.events.count, 2)
        XCTAssertEqual(d.events.count, 1)
    }

    func testGImport_OKXSpotGroupAndTransfer() throws {
        let text = try String(contentsOf: synthetic("okx_trading_sample.csv"), encoding: .utf8)
        let result = try OKXTradingHistoryCSVParser().parse(
            text: text, fileName: "OKX Trading History.csv",
            projectID: ProjectID(), accountID: AccountID()
        )
        let trades = result.events.filter { $0.type == .buy || $0.type == .sell }
        XCTAssertEqual(trades.count, 1)
        XCTAssertTrue(result.events.contains { $0.type == .deposit })
    }

    func testRegistryPrefersOKXFundingOverGeneric() {
        let text = try! String(contentsOf: synthetic("okx_funding_sample.csv"), encoding: .utf8)
        let probe = FormatProbe.probe(text: text, fileName: "OKX Funding History_sample.csv")
        let top = ParserRegistry.v1.ranked(for: probe).first
        XCTAssertEqual(top?.parser.parserID, "okx-funding-history-csv-v1")
    }
}
