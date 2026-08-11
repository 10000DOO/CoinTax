import Foundation
import Compression

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
        let cPattern = try! NSRegularExpression(pattern: #"<c([^>]*)>(.*?)</c>|<c([^/]*)/>"#, options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        for rm in rowPattern.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let rowXML = ns.substring(with: rm.range(at: 1))
            var cells: [Int: String] = [:]
            let rns = rowXML as NSString
            for cm in cPattern.matches(in: rowXML, range: NSRange(location: 0, length: rns.length)) {
                let attrs: String
                let body: String
                if cm.range(at: 1).location != NSNotFound {
                    attrs = rns.substring(with: cm.range(at: 1))
                    body = rns.substring(with: cm.range(at: 2))
                } else if cm.range(at: 3).location != NSNotFound {
                    attrs = rns.substring(with: cm.range(at: 3))
                    body = ""
                } else {
                    attrs = ""
                    body = ""
                }
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
            if let r = body.range(of: #"<t[^>]*>(.*?)</t>"#, options: .regularExpression) {
                let inner = String(body[r])
                if let t = inner.range(of: #">(.+)<"#, options: .regularExpression) {
                    // simpler extract
                }
            }
            let tPattern = try! NSRegularExpression(pattern: #"<t[^>]*>(.*?)</t>"#)
            let ns = body as NSString
            if let m = tPattern.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) {
                return decodeXML(ns.substring(with: m.range(at: 1)))
            }
            return ""
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
