import Foundation
import CryptoKit

/// Trezor Suite 계정 내역 CSV (개인지갑).
///
/// 헤더: `Timestamp,Date,Time,Type,Transaction ID,Fee,Fee unit,Address,Label,Amount,Amount unit,Fiat (USD),Other`
///
/// 거래소 파일과 다른 점이 셋 있고, 셋 다 틀리면 수량·원가가 통째로 어긋난다.
///
/// 1. **`Type` 만으로 방향을 판정할 수 없다.** 한 트랜잭션이 토큰을 내보내면서 다른 토큰을
///    받으면 두 행 모두 `SENT` 로 찍힌다(지갑이 그 트랜잭션을 보냈으므로). 방향은
///    **`Address` 열**로 가른다 — 받는 행에는 **내 지갑 주소**가, 보내는 행에는 상대 주소가 적힌다.
/// 2. **한 트랜잭션이 여러 행이다.** `Transaction ID` 가 같은 행들을 묶어야 「무엇을 주고 무엇을
///    받았는지」가 보인다.
/// 3. **금액 0 + 수수료만 있는 행**이 있다. 토큰 사용 승인(approve) 같은 것으로, 코인은 안 움직이고
///    가스비만 나간다.
///
/// **세무 처리는 이 파서가 정하지 않는다.** 디파이 예치·인출을 양도로 볼지(백서 U-05),
/// 예치로 늘어난 몫을 어떤 소득으로 볼지(U-06)는 확정 기준이 없고 2026-10 국세청 고시 대기다.
/// 파서는 **사실만 정확히 읽고**, 판단이 필요한 자리를 경고로 드러낸다.
struct TrezorSuiteCSVParser: ExchangeDocumentParser {
    let parserID = "trezor-suite-csv-v1"

    /// 이 소스에서 나온 이벤트임을 표시한다 (분류 결과가 `sourceKind` 로 남는다)
    enum Kind {
        static let plain = "trezor"
        /// 코인은 안 움직이고 가스비만 나간 트랜잭션 (approve 등)
        static let gasOnly = "trezor-gas-only"
        /// 디파이 예치로 보이는 짝 (원자산이 나가고 시세 없는 영수증 토큰이 들어옴)
        static let defiIn = "trezor-defi-deposit"
        /// 디파이 인출로 보이는 짝 (영수증 토큰이 나가고 원자산이 들어옴)
        static let defiOut = "trezor-defi-withdraw"
        /// 시세를 알 수 없는 토큰 (영수증·LP 토큰 등)
        static let unpriced = "trezor-unpriced-token"
    }

    private static let requiredHeaders = ["Transaction ID", "Amount unit", "Fee unit", "Address"]

