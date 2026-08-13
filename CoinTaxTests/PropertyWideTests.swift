import XCTest
@testable import CoinTax

/// 넓힌 무작위 시나리오 테스트 (`PropertyTests` 의 확장판).
///
/// 기존 `PropertyTests` 의 생성기는 계정 2개(빗썸·바이낸스)·자산 3종·개인지갑 없음·사실상 단년도였다.
/// 사람이 안 써 본 조합을 기계가 찾게 하려면 생성기가 넓어야 한다 — 좁은 생성기는
/// 「Critical 0건」을 공짜로 통과시킨다.
///
/// 여기서는 계정 4개(빗썸·바이낸스·OKX·**개인지갑**) · **2026~2029 다년도** ·
/// 개인지갑 왕복 · 손실만 난 해 · 같은 초 매수+매도 · 소수 18자리 수량 · 제3자산 수수료를 넣는다.
/// 넓혔다는 사실 자체도 검사한다 (`testGeneratorActuallyCoversTheNewCases`).
final class PropertyWideTests: XCTestCase {

    // MARK: - 재현 가능한 난수

    struct RNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
        mutating func bool(_ pct: Int = 50) -> Bool { int(1...100) <= pct }
        /// 소수 8자리 (거래소 관례)
        mutating func qty8(_ lo: Int, _ hi: Int) -> Decimal {
            Decimal(int(lo...hi)) + Decimal(int(0...99_999_999)) / 100_000_000
        }
        /// 소수 18자리 (ETH wei 단위) — 극단 자릿수
        mutating func qty18() -> Decimal {
            var frac = Decimal(int(1...999_999_999))
            frac += Decimal(int(0...999_999_999)) / 1_000_000_000
            return frac / 1_000_000_000
        }
    }

    struct Scenario {
        var accounts: [Account]
        var events: [LedgerEvent]
        var links: [TransferLink]
        var fx: [String: Decimal]
        var market: [String: Decimal]
        /// 생성기가 의도한 (계정|자산) 수량
        var intended: [String: Decimal]
    }

    // MARK: - 생성기

    // swiftlint:disable:next function_body_length
    private func makeScenario(seed: UInt64, steps: Int = 90) -> Scenario {
        var rng = RNG(seed: seed)
        let pid = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: pid)
        let binance = Account.defaults(for: .binance, projectID: pid)
        let okx = Account.defaults(for: .okx, projectID: pid)
        let wallet = Account.defaults(for: .wallet, projectID: pid)
        let accounts = [bithumb, binance, okx, wallet]
        /// 명세서 = (계정, 원본 종류). 개인지갑은 거래소 명세서가 없다 → 잔고를 찍지 않는다.
        func stream(_ a: Account) -> String { "gen-\(a.exchangeCode.rawValue)" }

        var events: [LedgerEvent] = []
        var links: [TransferLink] = []
        var held: [String: Decimal] = [:]
        var printed: [String: Decimal] = [:]
        var fx: [String: Decimal] = [:]
        var seq = 0
        var day = 0
        var lastTime = Date.distantPast

        func key(_ a: Account, _ s: String) -> String { "\(a.id.raw.uuidString)|\(s)" }
        /// 2026-02-01 부터 최대 3년 반 — 과세 시작(2027-01-01)을 사이에 두고 여러 해에 걸친다
        func nextTime(same: Bool) -> Date {
            if !same { day += rng.int(1...32) }
            return TaxTime.dateKST(year: 2026, month: 2, day: 1)
                .addingTimeInterval(TimeInterval(day) * 86_400 + TimeInterval(rng.int(0...80_000)))
        }
        func push(_ e: LedgerEvent, _ acc: Account, _ changes: [(String, Decimal)], printBalance: Bool = true) {
            var c = e
            if c.timestamp < lastTime { c.timestamp = lastTime }
            lastTime = c.timestamp
            for (asset, delta) in changes {
                held[key(acc, asset), default: 0] += delta
                printed[key(acc, asset), default: 0] += delta
            }
            if printBalance {
                c.balanceAfter = printed[key(acc, c.baseAsset.code)]
                if let q = c.quoteAsset, !q.isKRW { c.quoteBalanceAfter = printed[key(acc, q.code)] }
            }
            seq += 1
            c.rawRef = String(format: "s%05d", seq)
            c.fingerprint = "fp-\(seed)-\(seq)"
            fx[TaxTime.dayKST(c.timestamp)] = Decimal(rng.int(1_200...1_500))
            events.append(c)
        }

        // 씨앗 — 빗썸에서 원화로 USDT 를 산다
        do {
            let t = nextTime(same: false)
            let q = rng.qty8(3_000, 8_000)
            let e = LedgerEvent(projectID: pid, accountID: bithumb.id, timestamp: t, type: .buy,
                                baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
                                quantity: q, quoteAmountKRW: q * 1_400, sourceKind: stream(bithumb))
            push(e, bithumb, [("USDT", q)])
        }

        for step in 0..<steps {
            let same = rng.bool(18)
            let t = nextTime(same: same)
            let overseas = rng.bool() ? binance : okx

            switch rng.int(1...10) {
            case 1: // 빗썸 원화 매수
                let asset = ["USDT", "BTC", "ETH"][rng.int(0...2)]
                let q = asset == "USDT" ? rng.qty8(100, 900) : rng.qty8(0, 2)
                guard q > 0 else { continue }
                let e = LedgerEvent(projectID: pid, accountID: bithumb.id, timestamp: t, type: .buy,
                                    baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("KRW"),
                                    quantity: q, quoteAmountKRW: q * Decimal(rng.int(1_000...90_000_000)),
                                    feeAmount: Decimal(rng.int(0...400)), feeAsset: AssetSymbol("KRW"),
                                    sourceKind: stream(bithumb))
                push(e, bithumb, [(asset, q)])

            case 2: // 빗썸 원화 매도 — 해에 따라 손실만 나는 구간을 만든다
                let asset = ["USDT", "BTC", "ETH"][rng.int(0...2)]
                let have = held[key(bithumb, asset)] ?? 0
                guard have > 1 else { continue }
                let q = have / Decimal(rng.int(2...4))
                // 짝수 해는 헐값에 판다 → 그 해는 손실만 (다년도 통산 금지 확인용)
                let lossYear = TaxTime.calendarYearKST(t) % 2 == 0
                let unit = lossYear ? Decimal(rng.int(1...500)) : Decimal(rng.int(1_000...90_000_000))
                let e = LedgerEvent(projectID: pid, accountID: bithumb.id, timestamp: t, type: .sell,
                                    baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("KRW"),
                                    quantity: -q, quoteAmountKRW: q * unit,
                                    feeAmount: Decimal(rng.int(0...400)), feeAsset: AssetSymbol("KRW"),
                                    sourceKind: stream(bithumb))
                push(e, bithumb, [(asset, -q)])

            case 3: // 빗썸 → 해외 전송
                let have = held[key(bithumb, "USDT")] ?? 0
                guard have > 20 else { continue }
                let sent = have / Decimal(rng.int(2...5))
                let received = sent - sent / Decimal(rng.int(20...400))
                let out = LedgerEvent(projectID: pid, accountID: bithumb.id, timestamp: t, type: .withdrawal,
                                      baseAsset: AssetSymbol("USDT"), quantity: -sent, sourceKind: stream(bithumb))
                push(out, bithumb, [("USDT", -sent)])
                let into = LedgerEvent(projectID: pid, accountID: overseas.id,
                                       timestamp: t.addingTimeInterval(TimeInterval(rng.int(60...30_000))),
                                       type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: received,
                                       sourceKind: stream(overseas))
                push(into, overseas, [("USDT", received)])
                links.append(TransferLink(id: LinkID(), projectID: pid, fromEventID: out.id, toEventID: into.id,
                                          status: .confirmed, withdrawnQty: sent, receivedQty: received,
                                          score: 1, note: nil))

            case 4: // 해외 코인↔코인 매수 (수수료: 견적자산 / 기초자산 / 제3자산)
                let usdt = held[key(overseas, "USDT")] ?? 0
                guard usdt > 50 else { continue }
                let spend = usdt / Decimal(rng.int(2...6))
                let asset = ["BTC", "ETH", "XAUT"][rng.int(0...2)]
                let q = spend / Decimal(rng.int(1_000...60_000))
                guard q > 0 else { continue }
                let bnb = held[key(overseas, "BNB")] ?? 0
                let feeKind = bnb > 1 ? rng.int(1...3) : rng.int(1...2)   // 1=견적 2=기초 3=제3자산
                let fee: Decimal = feeKind == 1 ? spend / 1_000 : (feeKind == 2 ? q / 1_000 : Decimal(string: "0.01")!)
                let feeAsset = feeKind == 1 ? "USDT" : (feeKind == 2 ? asset : "BNB")
                let e = LedgerEvent(projectID: pid, accountID: overseas.id, timestamp: t, type: .buy,
                                    baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("USDT"),
                                    quantity: q, quoteAmount: spend,
                                    feeAmount: fee, feeAsset: AssetSymbol(feeAsset),
                                    sourceKind: stream(overseas))
                let changes: [(String, Decimal)]
                switch feeKind {
                case 1: changes = [(asset, q), ("USDT", -spend - fee)]
                case 2: changes = [(asset, q - fee), ("USDT", -spend)]
                default: changes = [(asset, q), ("USDT", -spend), ("BNB", -fee)]
                }
                push(e, overseas, changes)

            case 5: // 해외 코인↔코인 매도
                let asset = ["BTC", "ETH", "XAUT"][rng.int(0...2)]
                let have = held[key(overseas, asset)] ?? 0
                guard have > 0 else { continue }
                let q = have / Decimal(rng.int(2...4))
                guard q > 0 else { continue }
                let proceeds = q * Decimal(rng.int(1_000...60_000))
                let feeInQuote = rng.bool(70)
                let fee = feeInQuote ? proceeds / 1_000 : q / 1_000
                let e = LedgerEvent(projectID: pid, accountID: overseas.id, timestamp: t, type: .sell,
                                    baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("USDT"),
                                    quantity: -q, quoteAmount: proceeds,
                                    feeAmount: fee, feeAsset: AssetSymbol(feeInQuote ? "USDT" : asset),
                                    sourceKind: stream(overseas))
                let changes: [(String, Decimal)] = feeInQuote
                    ? [(asset, -q), ("USDT", proceeds - fee)]
                    : [(asset, -q - fee), ("USDT", proceeds)]
                push(e, overseas, changes)

            case 6: // 보상 (BNB 를 포함 — 제3자산 수수료 재원)
                let asset = ["USDT", "BTC", "ETH", "BNB"][rng.int(0...3)]
                let q = asset == "BNB" ? rng.qty8(1, 5) : rng.qty8(0, 1) / 100
                guard q > 0 else { continue }
                let acc = [bithumb, binance, okx][rng.int(0...2)]
                let e = LedgerEvent(projectID: pid, accountID: acc.id, timestamp: t, type: .income,
                                    baseAsset: AssetSymbol(asset), quantity: q, sourceKind: stream(acc))
                push(e, acc, [(asset, q)])

            case 7: // 거래소 → 개인지갑 (MatchingService.moveToWallet 이 만드는 모양 그대로)
                let asset = ["BTC", "ETH"][rng.int(0...1)]
                let have = held[key(overseas, asset)] ?? 0
                guard have > 0 else { continue }
                let sent = have / Decimal(rng.int(2...4))
                guard sent > 0 else { continue }
                let arrived = sent - sent / Decimal(rng.int(100...1_000))
                let out = LedgerEvent(projectID: pid, accountID: overseas.id, timestamp: t, type: .withdrawal,
                                      baseAsset: AssetSymbol(asset), quantity: -sent, sourceKind: stream(overseas))
                push(out, overseas, [(asset, -sent)])
                // 지갑 입고는 거래소 명세서가 아니므로 잔고를 찍지 않는다
                let into = LedgerEvent(projectID: pid, accountID: wallet.id, timestamp: t, type: .deposit,
                                       baseAsset: AssetSymbol(asset), quantity: arrived,
                                       sourceKind: "manual-wallet-v1", rawRef: "wallet:\(step)")
                push(into, wallet, [(asset, arrived)], printBalance: false)
                links.append(TransferLink(id: LinkID(), projectID: pid, fromEventID: out.id, toEventID: into.id,
                                          status: .confirmed, withdrawnQty: sent, receivedQty: arrived,
                                          score: 1, note: "개인지갑"))

            case 8: // 개인지갑 → 거래소 (receiveFromWallet)
                let asset = ["BTC", "ETH"][rng.int(0...1)]
                let have = held[key(wallet, asset)] ?? 0
                guard have > 0 else { continue }
                let sent = have / Decimal(rng.int(1...2))
                guard sent > 0 else { continue }
                let out = LedgerEvent(projectID: pid, accountID: wallet.id, timestamp: t, type: .withdrawal,
                                      baseAsset: AssetSymbol(asset), quantity: -sent,
                                      sourceKind: "manual-wallet-v1", rawRef: "wallet-out:\(step)")
                push(out, wallet, [(asset, -sent)], printBalance: false)
                let into = LedgerEvent(projectID: pid, accountID: overseas.id, timestamp: t, type: .deposit,
                                       baseAsset: AssetSymbol(asset), quantity: sent, sourceKind: stream(overseas))
                push(into, overseas, [(asset, sent)])
                links.append(TransferLink(id: LinkID(), projectID: pid, fromEventID: out.id, toEventID: into.id,
                                          status: .confirmed, withdrawnQty: sent, receivedQty: sent,
                                          score: 1, note: "개인지갑"))

            case 9: // 18자리 수량 — ETH wei 단위 매수/매도
                let q = rng.qty18()
                guard q > 0 else { continue }
                let usdt = held[key(overseas, "USDT")] ?? 0
                guard usdt > 10 else { continue }
                let spend = usdt / Decimal(rng.int(4...10))
                let e = LedgerEvent(projectID: pid, accountID: overseas.id, timestamp: t, type: .buy,
                                    baseAsset: AssetSymbol("ETH"), quoteAsset: AssetSymbol("USDT"),
                                    quantity: q, quoteAmount: spend, sourceKind: stream(overseas))
                push(e, overseas, [("ETH", q), ("USDT", -spend)])

            case 10: // 같은 초에 매수 → 매도 (순서가 뒤집히면 재고 부족이 난다)
                let usdt = held[key(overseas, "USDT")] ?? 0
                guard usdt > 50 else { continue }
                let spend = usdt / Decimal(rng.int(3...8))
                let q = spend / Decimal(rng.int(1_000...60_000))
                guard q > 0 else { continue }
                let buy = LedgerEvent(projectID: pid, accountID: overseas.id, timestamp: t, type: .buy,
                                      baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
                                      quantity: q, quoteAmount: spend, sourceKind: stream(overseas))
                push(buy, overseas, [("BTC", q), ("USDT", -spend)])
                let back = q * Decimal(rng.int(1_000...60_000))
                let sell = LedgerEvent(projectID: pid, accountID: overseas.id, timestamp: t, type: .sell,
                                       baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
                                       quantity: -q, quoteAmount: back, sourceKind: stream(overseas))
                push(sell, overseas, [("BTC", -q), ("USDT", back)])

            default:
                break
            }
        }

        var market: [String: Decimal] = [:]
        for k in held.keys {
            let asset = String(k.split(separator: "|").last ?? "")
            market[asset] = Decimal(rng.int(1_000...80_000_000))
        }
        return Scenario(accounts: accounts, events: events, links: links, fx: fx, market: market, intended: held)
    }

    // MARK: - 실행

    private func replay(_ s: Scenario) throws -> ReplayResult {
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(s.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: s.fx, marketPrices: s.market
        )
        return try engine.replay(events: s.events, links: s.links)
    }

    private func summarize(_ s: Scenario, _ r: ReplayResult, year: Int) -> TaxYearSummary {
        TaxAggregator.aggregate(
            projectID: s.accounts[0].projectID, disposals: r.disposals, taxYear: year,
            extraDeductible: r.extraDeductibleByYear[year] ?? 0,
            abandonedTransferCostKRW: r.abandonedByYear[year] ?? 0,
            deemed: r.deemedPositions, policies: .v1Default
        )
    }

    // MARK: - 불변식

    func testWideScenarioHasNoCriticals() throws {
        for seed in UInt64(1)...120 {
            let s = makeScenario(seed: seed)
            let r = try replay(s)
            // 재실행은 **진짜로 한 번 더 돌린다** (같은 객체를 넣으면 결정성 검사가 무력화된다 — 감사 G-2)
            let r2 = try replay(s)
            for year in TaxTime.taxStartYear...2030 {
                let summary = summarize(s, r, year: year)
                let rerun = summarize(s, r2, year: year)
                let report = Verifier.verify(VerifierInput(
                    summary: summary, replay: r, policies: .v1Default,
                    events: s.events, summaryRerun: rerun, links: s.links, fxPublished: s.fx
                ))
                let criticals = report.issues.filter { $0.severity == "critical" }
                XCTAssertTrue(
                    criticals.isEmpty,
                    "seed \(seed) / \(year)년: 정상 시나리오에서 Critical\n"
                        + criticals.map { "\($0.id) \($0.message) [\($0.context ?? "")]" }.joined(separator: "\n")
                )
                XCTAssertGreaterThanOrEqual(summary.totalTaxKRW, 0, "seed \(seed) \(year)")
            }
        }
    }

    /// **생성기가 실제로 그 경우를 만들었는지** 먼저 센다.
    /// 이걸 안 보면 `continue` 로 다 빠져나간 생성기가 「Critical 0건」으로 조용히 통과한다.
    func testGeneratorActuallyCoversTheNewCases() throws {
        var walletIn = 0, walletOut = 0, sameSecond = 0, longDecimals = 0
        var thirdAssetFee = 0, years: Set<Int> = [], lossYears = 0
        for seed in UInt64(1)...120 {
            let s = makeScenario(seed: seed)
            let wallet = s.accounts.first { $0.exchangeCode == .wallet }!
            walletIn += s.events.filter { $0.accountID == wallet.id && $0.type == .deposit }.count
            walletOut += s.events.filter { $0.accountID == wallet.id && $0.type == .withdrawal }.count
            thirdAssetFee += s.events.filter {
                guard let fa = $0.feeAsset else { return false }
                return fa != $0.baseAsset && fa != $0.quoteAsset && !fa.isKRW
            }.count
            longDecimals += s.events.filter { Money.decimalString(Money.abs($0.quantity)).count > 14 }.count
            for (i, e) in s.events.enumerated() where i > 0 {
                if e.timestamp == s.events[i - 1].timestamp { sameSecond += 1 }
            }
            for e in s.events { years.insert(TaxTime.calendarYearKST(e.timestamp)) }
            let r = try replay(s)
            for y in TaxTime.taxStartYear...2030 where summarize(s, r, year: y).netIncomeKRW < 0 { lossYears += 1 }
        }
        XCTAssertGreaterThan(walletIn, 50, "개인지갑 입고가 거의 안 만들어졌다")
        XCTAssertGreaterThan(walletOut, 30, "개인지갑 출고가 거의 안 만들어졌다")
        XCTAssertGreaterThan(sameSecond, 100, "같은 시각 거래가 거의 없다")
        XCTAssertGreaterThan(longDecimals, 50, "긴 소수 수량이 거의 없다")
        XCTAssertGreaterThan(thirdAssetFee, 30, "제3자산 수수료가 거의 없다")
        XCTAssertGreaterThan(lossYears, 20, "손실만 난 해가 거의 없다")
        XCTAssertTrue(years.contains(2026) && years.contains(2027) && years.count >= 3,
                      "다년도가 안 만들어졌다: \(years.sorted())")
    }

    func testEngineMatchesGeneratorIntent() throws {
        for seed in UInt64(1)...120 {
            let s = makeScenario(seed: seed)
            let r = try replay(s)
            var actual: [String: Decimal] = [:]
            for row in r.holdings.rows {
                guard let acc = row.accountID else { continue }
                actual["\(acc.raw.uuidString)|\(row.asset.code)"] = row.quantity
            }
            for (key, want) in s.intended where !key.hasSuffix("|KRW") {
                let got = actual[key] ?? 0
                XCTAssertLessThanOrEqual(
                    Money.abs(want - got), Money.qtyEpsilon,
                    "seed \(seed) \(key.split(separator: "|").last ?? ""): 의도 \(Money.decimalString(want)) / 엔진 \(Money.decimalString(got))"
                )
            }
        }
    }

    /// 손실만 난 해가 다음 해 세금을 깎으면 안 된다 (결손금 이월공제 없음 — 03-tax-rules §1)
    func testLossYearDoesNotReduceOtherYears() throws {
        for seed in UInt64(1)...80 {
            let s = makeScenario(seed: seed)
            let r = try replay(s)
            for year in TaxTime.taxStartYear...2030 {
                let sum = summarize(s, r, year: year)
                if sum.netIncomeKRW < 0 {
                    XCTAssertEqual(sum.taxBaseKRW, 0, "seed \(seed) \(year): 손실인데 과세표준이 0이 아니다")
                    XCTAssertEqual(sum.totalTaxKRW, 0, "seed \(seed) \(year): 손실인데 세액이 있다")
                }
                // 그 해 합계에는 그 해 처분만 들어가야 한다
                for d in sum.disposals {
                    XCTAssertEqual(TaxTime.calendarYearKST(d.timestamp), year, "seed \(seed): 다른 해 처분 혼입")
                }
            }
            // 과세 대상 처분은 연도별 합계에 빠짐없이 한 번씩만 들어간다
            let taxable = r.disposals.filter { $0.taxYear >= TaxTime.taxStartYear }
            var counted = 0
            for year in TaxTime.taxStartYear...2035 { counted += summarize(s, r, year: year).disposals.count }
            XCTAssertEqual(counted, taxable.count, "seed \(seed): 과세 처분 건수가 연도 합과 다르다")
        }
    }

    /// 거래소 잔고 대조가 멀쩡한 자료를 오탐하지 않고, 망가뜨리면 반드시 잡는다
    func testBalanceReconcilerOnWideScenario() throws {
        var caught = 0, attempted = 0
        for seed in UInt64(1)...80 {
            let s = makeScenario(seed: seed)
            let clean = BalanceReconciler.reconcile(events: s.events)
            XCTAssertTrue(clean.isEmpty, "seed \(seed): 멀쩡한 자료에서 잔고 오탐 \(clean.map { "\($0.asset.code) \($0.kind.rawValue)" })")

            let removable = s.events.indices.filter { i in
                let e = s.events[i]
                guard e.type == .buy || e.type == .sell else { return false }
                return s.events[(i + 1)...].contains {
                    $0.accountID == e.accountID && $0.sourceKind == e.sourceKind
                        && ($0.baseAsset == e.baseAsset || $0.quoteAsset == e.baseAsset)
                }
            }
            guard let victim = removable.dropFirst(removable.count / 2).first else { continue }
            attempted += 1
            var broken = s.events
            broken.remove(at: victim)
            if !BalanceReconciler.reconcile(events: broken).isEmpty { caught += 1 }
        }
        XCTAssertGreaterThan(attempted, 40)
        XCTAssertEqual(caught, attempted, "거래가 빠졌는데 잔고 대조가 못 잡았다")
    }
}
