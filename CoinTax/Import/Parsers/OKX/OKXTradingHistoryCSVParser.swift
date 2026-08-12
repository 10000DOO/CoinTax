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

        // 파일 안 위치를 함께 들고 다닌다. 주문(Spot)은 여러 행이 묶이므로 딕셔너리로 모으는데,
        // 그대로 꺼내면 순서가 매번 달라지고 **입금과 그 돈으로 한 매수의 순서가 뒤집힌다**.
        var pending: [(fileIndex: Int, event: LedgerEvent)] = []
        var warnings: [String] = []
        var ignored = 0

        // Transfer rows → individual events
        // Spot rows → group by Order id
        var spotGroups: [String: [[String]]] = [:]
        var spotFirstIndex: [String: Int] = [:]

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
                    rawRef: "row\(i+3)",
                    balanceAfter: Money.parseDecimal(col(row, "Balance"))
                )
                e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
                pending.append((fileIndex: i, event: e))
                transferCount += 1
            } else if tradeType == "Spot" {
                let oid = col(row, "Order id")
                spotGroups[oid, default: []].append(row)
                if spotFirstIndex[oid] == nil { spotFirstIndex[oid] = i }
            } else {
                ignored += 1
            }
        }

        for oid in spotGroups.keys.sorted(by: { (spotFirstIndex[$0] ?? 0) < (spotFirstIndex[$1] ?? 0) }) {
            guard let group = spotGroups[oid] else { continue }
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
            // 주문 직후 잔고 — 우리 계산의 정답지 (V-BAL).
            // 한 주문이 여러 행으로 쪼개지므로 **각 자산의 마지막 행** 값을 쓴다 (id 가 클수록 나중).
            var lastBalance: [String: (id: String, value: Decimal)] = [:]

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
                if !unit.isEmpty, let bal = Money.parseDecimal(col(row, "Balance")) {
                    let rid = col(row, "id")
                    // id 는 숫자 문자열이다. 자릿수가 다르면 문자열 비교가 뒤집히므로 길이를 먼저 본다.
                    func isLater(_ a: String, than b: String) -> Bool {
                        a.count != b.count ? a.count > b.count : a > b
                    }
                    if let prev = lastBalance[unit], !isLater(rid, than: prev.id) { continue }
                    lastBalance[unit] = (id: rid, value: bal)
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
                quantityIsNetOfFee: isNet,
                balanceAfter: lastBalance[base]?.value,
                quoteBalanceAfter: lastBalance[quote]?.value
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            pending.append((fileIndex: spotFirstIndex[oid] ?? 0, event: e))
        }

        if transferCount > 0 {
            warnings.append("Transfer \(transferCount)건은 거래소 내부 이동(거래↔펀딩 계정)으로 처리했습니다. 국내↔해외 전송 매칭에는 OKX Funding History의 Deposit/Withdrawal이 필요합니다.")
        }

        // 파일 순서로 되돌린 뒤 시간 오름차순으로 바로잡는다.
        // OKX 파일은 최신순이라, 파일 순서를 그대로 두면 같은 시각의 이동·체결이 거꾸로 들어간다.
        let fileOrdered = pending.sorted { $0.fileIndex < $1.fileIndex }.map(\.event)
        return ParseResult(
            parserID: parserID,
            events: RowOrder.chronological(fileOrdered),
            meta: ["timezone": metaLine, "ignoredCount": "\(ignored)", "internalTransfers": "\(transferCount)"],
            warnings: warnings,
            errors: [],
            ignoredCount: ignored
        )
    }
}