    func detect(_ probe: FormatProbeResult) -> Double {
        guard probe.format == .csv else { return 0 }
        let head = probe.peekText.prefix(600)
        guard Self.requiredHeaders.allSatisfy({ head.contains($0) }) else { return 0 }
        // `Fiat (USD)` 는 통화 설정에 따라 (KRW) 등으로 바뀔 수 있어 접두만 본다
        return head.contains("Fiat (") ? 0.96 : 0.9
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let text = try CSVUtil.readText(url: url)
        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let lines = CSVUtil.parseLines(CSVUtil.stripBOM(text))
        guard let header = lines.first, lines.count >= 2 else {
            throw CoinTaxError.parseRow("Trezor 파일이 비어 있습니다")
        }
        let map = CSVUtil.headerIndex(header)
        guard Self.requiredHeaders.allSatisfy({ map[$0] != nil }) else {
            throw CoinTaxError.parserReject("Trezor 헤더 불일치")
        }

        func col(_ row: [String], _ name: String) -> String {
            guard let idx = map[name], idx < row.count else { return "" }
            return row[idx].trimmingCharacters(in: .whitespaces)
        }

        var warnings: [String] = []
        var ignored = 0

        // ── 1) 행을 먼저 다 읽는다 (방향 판정에 전체가 필요하다) ────────────
        struct Row {
            var ts: Date
            var type: String
            var txid: String
            var address: String
            var asset: AssetSymbol
            var amount: Decimal
            var fee: Decimal
            var feeAsset: AssetSymbol?
            var hasFiat: Bool
            var lineNo: Int
        }
        var rows: [Row] = []
        for (i, raw) in lines.dropFirst().enumerated() {
            let lineNo = i + 2
            guard raw.count > 1 else { ignored += 1; continue }
            let unit = col(raw, "Amount unit")
            guard !unit.isEmpty else { ignored += 1; continue }
            guard let ts = Self.timestamp(epoch: col(raw, "Timestamp"), date: col(raw, "Date"), time: col(raw, "Time")) else {
                warnings.append("행 \(lineNo): 시각을 읽지 못해 건너뜁니다")
                ignored += 1
                continue
            }
            let feeUnit = col(raw, "Fee unit")
            rows.append(Row(
                ts: ts,
                type: col(raw, "Type").uppercased(),
                txid: col(raw, "Transaction ID"),
                address: col(raw, "Address"),
                asset: AssetSymbol(unit),
                amount: Money.abs(Money.parseDecimal(col(raw, "Amount")) ?? 0),
                fee: Money.abs(Money.parseDecimal(col(raw, "Fee")) ?? 0),
                feeAsset: feeUnit.isEmpty ? nil : AssetSymbol(feeUnit),
                hasFiat: !Self.fiatColumnValue(raw, map).isEmpty,
                lineNo: lineNo
            ))
        }
        guard !rows.isEmpty else { throw CoinTaxError.parseRow("Trezor 파일에서 읽을 행이 없습니다") }

        // ── 2) 내 지갑 주소 — 「받은」 행에 찍힌 주소는 **전부** 내 것이다 ──
        //
        // 예전에는 받은 행의 주소를 세어 **가장 많이 나온 하나만** 내 주소로 봤다.
        // 그러면 **비트코인에서 무너진다** — 하드웨어 지갑은 받을 때마다 새 주소를 만들기
        // 때문에(HD 지갑의 기본 동작) 받은 내역 대부분이 서로 다른 주소로 찍힌다.
        // 실사용 파일에서 받은 내역 13건이 8개 주소로 흩어져 있었고, 그중 **9건이 「보낸 것」으로
        // 뒤집혀** 보유가 음수가 됐다 (7차 감사 D-2).
        //
        // 받은 행(`RECV`)의 주소는 정의상 내 것이므로 **집합으로** 모은다.
        var ownAddresses: Set<String> = []
        for r in rows where r.type == "RECV" && !r.address.isEmpty {
            ownAddresses.insert(r.address)
        }
        // 받은 내역이 한 건도 없으면 방향의 근거가 없다 — 조용히 틀리느니 막는다.
        guard !ownAddresses.isEmpty else {
            throw CoinTaxError.parserReject(
                "Trezor 파일에서 내 지갑 주소를 찾지 못했습니다 (받은 내역이 한 건도 없음) — 방향을 판정할 수 없어 가져오지 않습니다"
            )
        }
        /// 들어온 것인가.
        ///
        /// `RECV` 는 그 자체로 받은 것이다. `SENT` 인데 내 주소로 찍힌 행은 **디파이 예치**처럼
        /// 「내 지갑이 보낸 트랜잭션인데 그 안에서 내가 받은」 몫이다 — 이때만 주소로 가린다.
        func isInbound(type: String, address: String) -> Bool {
            type == "RECV" || ownAddresses.contains(address)
        }

        // ── 3) 트랜잭션 단위로 묶어 분류한다 ──────────────────────────────
        var byTx: [String: [Row]] = [:]
        var txOrder: [String] = []
        for r in rows {
            if byTx[r.txid] == nil { txOrder.append(r.txid) }
            byTx[r.txid, default: []].append(r)
        }

        let network = Self.network(fileName: fileName, firstAsset: rows[0].asset.code)
        var events: [LedgerEvent] = []
        var defiPairs = 0
        var gasOnly = 0
        var unpricedAssets: Set<String> = []

        for txid in txOrder {
            let group = byTx[txid]!.sorted { $0.lineNo < $1.lineNo }
            let moves = group.filter { $0.amount > 0 }
            // 그 트랜잭션에 붙은 가스비 (행마다 중복 표기되지 않는다 — 합산하지 않고 최댓값을 쓴다)
            let gas = group.compactMap { $0.fee > 0 ? ($0.fee, $0.feeAsset) : nil }.max { $0.0 < $1.0 }

            // (a) 코인이 안 움직인 트랜잭션 — 토큰 사용 승인 등. 가스비만 나갔다.
            if moves.isEmpty {
                guard let g = gas, let ga = g.1 else { ignored += group.count; continue }
                gasOnly += 1
                events.append(Self.event(
                    projectID: projectID, accountID: accountID, ts: group[0].ts,
                    type: .withdrawal, asset: ga, quantity: -g.0,
                    fee: nil, feeAsset: nil, network: network, txid: txid,
                    sourceKind: Kind.gasOnly, rawRef: "\(Self.shortHash(txid))#gas",
                    // 가스비는 되돌아오지 않는다. 「연결하세요」를 재촉하지 않도록 소멸로 표시한다.
                    lostForever: true
                ))
                continue
            }

            // (b) 방향 판정
            let inbound = moves.filter { isInbound(type: $0.type, address: $0.address) }
            let outbound = moves.filter { !isInbound(type: $0.type, address: $0.address) }

            // (c) 디파이 예치·인출로 보이는 짝인지 (원자산 ↔ 시세 없는 영수증 토큰)
            let inUnpriced = inbound.contains { !$0.hasFiat }
            let outUnpriced = outbound.contains { !$0.hasFiat }
            var kind = Kind.plain
            if !inbound.isEmpty && !outbound.isEmpty {
                if inUnpriced && !outUnpriced { kind = Kind.defiIn; defiPairs += 1 }
                else if outUnpriced && !inUnpriced { kind = Kind.defiOut; defiPairs += 1 }
            }

            var gasAttached = false
            for m in moves {
                if !m.hasFiat { unpricedAssets.insert(m.asset.code) }
                let isIn = isInbound(type: m.type, address: m.address)
                // 가스비는 그 트랜잭션에서 **한 번만** 붙인다 (여러 행에 나눠 붙이면 이중 계상).
                //
                // 그리고 **보내는 자산과 가스 자산이 같을 때만** 붙인다. USDT 를 보내며 ETH 가스를
                // 내면 자산이 다른데, 수량 규칙 한 벌(`LedgerDelta.withdrawalFeeQuantity`)은
                // 「수수료 자산이 보내는 자산과 다르면 장부를 건드리지 않는다」이므로 **가스가
                // 통째로 사라진다** (7차 감사 D-3 — 실사용 이더리움 파일에서 6건).
                // 자산이 다르면 아래에서 **별도 출금 이벤트**로 뺀다.
                let attachGas = !gasAttached && gas?.1 == m.asset && !isIn
                if attachGas { gasAttached = true }
                events.append(Self.event(
                    projectID: projectID, accountID: accountID, ts: m.ts,
                    type: isIn ? .deposit : .withdrawal,
                    asset: m.asset,
                    quantity: isIn ? m.amount : -m.amount,
                    fee: attachGas ? gas?.0 : nil,
                    feeAsset: attachGas ? gas?.1 : nil,
                    network: network, txid: txid,
                    sourceKind: !m.hasFiat ? Kind.unpriced : kind,
                    rawRef: "\(Self.shortHash(txid))#\(m.lineNo)",
                    lostForever: false
                ))
            }
            // 가스를 어디에도 못 붙였으면 따로 뺀다 — 나가는 행이 없거나(받기만 한 트랜잭션),
            // 가스 자산이 보낸 자산과 다른 경우다. 빼지 않으면 장부 수량이 체인과 어긋난다.
            if !gasAttached, let g = gas, let ga = g.1 {
                events.append(Self.event(
                    projectID: projectID, accountID: accountID, ts: group[0].ts,
                    type: .withdrawal, asset: ga, quantity: -g.0,
                    fee: nil, feeAsset: nil, network: network, txid: txid,
                    sourceKind: Kind.gasOnly, rawRef: "\(Self.shortHash(txid))#gas", lostForever: true
                ))
            }
        }

        // ── 4) 판단이 필요한 자리를 사실대로 드러낸다 ─────────────────────
        if gasOnly > 0 {
            warnings.append("코인은 움직이지 않고 가스비만 나간 트랜잭션 \(gasOnly)건 (토큰 사용 승인 등) — 가스비만큼 수량을 뺐고, 그 취득원가는 소멸 처리됩니다 (세액이 커지는 방향 · 백서 U-11)")
        }
        if !unpricedAssets.isEmpty {
            warnings.append("시세를 알 수 없는 토큰 \(unpricedAssets.sorted().joined(separator: ", ")) — 예치 영수증·LP 토큰으로 보입니다. 취득가 0원으로 들어오고 원화 환산이 되지 않습니다")
        }
        if defiPairs > 0 {
            warnings.append("디파이 예치·인출로 보이는 트랜잭션 \(defiPairs)건 — **예치를 양도로 볼지 확정된 기준이 없습니다**(백서 U-05). 지금은 단순 입출금으로 읽었고, 연결하지 않은 출금은 취득원가가 소멸합니다. 예치한 자산이 그대로 돌아온 것이라면 「전송 연결」 화면에서 짝지어 주세요")
        }

        return ParseResult(
            parserID: parserID,
            events: events,
            // 비트코인은 받을 때마다 주소가 새로 생겨 내 주소가 여러 개다.
            // 감사 추적에는 **몇 개를 내 것으로 봤는지**와 대표 하나면 충분하다 (원문은 저장하지 않는다).
            meta: [
                "network": network,
                "ownAddressCount": "\(ownAddresses.count)",
                "ownAddress": Self.shortHash(ownAddresses.sorted().first ?? "")
            ],
            warnings: warnings,
            errors: [],
            ignoredCount: ignored
        )
    }

