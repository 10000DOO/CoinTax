import Foundation

struct OKXFundingHistoryCSVParser: ExchangeDocumentParser {
    let parserID = "okx-funding-history-csv-v1"

    func detect(_ probe: FormatProbeResult) -> Double {
        let n = probe.fileName.lowercased()
        if n.contains("funding history") || n.contains("funding_history") { return 0.95 }
        if probe.peekText.contains("Before Balance") && probe.peekText.contains("After Balance") && probe.peekText.contains("Type") {
            return 0.9
        }
        return 0
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let lines = CSVUtil.parseLines(text)
        guard lines.count >= 2 else { throw CoinTaxError.parseRow("OKX Funding 파일 너무 짧음") }
        let metaLine = lines[0].joined(separator: ",")
        let tz = CSVUtil.parseTimezoneOffset(metaLine)
        let header = lines[1]
        let map = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        guard map["Type"] != nil, map["Amount"] != nil, map["Symbol"] != nil else {
            throw CoinTaxError.parserReject("OKX Funding 헤더 불일치")
        }

        func col(_ row: [String], _ name: String) -> String {
            guard let idx = map[name], idx < row.count else { return "" }
            return row[idx]
        }

        var events: [LedgerEvent] = []
        var ignored = 0
        for (i, row) in lines.dropFirst(2).enumerated() {
            let typeStr = col(row, "Type")
            let amount = Money.parseDecimal(col(row, "Amount")) ?? 0
            let symbol = col(row, "Symbol")
            let timeStr = col(row, "Time")
            guard let ts = CSVUtil.parseDate(timeStr, timeZone: tz, formats: ["yyyy-MM-dd HH:mm:ss"]) else {
                continue
            }
            let mapped: (EventType, Decimal)?
            switch typeStr {
            case "Deposit", "Received":
                mapped = (.deposit, Money.abs(amount))
            case "Withdrawal":
                mapped = (.withdrawal, -Money.abs(amount))
            case "From unified trading account":
                mapped = (.transferInternal, Money.abs(amount))
            case "To unified trading account":
                mapped = (.transferInternal, -Money.abs(amount))
            case "Fee rebate":
                mapped = (.income, Money.abs(amount))
            default:
                mapped = nil
            }
            guard let (etype, qty) = mapped else {
                ignored += 1
                continue
            }
            var e = LedgerEvent(
                projectID: projectID,
                accountID: accountID,
                externalID: col(row, "id").isEmpty ? nil : col(row, "id"),
                timestamp: ts,
                type: etype,
                baseAsset: AssetSymbol(symbol),
                quantity: qty,
                memo: typeStr,
                sourceKind: parserID,
                rawRef: "row\(i+3)"
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }
        return ParseResult(
            parserID: parserID,
            events: events,
            meta: ["timezone": metaLine],
            warnings: [],
            errors: [],
            ignoredCount: ignored
        )
    }
}
