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
        // Trading History의 Transfer 행은 거래소 내부 이동(거래↔펀딩)이다.
        // 외부 입출금으로 잡으면 Funding History와 함께 넣었을 때 이중 반영된다 (리뷰 1-3).
        XCTAssertTrue(result.events.filter { $0.type == .deposit || $0.type == .withdrawal }.isEmpty)
        let internals = result.events.filter { $0.type == .transferInternal }
        XCTAssertEqual(internals.count, 1)
        XCTAssertEqual(internals.first?.baseAsset.code, "USDT")
        XCTAssertTrue(result.warnings.contains { $0.contains("Funding History") })
    }

    /// 리뷰 1-1: OKX `Balance Change`는 수수료가 이미 빠진 값 → 엔진이 다시 빼면 수량이 이중 축소된다.
    func testOKXSpotQuantityIsNetOfFee() throws {
        let text = try String(contentsOf: syntheticURL("okx_trading_history_sample.csv"), encoding: .utf8)
        let parser = OKXTradingHistoryCSVParser()
        let result = try parser.parse(text: text, fileName: "OKX Trading History.csv", projectID: projectID, accountID: accountID)
        let buy = try XCTUnwrap(result.events.first { $0.type == .buy })
        XCTAssertEqual(buy.quantity, Decimal(string: "0.00999"), "Balance Change 그대로")
        XCTAssertEqual(buy.feeAmount, Decimal(string: "0.00001"))
        XCTAssertTrue(buy.quantityIsNetOfFee, "이미 순액임을 표시해야 엔진이 재차감하지 않는다")

        let acc = Account.defaults(for: .okx, projectID: projectID)
        var event = buy
        event.accountID = acc.id
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: [acc.id: acc],
            fxRates: [TaxTime.dayKST(event.timestamp): 1400],
            marketPrices: ["BTC": 100_000_000]
        )
        let replay = try engine.replay(events: [event], links: [])
        let row = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "BTC" })
        XCTAssertEqual(row.quantity, Decimal(string: "0.00999"), "수수료를 두 번 빼면 0.00998이 된다")
    }

    /// 리뷰 4-1: 열 이름이 중복돼도 크래시하지 않는다.
    func testDuplicateHeadersDoNotCrash() throws {
        let text = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin,,
        2027-06-01 14:00:15,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT,,
        """
        let result = try BinanceSpotXLSXParser().parse(text: text, fileName: "spot.csv", projectID: projectID, accountID: accountID)
        XCTAssertEqual(result.events.count, 1)
    }

    /// 리뷰 2-3: 엑셀이 붙이는 BOM 때문에 헤더 검증이 실패하면 안 된다.
    func testBOMPrefixedCSVIsAccepted() throws {
        let text = "\u{FEFF}" + """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 14:00:15,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        """
        let result = try BinanceSpotXLSXParser().parse(text: text, fileName: "spot.csv", projectID: projectID, accountID: accountID)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].baseAsset.code, "BTC")
    }

    /// 리뷰 6-4: Type이 BUY가 아니면 무조건 매도로 두면 안 된다.
    func testUnknownTypeRowIsSkippedNotTreatedAsSell() throws {
        let text = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 14:00:15,BTC/USDT,BTC,USDT,,50000,0.01,500,0,USDT
        """
        let result = try BinanceSpotXLSXParser().parse(text: text, fileName: "spot.csv", projectID: projectID, accountID: accountID)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("알 수 없는 Type") })
    }

    /// 리뷰 1-5: 빗썸 확인서 PDF의 2단 레이아웃을 한 거래로 병합한다.
    func testBithumbTwoLineLayoutMerge() throws {
        // 실제 확인서 추출 텍스트를 모사: 날짜/시간 2줄 + 금액 줄 + 단위 줄 + 비고
        let extracted = """
        거래내역 확인서
        거래일시 자산명 거래구분 거래수량 체결가격 거래금액 정산금액 (수수료 포함) 비고
        2027-01-05
        10:00:00
        USDT 매수 10 1,400 14,000 -14,035
        USDT KRW KRW KRW
        지정가 매수
        2027-01-06
        11:30:00
        USDT 출금 10
        USDT
        바이낸스
        """
        let result = try BithumbCertificatePDFParser().parse(
            text: extracted, fileName: "cert.txt", projectID: projectID, accountID: accountID
        )
        XCTAssertEqual(result.events.count, 2)
        let buy = try XCTUnwrap(result.events.first { $0.type == .buy })
        XCTAssertEqual(buy.baseAsset.code, "USDT")
        XCTAssertEqual(buy.quantity, 10)
        XCTAssertEqual(buy.quoteAmountKRW, 14_035, "취득가는 |정산금액| (수수료 포함)")
        let out = try XCTUnwrap(result.events.first { $0.type == .withdrawal })
        XCTAssertEqual(out.quantity, -10)
        XCTAssertEqual(out.counterpartyHint, "binance")
        XCTAssertNil(out.quoteAmountKRW, "입·출금 행의 정산금액은 KRW가 아니다")
    }

    /// 리뷰 1-5: 한 행도 못 읽으면 조용히 성공하지 말고 오류를 낸다.
    func testBithumbEmptyExtractionThrows() {
        XCTAssertThrowsError(
            try BithumbCertificatePDFParser().parse(
                text: "거래내역 확인서\n(표를 읽을 수 없는 형식)\n", fileName: "cert.txt",
                projectID: projectID, accountID: accountID
            )
        ) { err in
            XCTAssertEqual((err as? CoinTaxError)?.code, "E_PARSE_ROW")
        }
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
