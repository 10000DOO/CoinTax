import XCTest
@testable import CoinTax

/// 엑셀 파일에서 **빈 칸 하나가 그 뒤 값을 통째로 한 칸씩 밀어버리는** 문제 (5차 감사).
///
/// 엑셀은 「값은 없지만 서식이 있는 칸」을 `<c r="D5" s="2"/>` 처럼 **혼자 닫히는 태그**로 적는다.
/// 셀을 찾는 정규식이 그 형태를 따로 보지 않으면, 빈 칸이 **다음 칸을 삼켜서**
/// 다음 칸의 값이 빈 칸 자리에 들어앉는다. 그 뒤 값은 전부 한 칸씩 왼쪽으로 밀린다.
///
/// 바이낸스 리포트센터 파일은 `.xlsx` 이고 잔고 열이 없어 **거래소 잔고 대조(V-BAL)도 못 잡는다.**
/// 수량이 대금 칸에서, 대금이 수수료 칸에서 읽히면 취득가액·양도가액이 통째로 틀린다.
final class XLSXCellShiftTests: XCTestCase {

    /// 시트 XML 을 **그대로** 넣어 xlsx 한 개를 만든다.
    /// (`XLSXWriter` 는 inlineStr 만 쓰므로 혼자 닫히는 빈 칸을 재현할 수 없다)
    private func makeXLSX(sheetRowsXML: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """.write(to: tmp.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """.write(to: tmp.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="sheet1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """.write(to: tmp.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """.write(to: tmp.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>\(sheetRowsXML)</sheetData>
        </worksheet>
        """.write(to: tmp.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("shift-\(UUID().uuidString).xlsx")
        let proc = Process()
        proc.currentDirectoryURL = tmp
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-qr", out.path, "."]
        try proc.run()
        proc.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
        guard proc.terminationStatus == 0 else { throw CoinTaxError.parseRow("zip 실패") }
        return out
    }

    private func inline(_ ref: String, _ text: String) -> String {
        "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(text)</t></is></c>"
    }
    private func number(_ ref: String, _ v: String) -> String {
        "<c r=\"\(ref)\"><v>\(v)</v></c>"
    }
    /// 값 없이 서식만 있는 칸 — 엑셀이 실제로 이렇게 적는다
    private func emptyStyled(_ ref: String) -> String {
        "<c r=\"\(ref)\" s=\"2\"/>"
    }

    // MARK: - 읽기 계층

    func testEmptyStyledCellDoesNotSwallowTheNextCell() throws {
        let rowXML = "<row r=\"1\">" + inline("A1", "hello") + emptyStyled("B1") + number("C1", "12345") + "</row>"
        let url = try makeXLSX(sheetRowsXML: rowXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try XLSXReader.readFirstSheetRows(url: url)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], ["hello", "", "12345"], "빈 칸이 다음 칸을 삼켜 값이 한 칸 밀렸다")
    }

    func testTrailingAndConsecutiveEmptyCells() throws {
        let rowXML = "<row r=\"1\">"
            + emptyStyled("A1") + emptyStyled("B1") + inline("C1", "x") + emptyStyled("D1")
            + "</row>"
        let url = try makeXLSX(sheetRowsXML: rowXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try XLSXReader.readFirstSheetRows(url: url)
        XCTAssertEqual(rows[0], ["", "", "x", ""])
    }

    /// 한 칸 안에서 **글씨체가 나뉘면** 엑셀은 그 칸을 조각(`<r><t>`)으로 쪼개 적는다.
    /// 조각을 하나만 읽으면 값이 **잘린다** — 공유 문자열 쪽은 이미 조각을 이어 붙이고 있다.
    func testRichTextInlineCellKeepsAllRuns() throws {
        let rowXML = "<row r=\"1\">"
            + "<c r=\"A1\" t=\"inlineStr\"><is><r><t>2027-</t></r><r><t>01-05</t></r></is></c>"
            + "<c r=\"B1\" t=\"inlineStr\"><is><r><t>1234</t></r><r><t>.5</t></r></is></c>"
            + "</row>"
        let url = try makeXLSX(sheetRowsXML: rowXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try XLSXReader.readFirstSheetRows(url: url)
        XCTAssertEqual(rows[0], ["2027-01-05", "1234.5"], "칸 안의 조각을 하나만 읽어 값이 잘렸다")
    }

    /// 빈 내용·순서가 뒤바뀐 칸·`r` 없는 칸에서도 무너지지 않아야 한다
    func testOtherCellShapes() throws {
        let rowXML = "<row r=\"1\">"
            + "<c r=\"C1\"><v>3</v></c>"           // 순서가 뒤바뀜
            + "<c r=\"A1\"><v>1</v></c>"
            + "<c r=\"B1\" t=\"inlineStr\"><is><t></t></is></c>"  // 빈 문자열
            + "</row>"
        let url = try makeXLSX(sheetRowsXML: rowXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try XLSXReader.readFirstSheetRows(url: url)
        XCTAssertEqual(rows[0], ["1", "", "3"], "칸 순서는 `r` 속성이 정한다")
    }

    /// **빈 행**도 혼자 닫히는 태그로 적힌다 (`<row r="3" .../>`).
    /// 셀에서 났던 문제가 한 단계 위에도 있으면 **그 뒤 행이 통째로 삼켜진다** = 거래가 사라진다.
    func testEmptyRowDoesNotSwallowFollowingRows() throws {
        let rowsXML = "<row r=\"1\">" + inline("A1", "first") + "</row>"
            + "<row r=\"2\" spans=\"1:1\" s=\"0\" customFormat=\"1\"/>"   // 값 없는 행
            + "<row r=\"3\">" + inline("A3", "third") + "</row>"
            + "<row r=\"4\">" + inline("A4", "fourth") + "</row>"
        let url = try makeXLSX(sheetRowsXML: rowsXML)
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try XLSXReader.readFirstSheetRows(url: url)
        XCTAssertEqual(
            rows.map { $0.first ?? "" }, ["first", "third", "fourth"],
            "빈 행이 뒤 행을 삼켜 거래가 사라졌다"
        )
    }

    // MARK: - 파서까지 이어지는 결과 (세액에 들어가는 값)

    /// 바이낸스 Spot 리포트 한 행의 가운데 칸이 비어 있어도
    /// **수량·대금·수수료가 제 열에서** 읽혀야 한다.
    func testBinanceSpotRowWithEmptyMiddleCellKeepsColumns() throws {
        let headers = ["Date(UTC)", "Base Asset", "Quote Asset", "Type", "Price", "Amount", "Total", "Fee", "Fee Coin"]
        var header = "<row r=\"1\">"
        for (i, h) in headers.enumerated() { header += inline("\(colName(i))1", h) }
        header += "</row>"

        // Price 칸이 비어 있는 행 (시장가 체결 등) — 그 뒤 Amount·Total·Fee 가 밀리면 안 된다
        var data = "<row r=\"2\">"
        data += inline("A2", "2026-05-01 10:00:00")
        data += inline("B2", "BTC")
        data += inline("C2", "USDT")
        data += inline("D2", "BUY")
        data += emptyStyled("E2")                 // Price 없음
        data += number("F2", "0.5")               // Amount = 수량
        data += number("G2", "25000")             // Total = 대금
        data += number("H2", "0.001")             // Fee
        data += inline("I2", "BNB")               // Fee Coin
        data += "</row>"

        let url = try makeXLSX(sheetRowsXML: header + data)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try BinanceSpotXLSXParser().parse(url: url, projectID: ProjectID(), accountID: AccountID())
        let e = try XCTUnwrap(result.events.first, "행을 읽지 못했다: \(result.warnings)")
        XCTAssertEqual(e.baseAsset.code, "BTC")
        XCTAssertEqual(e.quoteAsset?.code, "USDT")
        XCTAssertEqual(Money.abs(e.quantity), Decimal(string: "0.5")!, "수량이 다른 열에서 읽혔다")
        XCTAssertEqual(e.quoteAmount, 25_000, "대금이 다른 열에서 읽혔다")
        XCTAssertEqual(e.feeAmount, Decimal(string: "0.001")!)
        XCTAssertEqual(e.feeAsset?.code, "BNB")
    }

    private func colName(_ index: Int) -> String {
        String(UnicodeScalar(65 + index)!)
    }
}
