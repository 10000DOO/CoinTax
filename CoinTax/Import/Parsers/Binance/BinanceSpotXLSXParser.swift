import Foundation

struct BinanceSpotXLSXParser: ExchangeDocumentParser {
    let parserID = "binance-spot-xlsx-v1"

    func detect(_ probe: FormatProbeResult) -> Double {
        let n = probe.fileName.lowercased()
        if n.contains("spot") && n.contains("trade") { return 0.9 }
        if probe.peekText.contains("Date(UTC)") && probe.peekText.contains("Fee Coin") { return 0.95 }
        if probe.format == .xlsx && n.contains("spot") { return 0.7 }
        if probe.format == .csv && probe.peekText.contains("Base Asset") && probe.peekText.contains("Fee Coin") { return 0.9 }
        // 거래내역 화면 CSV — 헤더가 리포트센터 XLSX 와 완전히 다르다
        if probe.peekText.contains("Executed") && probe.peekText.contains("Pair") { return 0.95 }
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
        let rows = CSVUtil.parseLines(CSVUtil.stripBOM(text))
        return try parseRows(rows, fileName: fileName, projectID: projectID, accountID: accountID)
    }

    private func parseRows(_ rows: [[String]], fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        guard let header = rows.first else {
            throw CoinTaxError.parseRow("빈 파일")
        }
        let map = CSVUtil.headerIndex(header)
        var warnings: [String] = []
        for dup in CSVUtil.duplicateHeaders(header) {
            warnings.append("열 이름 중복 '\(dup)' — 첫 번째 열만 사용합니다")
        }
        // 거래내역 화면 CSV: Time,Pair,Side,Price,Executed,Amount,Fee
        if map["Executed"] != nil, map["Pair"] != nil {
            return try parseTradeScreenRows(rows, map: map, fileName: fileName, warnings: warnings, projectID: projectID, accountID: accountID)
        }
        guard map["Date(UTC)"] != nil, map["Base Asset"] != nil else {
            throw CoinTaxError.parserReject("바이낸스 Spot 헤더 불일치 (읽은 열: \(map.keys.sorted().joined(separator: ", ")))")
        }
        return try parseReportRows(rows, map: map, fileName: fileName, warnings: warnings, projectID: projectID, accountID: accountID)
    }

    // MARK: - 리포트센터 XLSX/CSV (Date(UTC), Base Asset, Quote Asset, Total, Fee Coin)

    private func parseReportRows(
        _ rows: [[String]],
        map: [String: Int],
        fileName: String,
        warnings initialWarnings: [String],
        projectID: ProjectID,
        accountID: AccountID
    ) throws -> ParseResult {
        var events: [LedgerEvent] = []
        var warnings = initialWarnings
        let tz = CSVUtil.timeZoneFromFileName(fileName) ?? TimeZone(secondsFromGMT: 0)!
        for (i, row) in rows.dropFirst().enumerated() {
            func col(_ name: String) -> String {
                guard let idx = map[name], idx < row.count else { return "" }
                return row[idx]
            }
            let dateStr = col("Date(UTC)")
            guard !dateStr.isEmpty else { continue }
            guard let ts = CSVUtil.parseDate(dateStr, timeZone: tz, formats: ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"]) else {
                warnings.append("행 \(i+2) 날짜 파싱 실패")
                continue
            }
            let typeStr = col("Type").trimmingCharacters(in: .whitespaces).uppercased()
            // BUY 아니면 무조건 SELL로 두면 빈 값·오타 행이 유령 매도가 된다 (리뷰 6-4)
            let type: EventType
            switch typeStr {
            case "BUY": type = .buy
            case "SELL": type = .sell
            default:
                warnings.append("행 \(i+2) 알 수 없는 Type '\(col("Type"))' — 건너뜀")
                continue
            }
            guard let amount = Money.parseDecimal(col("Amount")), amount != 0 else {
                warnings.append("행 \(i+2) Amount 파싱 실패 — 건너뜀")
                continue
            }
            let qty = type == .buy ? Money.abs(amount) : -Money.abs(amount)
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
                feeAsset: col("Fee Coin").trimmingCharacters(in: .whitespaces).isEmpty ? nil : AssetSymbol(col("Fee Coin")),
                sourceKind: parserID,
                rawRef: "row\(i+2)"
                // 바이낸스 Amount 는 수수료 차감 **전** 수량 → quantityIsNetOfFee 기본값(false) 유지
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }
        return ParseResult(parserID: parserID, events: events, meta: ["timezone": tz.identifier], warnings: warnings, errors: [], ignoredCount: 0)
    }

