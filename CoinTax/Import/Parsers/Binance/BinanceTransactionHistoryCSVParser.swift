import Foundation

/// 바이낸스 **Transaction History** — 계정의 모든 잔고 변동 원장.
///
/// ## 왜 필요한가
///
/// 거래내역·입금내역·출금내역 3개로는 **잔고가 닫히지 않는다.** 리퍼럴 보상으로 받은 코인,
/// 「코인 바꾸기(Convert)」로 들어온 코인은 그 어느 파일에도 안 찍힌다.
/// 실데이터에서 USDT 0.8055159 · BTC 0.00000489 가 그렇게 비어 「보유보다 많이 썼다」로
/// 계산이 막혔다. 리퍼럴로 받은 USDC 를 USDT·BTC 로 바꾼 것이 원인이었다.
///
/// ## 매매 행은 일부러 버린다
///
/// `Transaction Buy/Spend/Fee/Sold/Revenue` 는 Spot 거래내역과 **같은 거래**다
/// (실데이터에서 매수 105건·매도 5건이 시각까지 정확히 겹치고, 한쪽에만 있는 건 0건).
/// 둘 다 읽으면 거래가 두 배로 잡혀 세액이 완전히 틀어진다.
/// 체결 가격은 Spot 파일에만 있으므로, 매매는 그쪽에서 읽고 여기서는 버린다.
///
/// 역할 분담: **거래내역 = Spot Trade History · 입출금·보상·Convert = 이 파일.**
struct BinanceTransactionHistoryCSVParser: ExchangeDocumentParser {
    let parserID = "binance-transaction-history-csv-v1"

    /// Spot 거래내역과 겹치는 종류 — 여기서는 읽지 않는다
    private static let spotOperations: Set<String> = [
        "Transaction Buy", "Transaction Spend", "Transaction Fee",
        "Transaction Sold", "Transaction Revenue", "Transaction Related"
    ]

    /// 「코인 바꾸기」 두 행(내보낸 것 −, 받은 것 +)을 한 거래로 묶을 때 허용하는 시간차.
    /// 실데이터는 같은 초 ~ 31초 차이로 찍힌다.
    private static let convertPairWindow: TimeInterval = 120

