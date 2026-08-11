import Foundation

/// 표 형태 CSV/XLSX 폴백: 표준 컬럼명 또는 사용자 메타 매핑.
/// 헤더 동의어로 최소 자동 매핑. 사용자 매핑 dict 주입 가능.
struct GenericTabularMapper: ExchangeDocumentParser {
    let parserID = "generic-tabular-v1"

    /// 표준 필드 → 가능한 헤더 별칭
    static let defaultAliases: [String: [String]] = [
        "timestamp": ["timestamp", "date", "time", "datetime", "date(utc)", "date(utc+0)", "거래일시", "time"],
        "type": ["type", "side", "action", "trade type", "거래구분"],
        "baseAsset": ["base", "base asset", "asset", "coin", "symbol", "자산명", "baseasset"],
        "quoteAsset": ["quote", "quote asset", "quoteasset"],
        "quantity": ["quantity", "amount", "qty", "거래수량", "filled amount"],
        "price": ["price", "filled price", "체결가격"],
        "quoteAmount": ["total", "quote amount", "거래금액"],
        "quoteAmountKRW": ["quoteamountkrw", "정산금액", "settlement", "krw"],
        "feeAmount": ["fee", "fee amount"],
        "feeAsset": ["fee coin", "fee unit", "fee asset"],
        "externalID": ["id", "txid", "order id", "trade id"]
    ]

    var columnMap: [String: String] // standardField -> actual header name (case-insensitive match applied)

    init(columnMap: [String: String] = [:]) {
        self.columnMap = columnMap
    }

    func detect(_ probe: FormatProbeResult) -> Double {
        if probe.format != .csv && probe.format != .xlsx && probe.format != .text { return 0 }
        // Only as fallback — low score so presets win
        let peek = probe.peekText.lowercased()
        if peek.contains("date") || peek.contains("amount") || peek.contains("type") { return 0.35 }
        return 0.31
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" || ext == "xls" {
            let rows = try XLSXReader.readFirstSheetRows(url: url)
            return try parseRows(rows, projectID: projectID, accountID: accountID, fileName: url.lastPathComponent)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let lines = CSVUtil.parseLines(text)
        return try parseRows(lines, projectID: projectID, accountID: accountID, fileName: fileName)
    }

