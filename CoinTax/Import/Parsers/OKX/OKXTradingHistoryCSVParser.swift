import Foundation

struct OKXTradingHistoryCSVParser: ExchangeDocumentParser {
    let parserID = "okx-trading-history-csv-v1"

    func detect(_ probe: FormatProbeResult) -> Double {
        let n = probe.fileName.lowercased()
        if n.contains("trading history") || n.contains("trading_history") { return 0.95 }
        if probe.peekText.contains("Order id") && probe.peekText.contains("Trade Type") { return 0.95 }
        return 0
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let lines = CSVUtil.parseLines(text)
        guard lines.count >= 2 else { throw CoinTaxError.parseRow("OKX Trading 파일 너무 짧음") }
        let metaLine = lines[0].joined(separator: ",")
        let tz = CSVUtil.parseTimezoneOffset(metaLine)
        let header = lines[1]
        let map = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        guard map["Order id"] != nil, map["Trade Type"] != nil else {
            throw CoinTaxError.parserReject("OKX Trading 헤더 불일치")
        }

        func col(_ row: [String], _ name: String) -> String {
            guard let idx = map[name], idx < row.count else { return "" }
            return row[idx]
        }

        var events: [LedgerEvent] = []
        var warnings: [String] = []
        var ignored = 0

        // Transfer rows → individual events
        // Spot rows → group by Order id
        var spotGroups: [String: [[String]]] = [:]

        for (i, row) in lines.dropFirst(2).enumerated() {
            let tradeType = col(row, "Trade Type")
            if tradeType == "Transfer" {
                let action = col(row, "Action")
                let balChange = Money.parseDecimal(col(row, "Balance Change")) ?? 0
                let unit = col(row, "Balance Unit")
                let timeStr = col(row, "Time")
                guard let ts = CSVUtil.parseDate(timeStr, timeZone: tz, formats: ["yyyy-MM-dd HH:mm:ss"]) else {
                    warnings.append("Transfer 행 \(i+3) 시각 실패")
                    continue
                }
                let type: EventType = action.lowercased().contains("in") ? .deposit : .withdrawal
                let qty: Decimal = type == .deposit ? Money.abs(balChange) : -Money.abs(balChange)
                var e = LedgerEvent(
                    projectID: projectID,
                    accountID: accountID,
                    externalID: col(row, "id").isEmpty ? nil : col(row, "id"),
                    timestamp: ts,
                    type: type,
                    baseAsset: AssetSymbol(unit),
                    quantity: qty,
                    sourceKind: parserID,
                    rawRef: "row\(i+3)"
                )
                e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
                events.append(e)
            } else if tradeType == "Spot" {
                let oid = col(row, "Order id")
                spotGroups[oid, default: []].append(row)
            } else {
                ignored += 1
            }
        }

        for (oid, group) in spotGroups {
            guard let first = group.first else { continue }
            let symbol = col(first, "Symbol") // BTC-USDT
            let parts = symbol.split(separator: "-").map(String.init)
            guard parts.count == 2 else {
                warnings.append("Symbol 파싱 실패 \(symbol)")
                continue
            }
            let base = parts[0]
            let quote = parts[1]
            var netBase: Decimal = 0
            var netQuote: Decimal = 0
            var feeBase: Decimal = 0
            var feeAsset: String?
            var price: Decimal?
            var time: Date?
            var actionHint = ""

            for row in group {
                let unit = col(row, "Balance Unit")
                let change = Money.parseDecimal(col(row, "Balance Change")) ?? 0
                if unit == base { netBase += change }
                if unit == quote { netQuote += change }
                let fee = Money.parseDecimal(col(row, "Fee")) ?? 0
                let fu = col(row, "Fee Unit")
                if fu == base { feeBase += Money.abs(fee) }
                if fee != 0 { feeAsset = fu }
                if let p = Money.parseDecimal(col(row, "Filled Price")), p != 0 { price = p }
                if time == nil {
                    time = CSVUtil.parseDate(col(row, "Time"), timeZone: tz, formats: ["yyyy-MM-dd HH:mm:ss"])
                }
                let a = col(row, "Action")
                if a == "Buy" || a == "Sell" { actionHint = a }
            }

            guard let ts = time else { continue }
            let type: EventType
            let qty: Decimal
            if netBase > 0 {
                type = .buy
                qty = netBase
            } else if netBase < 0 {
                type = .sell
                qty = netBase // negative
            } else if actionHint == "Buy" {
                type = .buy
                qty = Money.abs(Money.parseDecimal(col(first, "Amount")) ?? 0)
            } else {
                type = .sell
                qty = -Money.abs(Money.parseDecimal(col(first, "Amount")) ?? 0)
            }

            var e = LedgerEvent(
                projectID: projectID,
                accountID: accountID,
                externalID: oid,
                timestamp: ts,
                type: type,
                baseAsset: AssetSymbol(base),
                quoteAsset: AssetSymbol(quote),
                quantity: qty,
                price: price,
                quoteAmount: Money.abs(netQuote) == 0 ? nil : Money.abs(netQuote),
                feeAmount: feeBase > 0 ? feeBase : nil,
                feeAsset: feeAsset.map { AssetSymbol($0) },
                sourceKind: parserID,
                rawRef: "order:\(oid)"
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }

        return ParseResult(
            parserID: parserID,
            events: events.sorted { $0.timestamp < $1.timestamp },
            meta: ["timezone": metaLine, "ignoredCount": "\(ignored)"],
            warnings: warnings,
            errors: [],
            ignoredCount: ignored
        )
    }
}
