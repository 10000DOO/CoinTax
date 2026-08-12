import XCTest
@testable import CoinTax

/// 실데이터 감사 F-01~F-04 회귀 (docs/realdata-audit-2026-08-12.md)
final class CSVUtilTests: XCTestCase {

    /// Swift 는 `"\r\n"` 을 **한 개의 Character** 로 본다.
    /// `Character` 단위로 순회하면 `case "\n"` 도 `case "\r"` 도 걸리지 않아
    /// 윈도우 줄바꿈 파일 전체가 한 행으로 읽힌다 — 거래소 export 대부분이 CRLF 다.
    func testCRLFSplitsRows() {
        let rows = CSVUtil.parseLines("a,b,c\r\n1,2,3\r\n4,5,6\r\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], ["a", "b", "c"])
        XCTAssertEqual(rows[2], ["4", "5", "6"])
    }

    func testMixedLineEndings() {
        // OKX 는 메타행만 CRLF, 나머지는 LF
        let rows = CSVUtil.parseLines("UID:1,Account Type:Main,Time Zone:UTC+9\r\nid,Time,Type\n7,x,Deposit\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["id", "Time", "Type"])
        XCTAssertEqual(CSVUtil.headerIndex(rows[1])["Type"], 2)
    }

    /// OKX 는 **줄마다** BOM 을 넣는다. 필드 선두에서 걷어내지 않으면 id 값이 오염된다.
    func testPerLineBOMStripped() {
        let rows = CSVUtil.parseLines("\u{FEFF}id,Time\n\u{FEFF}900000000001,2026-01-02 09:35:19\n")
        XCTAssertEqual(rows[0][0], "id")
        XCTAssertEqual(rows[1][0], "900000000001")
    }

    func testQuotedFieldKeepsCommaAndNewline() {
        let rows = CSVUtil.parseLines("a,\"x,y\",c\r\n\"두\r\n줄\",2,3\r\n")
        XCTAssertEqual(rows[0], ["a", "x,y", "c"])
        XCTAssertEqual(rows[1][0], "두\r\n줄")
    }

    /// 바이낸스 거래내역 CSV 는 숫자에 단위를 붙인다 (`0.1234XAUT`).
    /// `Pair`(XAUTUSDT)는 구분자가 없어 쪼갤 수 없으므로 심볼 근거는 이 접미사다.
    func testSplitAmountUnit() {
        XCTAssertEqual(CSVUtil.splitAmountUnit("0.1234XAUT")?.amount, Decimal(string: "0.1234"))
        XCTAssertEqual(CSVUtil.splitAmountUnit("0.1234XAUT")?.unit, "XAUT")
        XCTAssertEqual(CSVUtil.splitAmountUnit("1,500.123456USDT")?.amount, Decimal(string: "1500.123456"))
        XCTAssertEqual(CSVUtil.splitAmountUnit("-12.345678")?.unit, nil)
        XCTAssertEqual(CSVUtil.splitAmountUnit("-12.345678")?.amount, Decimal(string: "-12.345678"))
        XCTAssertNil(CSVUtil.splitAmountUnit(""))
        XCTAssertNil(CSVUtil.splitAmountUnit("BNB"))
    }

    /// 시각 타임존이 파일명에만 있는 export 가 있다.
    /// UTC 로 단정하면 최대 하루가 밀려 환율 적용일과 과세연도 귀속이 틀어진다.
    func testTimeZoneFromFileName() {
        XCTAssertEqual(
            CSVUtil.timeZoneFromFileName("Binance-Spot-Trade-History-202608111215(UTC+9)-part1-of1.csv")?.secondsFromGMT(),
            9 * 3600
        )
        XCTAssertEqual(CSVUtil.timeZoneFromFileName("x(UTC-5:30).csv")?.secondsFromGMT(), -5 * 3600 - 30 * 60)
        XCTAssertNil(CSVUtil.timeZoneFromFileName("Binance-Spot-Trade-History.csv"))
    }

    func testResolveExportTimeZonePrefersColumnName() {
        var warnings: [String] = []
        XCTAssertEqual(
            CSVUtil.resolveExportTimeZone(dateKey: "Date(UTC+0)", fileName: "x(UTC+9).csv", warnings: &warnings).secondsFromGMT(),
            0,
            "열 이름에 타임존이 박혀 있으면 그게 가장 확실하다"
        )
        XCTAssertEqual(
            CSVUtil.resolveExportTimeZone(dateKey: "Time", fileName: "x(UTC+9).csv", warnings: &warnings).secondsFromGMT(),
            9 * 3600
        )
        XCTAssertTrue(warnings.isEmpty)
        // 근거가 아무것도 없으면 UTC 로 두고 **경고**한다
        XCTAssertEqual(CSVUtil.resolveExportTimeZone(dateKey: "Time", fileName: "x.csv", warnings: &warnings).secondsFromGMT(), 0)
        XCTAssertFalse(warnings.isEmpty)
    }

    /// 거래소 반올림 먼지를 「보유보다 많은 처분」 Critical 로 올리면 정상 데이터에서 export 가 잠긴다.
    func testDustShortfallClassification() {
        XCTAssertTrue(Money.isDustShortfall(Decimal(string: "0.00000001")!, of: Decimal(string: "0.05000000")!))
        XCTAssertFalse(Money.isDustShortfall(Decimal(string: "0.8")!, of: Decimal(string: "200")!))
        XCTAssertFalse(Money.isDustShortfall(Decimal(string: "0.00002")!, of: Decimal(string: "0.03")!))
        // 큰 수량이면 상대 기준이 절대 기준보다 커진다
        XCTAssertTrue(Money.isDustShortfall(Decimal(string: "0.5")!, of: Decimal(1_000_000)))
    }
}