    private func parseRows(_ rows: [[String]], projectID: ProjectID, accountID: AccountID, fileName: String) throws -> ParseResult {
        guard let header = rows.first, header.count >= 2 else {
            throw CoinTaxError.parseRow("제네릭 표: 헤더 없음")
        }
        let resolved = resolveHeaders(header)
        guard resolved["timestamp"] != nil, resolved["type"] != nil || resolved["baseAsset"] != nil else {
            throw CoinTaxError.parseRow("제네릭 표: timestamp/type 컬럼을 찾지 못함")
        }

        var events: [LedgerEvent] = []
        var warnings: [String] = []
        var errors: [String] = []

        for (i, row) in rows.dropFirst().enumerated() {
            func cell(_ field: String) -> String {
                guard let col = resolved[field], let idx = header.firstIndex(of: col), idx < row.count else {
                    // try case-insensitive header index
                    if let col = resolved[field],
                       let idx = header.firstIndex(where: { $0.caseInsensitiveCompare(col) == .orderedSame }),
                       idx < row.count {
                        return row[idx]
                    }
                    return ""
                }
                return row[idx]
            }

            let typeRaw = cell("type").trimmingCharacters(in: .whitespaces)
            let base = cell("baseAsset")
            let qtyRaw = cell("quantity")
            if typeRaw.isEmpty && base.isEmpty { continue }

            guard let type = mapType(typeRaw) else {
                errors.append("행 \(i + 2): 알 수 없는 type '\(typeRaw)'")
                continue
            }
            guard let qtyAbs = Money.parseDecimal(qtyRaw), qtyAbs != 0 || type == .deposit || type == .withdrawal else {
                errors.append("행 \(i + 2): 수량 파싱 실패")
                continue
            }
            let signed: Decimal = {
                switch type {
                case .sell, .withdrawal, .fiatWithdraw, .fee: return -Money.abs(qtyAbs)
                default: return Money.abs(qtyAbs)
                }
            }()

            let tsStr = cell("timestamp")
            let ts = CSVUtil.parseDate(tsStr, timeZone: TimeZone(secondsFromGMT: 0)!, formats: [
                "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yy-MM-dd HH:mm:ss"
            ]) ?? CSVUtil.parseDate(tsStr, timeZone: TaxTime.seoul, formats: ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"])
            guard let timestamp = ts else {
                errors.append("행 \(i + 2): 시각 파싱 실패 '\(tsStr)'")
                continue
            }

            let quote = cell("quoteAsset")
            let price = Money.parseDecimal(cell("price"))
            let quoteAmt = Money.parseDecimal(cell("quoteAmount"))
            let krw = Money.parseDecimal(cell("quoteAmountKRW"))
            let fee = Money.parseDecimal(cell("feeAmount"))
            let feeAsset = cell("feeAsset")
            let ext = cell("externalID")

            var e = LedgerEvent(
                projectID: projectID,
                accountID: accountID,
                externalID: ext.isEmpty ? nil : ext,
                timestamp: timestamp,
                type: type,
                baseAsset: AssetSymbol(base.isEmpty ? "UNKNOWN" : base),
                quoteAsset: quote.isEmpty ? nil : AssetSymbol(quote),
                quantity: signed,
                price: price,
                quoteAmount: quoteAmt.map { Money.abs($0) },
                quoteAmountKRW: krw.map { Money.abs($0) },
                feeAmount: fee.map { Money.abs($0) },
                feeAsset: feeAsset.isEmpty ? nil : AssetSymbol(feeAsset),
                sourceKind: parserID,
                rawRef: "row\(i + 2)"
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }

        if events.isEmpty && errors.isEmpty {
            warnings.append("제네릭 표에서 이벤트가 없습니다")
        }

        return ParseResult(
            parserID: parserID,
            events: events,
            meta: ["fileName": fileName, "mappedColumns": resolved.keys.sorted().joined(separator: ",")],
            warnings: warnings,
            errors: errors,
            ignoredCount: 0
        )
    }

    private func resolveHeaders(_ header: [String]) -> [String: String] {
        var result: [String: String] = [:]
        let lowerMap = Dictionary(uniqueKeysWithValues: header.map { ($0.lowercased().trimmingCharacters(in: .whitespaces), $0) })

        for (field, aliases) in Self.defaultAliases {
            if let explicit = columnMap[field] {
                if let h = lowerMap[explicit.lowercased()] {
                    result[field] = h
                    continue
                }
            }
            for a in aliases {
                if let h = lowerMap[a.lowercased()] {
                    result[field] = h
                    break
                }
            }
        }
        return result
    }

    private func mapType(_ raw: String) -> EventType? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch s {
        case "buy", "매수", "b": return .buy
        case "sell", "매도", "s": return .sell
        case "deposit", "입금", "transfer in", "received": return .deposit
        case "withdrawal", "withdraw", "출금", "transfer out": return .withdrawal
        case "income", "fee rebate": return .income
        case "fee": return .fee
        case "transferinternal", "transfer internal", "internal": return .transferInternal
        case "fiatdeposit", "fiat deposit": return .fiatDeposit
        case "fiatwithdraw", "fiat withdraw": return .fiatWithdraw
        case "ignored", "ignore": return .ignored
        default:
            if s.contains("buy") || s.contains("매수") { return .buy }
            if s.contains("sell") || s.contains("매도") { return .sell }
            if s.contains("deposit") || s.contains("입금") { return .deposit }
            if s.contains("withdraw") || s.contains("출금") { return .withdrawal }
            return nil
        }
    }
}
