import XCTest
@testable import CoinTax

final class ParserTests: XCTestCase {
    let projectID = ProjectID()
    lazy var accountID = AccountID()

    private func syntheticURL(_ name: String) -> URL {
        // Prefer docs/samples/synthetic relative to package
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CoinTaxTests
            .deletingLastPathComponent() // project root
            .appendingPathComponent("docs/samples/synthetic/\(name)")
        return root
    }

    func testOKXTradingGroupsSpotOrder() throws {
        let text = try String(contentsOf: syntheticURL("okx_trading_sample.csv"), encoding: .utf8)
        let parser = OKXTradingHistoryCSVParser()
        let result = try parser.parse(text: text, fileName: "OKX Trading History_sample.csv", projectID: projectID, accountID: accountID)
        let spots = result.events.filter { $0.type == .buy || $0.type == .sell }
        XCTAssertEqual(spots.count, 1, "Order id 묶음 → 매매 1건")
        XCTAssertEqual(spots.first?.type, .buy)
        XCTAssertEqual(spots.first?.baseAsset.code, "BTC")
        let transfers = result.events.filter { $0.type == .deposit || $0.type == .withdrawal }
        XCTAssertEqual(transfers.count, 1)
        XCTAssertEqual(transfers.first?.type, .deposit)
    }

    func testOKXFunding() throws {
        let text = try String(contentsOf: syntheticURL("okx_funding_sample.csv"), encoding: .utf8)
        let parser = OKXFundingHistoryCSVParser()
        let result = try parser.parse(text: text, fileName: "OKX Funding History_sample.csv", projectID: projectID, accountID: accountID)
        XCTAssertTrue(result.events.contains { $0.type == .deposit && $0.quantity == 10 })
        XCTAssertTrue(result.events.contains { $0.type == .withdrawal && $0.quantity == -5 })
        XCTAssertTrue(result.events.contains { $0.type == .income })
        XCTAssertTrue(result.events.contains { $0.type == .transferInternal })
    }

    func testBinanceSpotCSV() throws {
        let text = try String(contentsOf: syntheticURL("binance_spot_sample.csv"), encoding: .utf8)
        let parser = BinanceSpotXLSXParser()
        let result = try parser.parse(text: text, fileName: "Binance-Spot Trade History.csv", projectID: projectID, accountID: accountID)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events[0].type, .buy)
        XCTAssertEqual(result.events[0].quantity, Decimal(string: "0.01"))
        XCTAssertEqual(result.events[1].type, .sell)
        XCTAssertEqual(result.events[1].quantity, Decimal(string: "-0.01"))
    }

    func testBinanceDepositCSV() throws {
        let text = try String(contentsOf: syntheticURL("binance_deposit_sample.csv"), encoding: .utf8)
        let parser = BinanceDepositXLSXParser()
        let result = try parser.parse(text: text, fileName: "Binance-Deposit-History.csv", projectID: projectID, accountID: accountID)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].quantity, Decimal(string: "9.9"))
        XCTAssertEqual(result.ignoredCount, 1)
    }

    func testBinanceWithdrawCSV() throws {
        let text = try String(contentsOf: syntheticURL("binance_withdraw_sample.csv"), encoding: .utf8)
        let parser = BinanceWithdrawXLSXParser()
        let result = try parser.parse(text: text, fileName: "Binance-Withdraw-History.csv", projectID: projectID, accountID: accountID)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].type, .withdrawal)
        XCTAssertEqual(result.events[0].quantity, -5)
        XCTAssertEqual(result.events[0].feeAmount, 1)
    }

    func testBinanceSpotXLSXRoundTrip() throws {
        let rows = [
            ["Date(UTC)", "Pair", "Base Asset", "Quote Asset", "Type", "Price", "Amount", "Total", "Fee", "Fee Coin"],
            ["2027-06-01 14:00:15", "BTC/USDT", "BTC", "USDT", "BUY", "50000", "0.01", "500", "0", "USDT"]
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spot-test-\(UUID().uuidString).xlsx")
        try XLSXWriter.write(rows: rows, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let parser = BinanceSpotXLSXParser()
        let result = try parser.parse(url: url, projectID: projectID, accountID: accountID)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].type, .buy)
    }

    func testBithumbText() throws {
        let text = try String(contentsOf: syntheticURL("bithumb_certificate_sample.txt"), encoding: .utf8)
        let parser = BithumbCertificatePDFParser()
        let result = try parser.parse(text: text, fileName: "bithumb_certificate_sample.txt", projectID: projectID, accountID: accountID)
        XCTAssertTrue(result.events.contains { $0.type == .buy && $0.quantity == 10 })
        XCTAssertTrue(result.events.contains { $0.type == .withdrawal && $0.counterpartyHint == "binance" })
        XCTAssertTrue(result.events.contains { $0.type == .sell })
    }

    func testBithumbRejectsWithholding() {
        let parser = BithumbCertificatePDFParser()
        XCTAssertThrowsError(try parser.parse(text: "원천징수영수증\n...", fileName: "x.txt", projectID: projectID, accountID: accountID)) { err in
            let e = err as? CoinTaxError
            XCTAssertEqual(e?.code, "E_PARSER_REJECT")
        }
    }
}
