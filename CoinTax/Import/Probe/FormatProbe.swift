import Foundation

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
        if format == .csv || format == .text {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                let prefix = data.prefix(4096)
                peek = String(decoding: prefix, as: UTF8.self)
            }
        } else if format == .xlsx {
            peek = name
        } else if format == .pdf {
            peek = name
            // try PDFKit-free name hint
        }
        return FormatProbeResult(format: format, fileName: name, peekText: peek, extensionHint: ext)
    }

    static func probe(text: String, fileName: String) -> FormatProbeResult {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let format: SourceFormat = ext == "csv" ? .csv : (ext == "txt" || ext.isEmpty ? .text : .unknown)
        return FormatProbeResult(format: format, fileName: fileName, peekText: String(text.prefix(4096)), extensionHint: ext)
    }
}
