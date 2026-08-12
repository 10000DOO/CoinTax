import Foundation
import PDFKit

struct FormatProbeResult: Sendable {
    var format: SourceFormat
    var fileName: String
    var peekText: String
    var extensionHint: String
}

enum FormatProbe {
    static func probe(url: URL) -> FormatProbeResult {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let format: SourceFormat
        switch ext {
        case "pdf": format = .pdf
        case "xlsx", "xls": format = .xlsx
        case "csv", "tsv": format = .csv
        case "txt": format = .text
        default: format = .unknown
        }
        var peek = ""
        switch format {
        case .csv, .text:
            if let text = try? CSVUtil.readText(url: url) {
                peek = String(text.prefix(4096))
            }
        case .xlsx:
            // 헤더 행을 실제로 읽는다. 파일명만 보면 이름을 바꿔 저장한 파일을 인식하지 못한다(리뷰 2-5).
            if let rows = try? XLSXReader.readFirstSheetRows(url: url), let header = rows.first {
                peek = name + "\n" + header.joined(separator: ",")
            } else {
                peek = name
            }
        case .pdf:
            // 제목·헤더 문자열로 빗썸 확인서/원천징수영수증을 구분해야 한다(F-IM-02, F-IM-10).
            peek = name + "\n" + (Self.pdfHeadText(url: url) ?? "")
        case .unknown:
            peek = name
        }
        return FormatProbeResult(format: format, fileName: name, peekText: peek, extensionHint: ext)
    }

    /// PDF 앞부분 텍스트 (암호 PDF는 빈 문자열). 개인정보가 섞일 수 있으므로 로그로 남기지 않는다.
    static func pdfHeadText(url: URL, maxPages: Int = 2, limit: Int = 4096) -> String? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        var text = ""
        for i in 0..<min(doc.pageCount, maxPages) {
            text += doc.page(at: i)?.string ?? ""
            text += "\n"
            if text.count >= limit { break }
        }
        return String(text.prefix(limit))
    }

    static func probe(text: String, fileName: String) -> FormatProbeResult {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let format: SourceFormat = ext == "csv" ? .csv : (ext == "txt" || ext.isEmpty ? .text : .unknown)
        let clean = CSVUtil.stripBOM(text)
        return FormatProbeResult(format: format, fileName: fileName, peekText: String(clean.prefix(4096)), extensionHint: ext)
    }
}
