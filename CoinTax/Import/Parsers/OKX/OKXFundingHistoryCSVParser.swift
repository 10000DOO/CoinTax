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
        let text = try CSVUtil.readText(url: url)
        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let lines = CSVUtil.parseLines(CSVUtil.stripBOM(text))
        guard lines.count >= 2 else { throw CoinTaxError.parseRow("OKX Funding 파일 너무 짧음") }
        let metaLine = lines[0].joined(separator: ",")
        let tz = CSVUtil.parseTimezoneOffset(metaLine)
        let header = lines[1]
        let map = CSVUtil.headerIndex(header)
        guard map["Type"] != nil, map["Amount"] != nil, map["Symbol"] != nil else {
            throw CoinTaxError.parserReject("OKX Funding 헤더 불일치")
        }

        func col(_ row: [String], _ name: String) -> String {
            guard let idx = map[name], idx < row.count else { return "" }
            return row[idx]
        }

        var events: [LedgerEvent] = []
        var warnings: [String] = []
        var ignored = 0
        for dup in CSVUtil.duplicateHeaders(header) {
            warnings.append("열 이름 중복 '\(dup)' — 첫 번째 열만 사용합니다")
        }
        for (i, row) in lines.dropFirst(2).enumerated() {
            let typeStr = col(row, "Type")
            let amount = Money.parseDecimal(col(row, "Amount")) ?? 0
            let symbol = col(row, "Symbol")
            let timeStr = col(row, "Time")
            guard let ts = CSVUtil.parseDate(timeStr, timeZone: tz, formats: ["yyyy-MM-dd HH:mm:ss"]) else {
                warnings.append("행 \(i+3) 시각 파싱 실패 '\(timeStr)' — 건너뜀")
                continue
            }
            let mapped: (EventType, Decimal)?
            switch typeStr {
            case "Deposit":
                mapped = (.deposit, Money.abs(amount))
            // `Received` 는 블록체인 입금이 아니라 OKX 안에서 받은 것이다 (가입·첫 입금 보상 등).
            // 다른 거래소 출금의 상대가 될 수 없으므로 입금으로 두면 전송 연결 화면에
            // 영영 짝이 안 맞는 후보로 남는다. 취득가 0원 처리는 income 쪽과 같고,
            // 「취득가 0원」 안내는 V-COST-01 이 따로 내보낸다.
            case "Received":
                mapped = (.income, Money.abs(amount))
            case "Withdrawal":
                mapped = (.withdrawal, -Money.abs(amount))
            case "From unified trading account":
                mapped = (.transferInternal, Money.abs(amount))
            case "To unified trading account":
                mapped = (.transferInternal, -Money.abs(amount))
            // 계정 마이그레이션 기록. in/out 이 같은 시각·같은 수량으로 짝을 이루므로 내부 이동이다.
            // 「미지원 Type」으로 버리면 경고만 쌓이고 검증 상태가 근거 없이 내려간다.
            case "Data migration in":
                mapped = (.transferInternal, Money.abs(amount))
            case "Data migration out":
                mapped = (.transferInternal, -Money.abs(amount))
            case "Fee rebate":
                mapped = (.income, Money.abs(amount))
            default:
                mapped = nil
            }
            guard let (etype, qty) = mapped else {
                ignored += 1
                warnings.append("행 \(i+3) 미지원 Type '\(typeStr)' — 제외")
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
                rawRef: "row\(i+3)",
                // OKX 가 찍어준 `After Balance` — 우리 계산의 정답지 (V-BAL)
                balanceAfter: Money.parseDecimal(col(row, "After Balance"))
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            events.append(e)
        }
        return ParseResult(
            parserID: parserID,
            events: RowOrder.chronological(events),
            meta: ["timezone": metaLine],
            warnings: warnings,
            errors: [],
            ignoredCount: ignored
        )
    }
}