    // MARK: - 보조

    private static func fiatColumnValue(_ row: [String], _ map: [String: Int]) -> String {
        for (name, idx) in map where name.hasPrefix("Fiat (") {
            if idx < row.count { return row[idx].trimmingCharacters(in: .whitespaces) }
        }
        return ""
    }

    /// `Timestamp` 는 유닉스 초다. 없으면 `Date`+`Time` 으로 떨어진다.
    ///
    /// 로캘 표기(`2026. 8. 12.`)는 기기 설정에 따라 달라서 유닉스 초를 **먼저** 본다 —
    /// 여기서 하루가 밀리면 과세연도 귀속(2027-01-01 경계)이 틀어진다.
    static func timestamp(epoch: String, date: String, time: String) -> Date? {
        if let secs = Double(epoch.trimmingCharacters(in: .whitespaces)), secs > 0 {
            return Date(timeIntervalSince1970: secs)
        }
        let joined = "\(date) \(time)".trimmingCharacters(in: .whitespaces)
        return CSVUtil.parseDate(joined, timeZone: TaxTime.seoul, formats: [
            "yyyy. M. d. HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"
        ])
    }

    private static func network(fileName: String, firstAsset: String) -> String {
        let n = fileName.lowercased()
        if n.contains("bitcoin") { return "BTC" }
        if n.contains("ethereum") { return "ETH" }
        return firstAsset
    }

    private static func event(
        projectID: ProjectID, accountID: AccountID, ts: Date,
        type: EventType, asset: AssetSymbol, quantity: Decimal,
        fee: Decimal?, feeAsset: AssetSymbol?,
        network: String, txid: String, sourceKind: String, rawRef: String,
        lostForever: Bool
    ) -> LedgerEvent {
        var e = LedgerEvent(
            projectID: projectID,
            accountID: accountID,
            timestamp: ts,
            type: type,
            baseAsset: asset,
            quantity: quantity,
            feeAmount: fee,
            feeAsset: feeAsset,
            network: network,
            txidHash: Self.shortHash(txid),
            sourceKind: sourceKind,
            rawRef: rawRef
        )
        e.lostForever = lostForever
        return e
    }

    /// 온체인 식별자(트랜잭션 ID·주소)는 **원본 그대로 저장하지 않는다.**
    /// 감사 추적에는 같은 값이 같은 문자열로 나오기만 하면 충분하다.
    static func shortHash(_ s: String) -> String {
        let d = SHA256.hash(data: Data(s.utf8))
        return d.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
