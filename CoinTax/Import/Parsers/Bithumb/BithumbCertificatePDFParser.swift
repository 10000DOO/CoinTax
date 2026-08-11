import Foundation
import PDFKit

struct BithumbCertificatePDFParser: ExchangeDocumentParser {
    let parserID = "bithumb-certificate-pdf-v1"
    /// 암호 PDF 잠금 해제용 (UI에서 전달)
    var password: String?

    func detect(_ probe: FormatProbeResult) -> Double {
        let n = probe.fileName.lowercased()
        if probe.peekText.contains("원천징수영수증") { return 0 } // reject path
        if probe.peekText.contains("거래내역 확인서") { return 0.98 }
        if n.contains("bithumb") || n.contains("빗썸") || n.contains("거래내역") { return 0.7 }
        if probe.format == .pdf { return 0.4 }
        if probe.format == .text && probe.peekText.contains("거래구분") { return 0.85 }
        return 0
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let ext = url.pathExtension.lowercased()
        if ext == "txt" || ext == "text" {
            let text = try String(contentsOf: url, encoding: .utf8)
            return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
        }
        guard let doc = PDFDocument(url: url) else {
            throw CoinTaxError.parserReject("PDF를 열 수 없습니다")
        }
        if doc.isLocked {
            let pw = password ?? ""
            guard !pw.isEmpty, doc.unlock(withPassword: pw) else {
                throw CoinTaxError.pdfPassword
            }
        }
        var text = ""
        for i in 0..<doc.pageCount {
            text += doc.page(at: i)?.string ?? ""
            text += "\n"
        }
        if text.contains("원천징수영수증") {
            throw CoinTaxError.parserReject("거래내역 확인서가 아닙니다 (원천징수영수증)")
        }
        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        if text.contains("원천징수영수증") {
            throw CoinTaxError.parserReject("거래내역 확인서가 아닙니다 (원천징수영수증)")
        }
        // Synthetic / extracted text format (pipe or tab separated rows):
        // date\ttime\tasset\ttype\tqty\tprice\ttradeAmt\tsettleAmt\tmemo
        // or free text lines starting with yyyy-MM-dd
        var events: [LedgerEvent] = []
        var warnings: [String] = []
        let lines = text.components(separatedBy: .newlines)

        let rowRegex = try! NSRegularExpression(
            pattern: #"(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})\s+(\S+)\s+(매수|매도|입금|출금)\s+([\d,\.]+)\s+([\d,\.]*)\s+([\d,\.\-]*)\s+([\d,\.\-]*)\s*(.*)"#
        )

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // pipe-delimited synthetic
            if trimmed.contains("|") {
                let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                // date|time|asset|type|qty|price|tradeAmt|settle|memo
                if parts.count >= 5 {
                    if let e = makeEvent(parts: parts, projectID: projectID, accountID: accountID, rawRef: "line\(i+1)") {
                        events.append(e)
                    }
                    continue
                }
            }
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = rowRegex.firstMatch(in: trimmed, range: range) {
                func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
                let parts = [g(1), g(2), g(3), g(4), g(5), g(6), g(7), g(8), g(9)]
                if let e = makeEvent(parts: parts, projectID: projectID, accountID: accountID, rawRef: "line\(i+1)") {
                    events.append(e)
                }
            }
        }

        if events.isEmpty {
            warnings.append("추출된 거래 행이 없습니다")
        }
        return ParseResult(parserID: parserID, events: events, meta: [:], warnings: warnings, errors: [], ignoredCount: 0)
    }

    private func makeEvent(parts: [String], projectID: ProjectID, accountID: AccountID, rawRef: String) -> LedgerEvent? {
        guard parts.count >= 5 else { return nil }
        let date = parts[0]
        let time = parts[1]
        let asset = parts[2]
        let typeKO = parts[3]
        let qty = Money.parseDecimal(parts[4]) ?? 0
        let price = parts.count > 5 ? Money.parseDecimal(parts[5]) : nil
        let settle = parts.count > 7 ? Money.parseDecimal(parts[7]) : (parts.count > 6 ? Money.parseDecimal(parts[6]) : nil)
        let memo = parts.count > 8 ? parts[8] : ""

        let ts = CSVUtil.parseDate("\(date) \(time)", timeZone: TaxTime.seoul, formats: ["yyyy-MM-dd HH:mm:ss"])
            ?? CSVUtil.parseDate("\(date) \(time)", timeZone: TaxTime.seoul, formats: ["yyyy-MM-dd HH:mm"])
        guard let timestamp = ts else { return nil }

        if asset.uppercased() == "KRW" {
            let type: EventType = typeKO == "입금" ? .fiatDeposit : (typeKO == "출금" ? .fiatWithdraw : .other)
            if memo.contains("예치금 이용료") {
                var e = LedgerEvent(
                    projectID: projectID, accountID: accountID, timestamp: timestamp,
                    type: .income, baseAsset: AssetSymbol("KRW"), quantity: Money.abs(qty),
                    quoteAmountKRW: settle.map { Money.abs($0) },
                    memo: memo, sourceKind: parserID, rawRef: rawRef
                )
                e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
                return e
            }
            var e = LedgerEvent(
                projectID: projectID, accountID: accountID, timestamp: timestamp,
                type: type, baseAsset: AssetSymbol("KRW"), quantity: type == .fiatDeposit ? Money.abs(qty) : -Money.abs(qty),
                quoteAmountKRW: settle.map { Money.abs($0) },
                memo: memo, sourceKind: parserID, rawRef: rawRef
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            return e
        }

        let type: EventType
        let quantity: Decimal
        switch typeKO {
        case "매수": type = .buy; quantity = Money.abs(qty)
        case "매도": type = .sell; quantity = -Money.abs(qty)
        case "입금": type = .deposit; quantity = Money.abs(qty)
        case "출금": type = .withdrawal; quantity = -Money.abs(qty)
        default: return nil
        }

        var hint: String?
        if memo.contains("바이낸스") || memo.lowercased().contains("binance") { hint = "binance" }
        if memo.uppercased().contains("OKX") { hint = "okx" }

        var e = LedgerEvent(
            projectID: projectID,
            accountID: accountID,
            timestamp: timestamp,
            type: type,
            baseAsset: AssetSymbol(asset),
            quoteAsset: (type == .buy || type == .sell) ? AssetSymbol("KRW") : nil,
            quantity: quantity,
            price: price,
            quoteAmountKRW: settle.map { Money.abs($0) },
            memo: memo.isEmpty ? nil : memo,
            counterpartyHint: hint,
            sourceKind: parserID,
            rawRef: rawRef
        )
        e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
        return e
    }
}