    // MARK: - 거래내역 화면 CSV (Time, Pair, Side, Price, Executed, Amount, Fee)

    private func parseTradeScreenRows(
        _ rows: [[String]],
        map: [String: Int],
        fileName: String,
        warnings initialWarnings: [String],
        projectID: ProjectID,
        accountID: AccountID
    ) throws -> ParseResult {
        var events: [LedgerEvent] = []
        var warnings = initialWarnings
        // 이 export 는 파일명에만 타임존을 남긴다. 없으면 UTC 가정 + 경고 (하루 밀리면 과세연도가 바뀐다)
        let tz: TimeZone
        if let fromName = CSVUtil.timeZoneFromFileName(fileName) {
            tz = fromName
        } else {
            tz = TimeZone(secondsFromGMT: 0)!
            warnings.append("파일명에 타임존 표기가 없어 UTC 로 해석했습니다 — 시각이 밀리면 환율 적용일·과세연도가 달라집니다")
        }

        for (i, row) in rows.dropFirst().enumerated() {
            func col(_ name: String) -> String {
                guard let idx = map[name], idx < row.count else { return "" }
                return row[idx]
            }
            let timeStr = col("Time")
            guard !timeStr.isEmpty else { continue }
            guard let ts = CSVUtil.parseDate(timeStr, timeZone: tz, formats: ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"]) else {
                warnings.append("행 \(i+2) 날짜 파싱 실패 '\(timeStr)' — 건너뜀")
                continue
            }
            let sideStr = col("Side").trimmingCharacters(in: .whitespaces).uppercased()
            let type: EventType
            switch sideStr {
            case "BUY": type = .buy
            case "SELL": type = .sell
            default:
                warnings.append("행 \(i+2) 알 수 없는 Side '\(col("Side"))' — 건너뜀")
                continue
            }
            // Executed = base 수량 + 단위, Amount = quote 대금 + 단위
            guard let executed = CSVUtil.splitAmountUnit(col("Executed")), executed.amount != 0 else {
                warnings.append("행 \(i+2) Executed 파싱 실패 '\(col("Executed"))' — 건너뜀")
                continue
            }
            guard let total = CSVUtil.splitAmountUnit(col("Amount")), total.amount != 0 else {
                warnings.append("행 \(i+2) Amount 파싱 실패 '\(col("Amount"))' — 건너뜀")
                continue
            }
            // `Pair`(XAUTUSDT)는 구분자가 없어 쪼개는 위치가 모호하다 → 단위 접미사를 심볼의 근거로 쓴다
            let pair = col("Pair").trimmingCharacters(in: .whitespaces)
            guard let baseCode = executed.unit, let quoteCode = total.unit else {
                warnings.append("행 \(i+2) 수량에 자산 단위가 없어 마켓(\(pair))을 확정할 수 없습니다 — 건너뜀")
                continue
            }
            let fee = CSVUtil.splitAmountUnit(col("Fee"))
            let qty = type == .buy ? Money.abs(executed.amount) : -Money.abs(executed.amount)

            var e = LedgerEvent(
                projectID: projectID,
                accountID: accountID,
                timestamp: ts,
                type: type,
                baseAsset: AssetSymbol(baseCode),
                quoteAsset: AssetSymbol(quoteCode),
                quantity: qty,
                price: Money.parseDecimal(col("Price")),
                quoteAmount: Money.abs(total.amount),
                feeAmount: fee.map { Money.abs($0.amount) },
                feeAsset: fee?.unit.map { AssetSymbol($0) },
                memo: pair.isEmpty ? nil : pair,
                sourceKind: parserID,
                rawRef: "row\(i+2)"
                // Executed 는 수수료 차감 전 체결 수량 → quantityIsNetOfFee = false
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }
        if events.isEmpty {
            throw CoinTaxError.parseRow("바이낸스 거래내역에서 체결 행을 읽지 못했습니다")
        }
        return ParseResult(
            parserID: parserID,
            events: events,
            meta: ["timezone": tz.identifier, "variant": "trade-screen-csv"],
            warnings: warnings,
            errors: [],
            ignoredCount: 0
        )
    }
}
