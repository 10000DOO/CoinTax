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
        let text = try CSVUtil.readText(url: url)
        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let lines = CSVUtil.parseLines(CSVUtil.stripBOM(text))
        guard lines.count >= 2 else { throw CoinTaxError.parseRow("OKX Trading 파일 너무 짧음") }
        let metaLine = lines[0].joined(separator: ",")
        let tz = CSVUtil.parseTimezoneOffset(metaLine)
        let header = lines[1]
        let map = CSVUtil.headerIndex(header)
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

        var transferCount = 0
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
                // Trading History의 Transfer 행은 **거래 계정 ↔ 펀딩 계정 내부 이동**의 거래 계정 쪽 기록이다.
                // 외부 입출금은 Funding History의 Deposit/Withdrawal에 찍힌다
                // (docs/parsers/okx-funding-history.md §3). 여기서 외부 입출금으로 잡으면
                // 두 파일을 함께 가져온 경우 같은 이동이 이중 반영된다 — 리뷰 1-3.
                let inbound = action.range(of: #"(?i)\btransfer\s+in\b"#, options: .regularExpression) != nil
                let qty: Decimal = inbound ? Money.abs(balChange) : -Money.abs(balChange)
                var e = LedgerEvent(
                    projectID: projectID,
                    accountID: accountID,
                    externalID: col(row, "id").isEmpty ? nil : col(row, "id"),
                    timestamp: ts,
                    type: .transferInternal,
                    baseAsset: AssetSymbol(unit),
                    quantity: qty,
                    memo: action,
                    sourceKind: parserID,
                    rawRef: "row\(i+3)"
                )
                e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
                events.append(e)
                transferCount += 1
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
            var amountBase: Decimal = 0   // Amount 컬럼 합 (base 레그) — 순액 판정에 쓴다

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
                // base 자산의 잔고가 움직인 레그의 Amount 만 더한다.
                // `Trading Unit` 은 견적 레그에도 base 가 적혀 있는 파일이 있어 기준으로 쓸 수 없다.
                if unit == base {
                    amountBase += Money.abs(Money.parseDecimal(col(row, "Amount")) ?? 0)
                }
            }

            guard let ts = time else { continue }

            // `Balance Change` 가 수수료를 이미 뺀 순증분인지 **파일 안의 숫자로 판정**한다.
            //
            // 거래소 관례를 문서만 보고 단정하면 위험하다. 여기서는 세 값의 관계로 확인한다:
            //   |Balance Change| ≈ Amount − Fee  →  순액 (엔진이 수수료를 다시 빼면 이중 차감)
            //   |Balance Change| ≈ Amount        →  총액 (엔진이 빼야 함)
            // 판정이 안 되면 아무것도 가정하지 않고 경고를 남긴 뒤 총액으로 둔다(기존 동작 유지).
            var isNet = false
            if feeBase > 0, amountBase > 0 {
                let observed = Money.abs(netBase)
                let tolerance = max(amountBase * Decimal(string: "0.0001")!, Money.qtyEpsilon)
                if Money.abs(observed - (amountBase - feeBase)) <= tolerance {
                    isNet = true
                } else if Money.abs(observed - amountBase) <= tolerance {
                    isNet = false
                } else {
                    warnings.append(
                        "주문 \(oid): 수량(Amount \(Money.decimalString(amountBase)))·수수료(\(Money.decimalString(feeBase)))·잔고증감(\(Money.decimalString(observed)))의 관계를 판정하지 못했습니다. 수수료 차감 전 수량으로 처리했습니다 — 보유 수량을 확인하세요."
                    )
                }
            }

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
                feeAsset: feeBase > 0 ? feeAsset.map { AssetSymbol($0) } : nil,
                sourceKind: parserID,
                rawRef: "order:\(oid)",
                quantityIsNetOfFee: isNet
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }

        if transferCount > 0 {
            warnings.append("Transfer \(transferCount)건은 거래소 내부 이동(거래↔펀딩 계정)으로 처리했습니다. 국내↔해외 전송 매칭에는 OKX Funding History의 Deposit/Withdrawal이 필요합니다.")
        }

        return ParseResult(
            parserID: parserID,
            events: events.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return ($0.rawRef ?? "") < ($1.rawRef ?? "")
            },
            meta: ["timezone": metaLine, "ignoredCount": "\(ignored)", "internalTransfers": "\(transferCount)"],
            warnings: warnings,
            errors: [],
            ignoredCount: ignored
        )
    }
}
