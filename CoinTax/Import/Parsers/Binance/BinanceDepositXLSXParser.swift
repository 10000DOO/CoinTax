import Foundation

struct BinanceDepositXLSXParser: ExchangeDocumentParser {
    let parserID = "binance-deposit-xlsx-v1"

    func detect(_ probe: FormatProbeResult) -> Double {
        let n = probe.fileName.lowercased()
        if n.contains("deposit") { return 0.92 }
        if probe.peekText.contains("Date(UTC+0)") && probe.peekText.contains("TXID") && !probe.peekText.contains("Fee") {
            return 0.9
        }
        if probe.format == .csv && probe.peekText.contains("Coin") && probe.peekText.contains("TXID") && !probe.peekText.contains(",Fee,") {
            return 0.85
        }
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
        try parseRows(CSVUtil.parseLines(text), projectID: projectID, accountID: accountID)
    }

    private func parseRows(_ rows: [[String]], projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        guard let header = rows.first else { throw CoinTaxError.parseRow("빈 파일") }
        let map = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        let dateKey = map["Date(UTC+0)"] != nil ? "Date(UTC+0)" : "Date(UTC)"
        guard map[dateKey] != nil, map["Coin"] != nil else {
            throw CoinTaxError.parserReject("바이낸스 Deposit 헤더 불일치")
        }
        var events: [LedgerEvent] = []
        var ignored = 0
        for (i, row) in rows.dropFirst().enumerated() {
            func col(_ name: String) -> String {
                guard let idx = map[name], idx < row.count else { return "" }
                return row[idx]
            }
            let status = col("Status")
            if !status.isEmpty && status.lowercased() != "completed" {
                ignored += 1
                continue
            }
            let dateStr = col(dateKey)
            guard let ts = CSVUtil.parseDate(dateStr, timeZone: TimeZone(secondsFromGMT: 0)!, formats: ["yy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"]) else {
                continue
            }
            let amount = Money.parseDecimal(col("Amount")) ?? 0
            let txid = col("TXID")
            let addr = col("Address")
            var e = LedgerEvent(
                projectID: projectID,
                accountID: accountID,
                externalID: txid.isEmpty ? nil : txid,
                timestamp: ts,
                type: .deposit,
                baseAsset: AssetSymbol(col("Coin")),
                quantity: amount,
                network: col("Network"),
                addressHash: addr.isEmpty ? nil : Fingerprint.sha256Hex(addr),
                txidHash: txid.isEmpty ? nil : Fingerprint.sha256Hex(txid),
                sourceKind: parserID,
                rawRef: "row\(i+2)"
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }
        return ParseResult(parserID: parserID, events: events, meta: [:], warnings: [], errors: [], ignoredCount: ignored)
    }
}
