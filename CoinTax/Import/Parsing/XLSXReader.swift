import Foundation

/// Lightweight XLSX first-sheet reader (sharedStrings + inlineStr).
enum XLSXReader {
    static func readFirstSheetRows(url: URL) throws -> [[String]] {
        let data = try Data(contentsOf: url)
        return try readFirstSheetRows(data: data)
    }

    static func readFirstSheetRows(data: Data) throws -> [[String]] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try unzip(data: data, to: tmp)

        let shared = loadSharedStrings(dir: tmp)
        // prefer sheet1
        let sheetCandidates = [
            tmp.appendingPathComponent("xl/worksheets/sheet1.xml"),
            tmp.appendingPathComponent("xl/worksheets/sheet.xml")
        ]
        guard let sheetURL = sheetCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CoinTaxError.parseRow("xlsx sheet 없음")
        }
        let xml = try String(contentsOf: sheetURL, encoding: .utf8)
        return parseSheetXML(xml, shared: shared)
    }

    /// Minimal ZIP inflate for store + deflate entries (enough for Binance xlsx).
    private static func unzip(data: Data, to dir: URL) throws {
        // Use /usr/bin/unzip via process for reliability on macOS
        let zipURL = dir.appendingPathComponent("in.zip")
        try data.write(to: zipURL)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", zipURL.path, "-d", dir.path]
        let pipe = Pipe()
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw CoinTaxError.parseRow("xlsx unzip 실패")
        }
    }

    private static func loadSharedStrings(dir: URL) -> [String] {
        let url = dir.appendingPathComponent("xl/sharedStrings.xml")
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [String] = []
        // <si>...<t>...</t> or rich text multiple t
        let siPattern = try! NSRegularExpression(pattern: #"<si>(.*?)</si>"#, options: [.dotMatchesLineSeparators])
        let tPattern = try! NSRegularExpression(pattern: #"<t[^>]*>(.*?)</t>"#, options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        let matches = siPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let si = ns.substring(with: m.range(at: 1))
            let tMatches = tPattern.matches(in: si, range: NSRange(location: 0, length: (si as NSString).length))
            var text = ""
            for tm in tMatches {
                text += (si as NSString).substring(with: tm.range(at: 1))
            }
            result.append(decodeXML(text))
        }
        return result
    }

    private static func parseSheetXML(_ xml: String, shared: [String]) -> [[String]] {
        var rows: [[String]] = []
        let rowPattern = try! NSRegularExpression(pattern: #"<row[^>]*>(.*?)</row>"#, options: [.dotMatchesLineSeparators])
        // 셀은 `<c …>값</c>` 또는 **혼자 닫히는** `<c … />` 두 가지다.
        //
        // 「내용이 있는 셀」을 먼저 보는 갈래로 짜면, 빈 셀 `<c r="B1" s="2"/>` 에서
        // 여는 태그가 `/` 까지 삼킨 뒤 **다음 셀의 `</c>` 까지 한 덩어리로** 잡힌다.
        // 그러면 다음 셀 값이 빈 셀 자리에 들어앉고 그 뒤가 한 칸씩 밀린다
        // (엑셀은 값 없이 서식만 있는 칸을 이 형태로 쓴다. 바이낸스 xlsx 는 잔고 열이 없어
        //  V-BAL 로도 못 잡으므로, 수량·대금이 다른 열에서 읽혀도 조용히 지나간다).
        //
        // 그래서 닫는 방식을 **한 정규식 안에서 같은 층위로** 고른다 — 속성은 `>` 를 넘지 않는다.
        let cPattern = try! NSRegularExpression(pattern: #"<c([^>]*?)(?:/>|>(.*?)</c>)"#, options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        for rm in rowPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let rowXML = ns.substring(with: rm.range(at: 1))
            var cells: [Int: String] = [:]
            let rns = rowXML as NSString
            for cm in cPattern.matches(in: rowXML, range: NSRange(location: 0, length: rns.length)) {
                let attrs = cm.range(at: 1).location == NSNotFound ? "" : rns.substring(with: cm.range(at: 1))
                // 혼자 닫히는 셀은 내용 자체가 없다
                let body = cm.range(at: 2).location == NSNotFound ? "" : rns.substring(with: cm.range(at: 2))
                let col = columnIndex(from: attrs)
                let value = cellValue(attrs: attrs, body: body, shared: shared)
                cells[col] = value
            }
            if cells.isEmpty { continue }
            let maxCol = cells.keys.max() ?? 0
            var row: [String] = []
            for i in 0...maxCol {
                row.append(cells[i] ?? "")
            }
            rows.append(row)
        }
        return rows
    }

    private static func columnIndex(from attrs: String) -> Int {
        // r="A1" or r="AB12"
        guard let r = attrs.range(of: #"r="([A-Z]+)(\d+)""#, options: .regularExpression) else { return 0 }
        let token = String(attrs[r])
        let letters = token.dropFirst(3).prefix(while: { $0.isLetter })
        var n = 0
        for ch in letters {
            n = n * 26 + Int(ch.asciiValue! - Character("A").asciiValue!) + 1
        }
        return max(0, n - 1)
    }

    private static func cellValue(attrs: String, body: String, shared: [String]) -> String {
        if attrs.contains("t=\"inlineStr\"") {
            // 한 칸 안에서 글씨체가 나뉘면 엑셀은 그 칸을 **조각**(`<r><t>…</t></r>`)으로 쪼개 적는다.
            // 첫 조각만 읽으면 값이 잘린다 — `1234.5` 가 `1234` 가 되어도 숫자로는 읽히므로
            // 조용히 틀린 수량·금액이 된다. 공유 문자열 쪽은 이미 조각을 이어 붙이고 있다.
            let tPattern = try! NSRegularExpression(pattern: #"<t[^>]*>(.*?)</t>"#, options: [.dotMatchesLineSeparators])
            let ns = body as NSString
            var text = ""
            for m in tPattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                text += ns.substring(with: m.range(at: 1))
            }
            return decodeXML(text)
        }
        if attrs.contains("t=\"s\"") {
            let vPattern = try! NSRegularExpression(pattern: #"<v>(.*?)</v>"#)
            let ns = body as NSString
            if let m = vPattern.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
               let idx = Int(ns.substring(with: m.range(at: 1))),
               idx >= 0, idx < shared.count {
                return shared[idx]
            }
            return ""
        }
        let vPattern = try! NSRegularExpression(pattern: #"<v>(.*?)</v>"#)
        let ns = body as NSString
        if let m = vPattern.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
            return decodeXML(ns.substring(with: m.range(at: 1)))
        }
        return ""
    }

    private static func decodeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

/// Minimal XLSX writer for tests (inlineStr only).
enum XLSXWriter {
    static func write(rows: [[String]], to url: URL) throws {
        let sheetBody = rows.enumerated().map { rIdx, row in
            let cells = row.enumerated().map { cIdx, val in
                let ref = colName(cIdx) + "\(rIdx + 1)"
                let escaped = val
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(escaped)</t></is></c>"
            }.joined()
            return "<row r=\"\(rIdx + 1)\">\(cells)</row>"
        }.joined()

        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>\(sheetBody)</sheetData>
        </worksheet>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let wb = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="sheet1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let wbRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try contentTypes.write(to: tmp.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rels.write(to: tmp.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try wb.write(to: tmp.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try wbRels.write(to: tmp.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try sheet.write(to: tmp.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)

        let proc = Process()
        proc.currentDirectoryURL = tmp
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-qr", url.path, "."]
        try proc.run()
        proc.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
        if proc.terminationStatus != 0 {
            throw CoinTaxError.parseRow("xlsx write 실패")
        }
    }

    private static func colName(_ index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            s = String(Character(UnicodeScalar(65 + n % 26)!)) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }
}
