import Foundation

struct BinanceSpotXLSXParser: ExchangeDocumentParser {
    let parserID = "binance-spot-xlsx-v1"

    func detect(_ probe: FormatProbeResult) -> Double {
        let n = probe.fileName.lowercased()
        if n.contains("spot") && n.contains("trade") { return 0.9 }
        if probe.peekText.contains("Date(UTC)") && probe.peekText.contains("Fee Coin") { return 0.95 }
        if probe.format == .xlsx && n.contains("spot") { return 0.7 }
        if probe.format == .csv && probe.peekText.contains("Base Asset") && probe.peekText.contains("Fee Coin") { return 0.9 }
        return 0
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        if url.pathExtension.lowercased() == "csv" {
            let text = try String(contentsOf: url, encoding: .utf8)
            return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
        }
        let rows = try XLSXReader.readFirstSheetRows(url: url)
        return try parseRows(rows, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let rows = CSVUtil.parseLines(text)
        return try parseRows(rows, projectID: projectID, accountID: accountID)
    }

    private func parseRows(_ rows: [[String]], projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        guard let header = rows.first else {
            throw CoinTaxError.parseRow("빈 파일")
        }
        let map = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        guard map["Date(UTC)"] != nil, map["Base Asset"] != nil else {
            throw CoinTaxError.parserReject("바이낸스 Spot 헤더 불일치")
        }
        var events: [LedgerEvent] = []
        var warnings: [String] = []
        for (i, row) in rows.dropFirst().enumerated() {
            func col(_ name: String) -> String {
                guard let idx = map[name], idx < row.count else { return "" }
                return row[idx]
            }
            let dateStr = col("Date(UTC)")
            guard !dateStr.isEmpty else { continue }
            guard let ts = CSVUtil.parseDate(dateStr, timeZone: TimeZone(secondsFromGMT: 0)!, formats: ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"]) else {
                warnings.append("행 \(i+2) 날짜 파싱 실패")
                continue
            }
            let typeStr = col("Type").uppercased()
            let type: EventType = typeStr == "BUY" ? .buy : .sell
            let amount = Money.parseDecimal(col("Amount")) ?? 0
            let qty = type == .buy ? amount : -amount
            var e = LedgerEvent(
                projectID: projectID,
                accountID: accountID,
                timestamp: ts,
                type: type,
                baseAsset: AssetSymbol(col("Base Asset")),
                quoteAsset: AssetSymbol(col("Quote Asset")),
                quantity: qty,
                price: Money.parseDecimal(col("Price")),
                quoteAmount: Money.parseDecimal(col("Total")),
                feeAmount: Money.parseDecimal(col("Fee")),
                feeAsset: AssetSymbol(col("Fee Coin")),
                sourceKind: parserID,
                rawRef: "row\(i+2)"
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }
        return ParseResult(parserID: parserID, events: events, meta: [:], warnings: warnings, errors: [], ignoredCount: 0)
    }
}