    func detect(_ probe: FormatProbeResult) -> Double {
        let name = probe.fileName.lowercased()
        let text = probe.peekText
        // 헤더가 가장 확실하다. `Operation` 열은 이 파일에만 있다.
        let hasHeader = text.contains("Operation") && text.contains("Change")
            && text.contains("Coin") && text.contains("Account")
        if name.contains("transaction-history") || name.contains("transaction history") {
            return hasHeader ? 0.96 : 0.9
        }
        if hasHeader && text.contains("User ID") { return 0.9 }
        return 0
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        if url.pathExtension.lowercased() == "xlsx" || url.pathExtension.lowercased() == "xls" {
            let rows = try XLSXReader.readFirstSheetRows(url: url)
            return try parseRows(rows, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
        }
        let text = try CSVUtil.readText(url: url)
        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        try parseRows(CSVUtil.parseLines(CSVUtil.stripBOM(text)), fileName: fileName, projectID: projectID, accountID: accountID)
    }

    /// 파일에서 읽어낸 한 줄 (묶기 전)
    private struct Row {
        var timestamp: Date
        var operation: String
        var coin: AssetSymbol
        var change: Decimal
        var remark: String
        var line: Int
    }

    private func parseRows(_ rows: [[String]], fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        guard let header = rows.first else { throw CoinTaxError.parseRow("빈 파일") }
        let map = CSVUtil.headerIndex(header)
        guard let dateKey = ["UTC_Time", "Time", "Date(UTC)"].first(where: { map[$0] != nil }),
              map["Operation"] != nil, map["Coin"] != nil, map["Change"] != nil else {
            throw CoinTaxError.parserReject("바이낸스 Transaction History 헤더 불일치 (읽은 열: \(map.keys.sorted().joined(separator: ", ")))")
        }

        var warnings: [String] = []
        var ignored = 0
        for dup in CSVUtil.duplicateHeaders(header) {
            warnings.append("열 이름 중복 '\(dup)' — 첫 번째 열만 사용합니다")
        }
        let tz = CSVUtil.resolveExportTimeZone(dateKey: dateKey, fileName: fileName, warnings: &warnings)

        var parsed: [Row] = []
        var convertRows: [Row] = []
        for (i, row) in rows.dropFirst().enumerated() {
            func col(_ name: String) -> String {
                guard let idx = map[name], idx < row.count else { return "" }
                return row[idx]
            }
            let line = i + 2
            let operation = col("Operation").trimmingCharacters(in: .whitespaces)
            if Self.spotOperations.contains(operation) {
                // Spot 거래내역에서 읽는다 — 경고를 내지 않는다 (정상 동작이다)
                ignored += 1
                continue
            }
            let dateStr = col(dateKey)
            guard let ts = CSVUtil.parseDate(dateStr, timeZone: tz, formats: ["yyyy-MM-dd HH:mm:ss", "yy-MM-dd HH:mm:ss"]) else {
                warnings.append("행 \(line) 시각 파싱 실패 '\(dateStr)' — 건너뜀")
                continue
            }
            guard let change = Money.parseDecimal(col("Change")), change != 0 else {
                ignored += 1
                continue
            }
            let r = Row(timestamp: ts, operation: operation, coin: AssetSymbol(col("Coin")),
                        change: change, remark: col("Remark"), line: line)
            if operation == "Binance Convert" {
                convertRows.append(r)
            } else {
                parsed.append(r)
            }
        }

        var events: [LedgerEvent] = []
        for r in parsed {
            guard let e = event(for: r, projectID: projectID, accountID: accountID, warnings: &warnings, ignored: &ignored) else { continue }
            events.append(e)
        }
        events.append(contentsOf: convertEvents(convertRows, projectID: projectID, accountID: accountID, warnings: &warnings))

        let stamped = RowOrder.chronological(events).map { e -> LedgerEvent in
            var copy = e
            copy.fingerprint = Fingerprint.make(for: copy, parserID: parserID)
            return copy
        }
        return ParseResult(parserID: parserID, events: stamped, meta: ["timezone": tz.identifier],
                           warnings: warnings, errors: [], ignoredCount: ignored)
    }

    private func event(for r: Row, projectID: ProjectID, accountID: AccountID, warnings: inout [String], ignored: inout Int) -> LedgerEvent? {
        switch r.operation {
        case "Deposit", "Fiat Deposit":
            return LedgerEvent(
                projectID: projectID, accountID: accountID, timestamp: r.timestamp,
                type: r.coin.isKRW ? .fiatDeposit : .deposit, baseAsset: r.coin,
                quantity: Money.abs(r.change), sourceKind: parserID, rawRef: "row\(r.line)"
            )
        case "Withdraw", "Fiat Withdraw":
            // Remark 「Withdraw fee is included」 — Change 가 수수료까지 합친 **실제로 빠진 총량**이다.
            // 수수료만 따로는 알 수 없으므로 총량 하나로 처분한다 (기존 출금내역 파서와 결과가 같다).
            return LedgerEvent(
                projectID: projectID, accountID: accountID, timestamp: r.timestamp,
                type: r.coin.isKRW ? .fiatWithdraw : .withdrawal, baseAsset: r.coin,
                quantity: -Money.abs(r.change), sourceKind: parserID, rawRef: "row\(r.line)",
                quantityIsNetOfFee: true
            )
        // 공짜로 받은 것 — 취득가 0원. V-COST-01 이 처분 시 전액 이익이 됨을 알린다.
        case "Referral Commission", "Commission Rebate", "Referral Kickback",
             "Distribution", "Airdrop Assets", "Simple Earn Flexible Interest",
             "Simple Earn Locked Rewards", "Staking Rewards", "Cashback Voucher",
             "Card Cashback", "Launchpool Interest", "Token Swap - Redenomination":
            guard r.change > 0 else {
                // 보상 계열에 음수가 오면(회수·정정) 근거 없이 처분으로 만들지 않는다
                warnings.append("행 \(r.line) '\(r.operation)' 가 음수(\(Money.decimalString(r.change)) \(r.coin.code))입니다 — 제외했습니다")
                ignored += 1
                return nil
            }
            return LedgerEvent(
                projectID: projectID, accountID: accountID, timestamp: r.timestamp,
                type: .income, baseAsset: r.coin, quantity: r.change,
                memo: r.operation, sourceKind: parserID, rawRef: "row\(r.line)"
            )
        // 계정 안에서의 지갑 이동 (현물↔펀딩↔마진 등) — 총원가·수량이 그대로다
        case "Transfer Between Main Account/Futures and Margin Account",
             "Transfer Between Spot Account and UM Futures Account",
             "Transfer Between Main and Funding Wallet",
             "Funding Wallet", "Main and Funding Account Transfer":
            return LedgerEvent(
                projectID: projectID, accountID: accountID, timestamp: r.timestamp,
                type: .transferInternal, baseAsset: r.coin, quantity: r.change,
                memo: r.operation, sourceKind: parserID, rawRef: "row\(r.line)"
            )
        default:
            // 모르는 종류를 조용히 버리면 잔고가 안 닫히고, 그 결과가 「보유보다 많이 썼다」로
            // 엉뚱한 곳에서 터진다. 무엇을 못 읽었는지 반드시 알린다.
            warnings.append("행 \(r.line) 처음 보는 종류 '\(r.operation)' (\(Money.decimalString(r.change)) \(r.coin.code)) — 제외했습니다. 잔고가 어긋나면 이 줄을 확인하세요")
            ignored += 1
            return nil
        }
    }

    /// 「코인 바꾸기」 — 내보낸 코인(−)과 받은 코인(+)을 한 건의 매수로 묶는다.
    ///
    /// 한 건으로 묶어야 엔진이 견적자산 leg 을 처리해 **낸 코인을 처분하고 받은 코인에 원가를 얹는다.**
    /// 따로따로 두면 낸 코인의 취득원가가 사라지고 받은 코인이 취득가 0원이 된다.
    private func convertEvents(_ rows: [Row], projectID: ProjectID, accountID: AccountID, warnings: inout [String]) -> [LedgerEvent] {
        var events: [LedgerEvent] = []
        var pending = rows.sorted { $0.timestamp == $1.timestamp ? $0.line < $1.line : $0.timestamp < $1.timestamp }

        while let first = pending.first {
            pending.removeFirst()
            // 부호가 반대이고 시간차가 창 안인 가장 이른 줄과 짝짓는다
            guard let mateIdx = pending.firstIndex(where: {
                ($0.change > 0) != (first.change > 0)
                    && $0.coin != first.coin
                    && abs($0.timestamp.timeIntervalSince(first.timestamp)) <= Self.convertPairWindow
            }) else {
                // 짝이 없다 — 받은 것은 취득가 0원, 내보낸 것은 원가 소멸로 둔다.
                // 둘 다 세금이 커지는 쪽이고, 무엇보다 **잔고는 맞는다.**
                warnings.append("행 \(first.line) 코인 바꾸기의 상대 줄을 못 찾았습니다 (\(Money.decimalString(first.change)) \(first.coin.code)) — \(first.change > 0 ? "취득가 0원" : "취득원가 소멸")으로 처리했습니다")
                events.append(LedgerEvent(
                    projectID: projectID, accountID: accountID, timestamp: first.timestamp,
                    type: first.change > 0 ? .income : .withdrawal, baseAsset: first.coin,
                    quantity: first.change, memo: "코인 바꾸기 (상대 줄 없음)",
                    sourceKind: parserID, rawRef: "row\(first.line)"
                ))
                continue
            }
            let mate = pending.remove(at: mateIdx)
            let received = first.change > 0 ? first : mate
            let spent = first.change > 0 ? mate : first
            // 시각은 두 줄 중 이른 쪽 — 낸 코인이 그 시점에 장부에 있어야 한다
            let ts = min(received.timestamp, spent.timestamp)
            events.append(LedgerEvent(
                projectID: projectID, accountID: accountID, timestamp: ts,
                type: .buy, baseAsset: received.coin, quoteAsset: spent.coin,
                quantity: Money.abs(received.change),
                quoteAmount: Money.abs(spent.change),
                memo: "코인 바꾸기", sourceKind: parserID,
                rawRef: "row\(min(received.line, spent.line))"
            ))
        }
        return events
    }
}
