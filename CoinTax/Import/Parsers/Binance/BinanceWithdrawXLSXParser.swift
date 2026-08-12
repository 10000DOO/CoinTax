import Foundation

struct BinanceWithdrawXLSXParser: ExchangeDocumentParser {
    let parserID = "binance-withdraw-xlsx-v1"

    func detect(_ probe: FormatProbeResult) -> Double {
        let n = probe.fileName.lowercased()
        if n.contains("withdraw") { return 0.92 }
        if probe.peekText.contains("Fee") && probe.peekText.contains("TXID") && probe.peekText.contains("Date(UTC") {
            return 0.88
        }
        if probe.format == .csv && probe.peekText.contains(",Fee,") && probe.peekText.contains("TXID") {
            return 0.85
        }
        return 0
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        if url.pathExtension.lowercased() == "csv" {
            let text = try CSVUtil.readText(url: url)
            return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
        }
        let rows = try XLSXReader.readFirstSheetRows(url: url)
        return try parseRows(rows, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        try parseRows(CSVUtil.parseLines(CSVUtil.stripBOM(text)), fileName: fileName, projectID: projectID, accountID: accountID)
    }

    private func parseRows(_ rows: [[String]], fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        guard let header = rows.first else { throw CoinTaxError.parseRow("빈 파일") }
        let map = CSVUtil.headerIndex(header)
        // 리포트센터는 `Date(UTC+0)`, 출금 화면 export 는 `Time` (타임존은 파일명에만 있다)
        guard let dateKey = ["Date(UTC+0)", "Date(UTC)", "Time"].first(where: { map[$0] != nil }),
              map["Coin"] != nil, map["Fee"] != nil else {
            throw CoinTaxError.parserReject("바이낸스 Withdraw 헤더 불일치 (읽은 열: \(map.keys.sorted().joined(separator: ", ")))")
        }
        var events: [LedgerEvent] = []
        var warnings: [String] = []
        var ignored = 0
        for dup in CSVUtil.duplicateHeaders(header) {
            warnings.append("열 이름 중복 '\(dup)' — 첫 번째 열만 사용합니다")
        }
        let tz = CSVUtil.resolveExportTimeZone(dateKey: dateKey, fileName: fileName, warnings: &warnings)
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
            guard let ts = CSVUtil.parseDate(dateStr, timeZone: tz, formats: ["yy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss"]) else {
                warnings.append("행 \(i+2) 시각 파싱 실패 '\(dateStr)' — 건너뜀")
                continue
            }
            guard let amount = Money.parseDecimal(col("Amount")), amount != 0 else {
                warnings.append("행 \(i+2) Amount 파싱 실패 — 건너뜀")
                continue
            }
            let fee = Money.parseDecimal(col("Fee"))
            let coin = col("Coin")
            let txid = col("TXID")
            let addr = col("Address")
            var e = LedgerEvent(
                projectID: projectID,
                accountID: accountID,
                externalID: txid.isEmpty ? nil : txid,
                timestamp: ts,
                type: .withdrawal,
                baseAsset: AssetSymbol(coin),
                quantity: -Money.abs(amount),
                feeAmount: fee.map { Money.abs($0) },
                feeAsset: fee != nil ? AssetSymbol(coin) : nil,
                network: col("Network"),
                addressHash: addr.isEmpty ? nil : Fingerprint.sha256Hex(addr),
                txidHash: txid.isEmpty ? nil : Fingerprint.sha256Hex(txid),
                sourceKind: parserID,
                rawRef: "row\(i+2)"
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }
        return ParseResult(parserID: parserID, events: events, meta: ["timezone": tz.identifier], warnings: warnings, errors: [], ignoredCount: ignored)
    }
}
