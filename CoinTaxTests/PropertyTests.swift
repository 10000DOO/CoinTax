import XCTest
import SwiftData
@testable import CoinTax

/// 무작위 시나리오 테스트.
///
/// 사람이 쓰는 테스트는 사람이 생각한 경우만 본다. 이번 감사에서 새어 나간 결함들
/// (연말을 걸친 전송, 같은 초에 뒤집힌 순서, 수수료를 견적자산으로 낸 매매)이 전부
/// **아무도 그 조합을 테스트로 쓰지 않았기 때문**에 통과했다.
///
/// 여기서는 매수·매도·전송·수수료를 수천 가지로 섞어 돌리고, **어떤 입력에도 깨지면 안 되는 것**만 본다.
/// 실패하면 시드 번호가 찍히므로 그대로 재현할 수 있다.
final class PropertyTests: XCTestCase {

    // MARK: - 재현 가능한 난수 (Swift 기본 난수는 실행마다 달라 실패를 재현할 수 없다)

    struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        /// 소수 8자리로 끊은 수량 — 거래소 관례
        mutating func qty(_ lo: Int, _ hi: Int) -> Decimal {
            let whole = Decimal(int(lo...hi))
            let frac = Decimal(int(0...99_999_999)) / 100_000_000
            return whole + frac
        }
        mutating func bool(_ percentTrue: Int = 50) -> Bool { int(1...100) <= percentTrue }
    }

    // MARK: - 시나리오 생성기
    //
    // **실행 가능한** 시나리오만 만든다 (없는 코인을 팔지 않는다). 그래야 「정상 입력에서
    // Critical 이 하나도 나오면 안 된다」는 강한 단정을 걸 수 있다.

    struct Scenario {
        var accounts: [Account]
        var events: [LedgerEvent]
        var links: [TransferLink]
        var fxRates: [String: Decimal]
        var marketPrices: [String: Decimal]
        /// 생성기가 **의도한** 잔고 (계정|자산 → 수량). 엔진과 별개로 세어 둔 값.
        var intendedHoldings: [String: Decimal]
    }

    private func makeScenario(seed: UInt64, steps: Int = 40) -> Scenario {
        var rng = SeededRNG(seed: seed)
        let pid = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: pid)   // 이동평균
        let binance = Account.defaults(for: .binance, projectID: pid)   // 선입선출
        let accounts = [bithumb, binance]

        var events: [LedgerEvent] = []
        var links: [TransferLink] = []
        var held: [String: Decimal] = [:]      // "계정|자산" → 수량
        var balances: [String: Decimal] = [:]  // 생성기가 매기는 거래소 잔고
        var fx: [String: Decimal] = [:]
        var seq = 0

        // 2026-02 ~ 2027-08 — 과세 시작(2027-01-01)을 사이에 두고 걸친다
        var day = 0
        func nextTime(sameInstant: Bool) -> Date {
            if !sameInstant { day += rng.int(1...12) }
            let base = TaxTime.dateKST(year: 2026, month: 2, day: 1)
            return base.addingTimeInterval(TimeInterval(day) * 86_400 + TimeInterval(rng.int(0...80_000)))
        }
        func key(_ a: Account, _ asset: String) -> String { "\(a.id.raw.uuidString)|\(asset)" }
        func stamp(_ e: inout LedgerEvent, _ acc: Account, _ changes: [(String, Decimal)]) {
            for (asset, delta) in changes {
                held[key(acc, asset), default: 0] += delta
                balances[key(acc, asset), default: 0] += delta
            }
            // 거래소가 찍어 주는 잔고 — 생성기가 **의도한** 값이다.
            // 엔진의 수량 규칙이 이 의도와 어긋나면 V-BAL 이 잡는다.
            e.balanceAfter = balances[key(acc, e.baseAsset.code)]
            if let q = e.quoteAsset, !q.isKRW {
                e.quoteBalanceAfter = balances[key(acc, q.code)]
            }
            seq += 1
            e.rawRef = String(format: "s%05d", seq)
            e.fingerprint = "fp-\(seed)-\(seq)"
        }

        var lastTime = Date.distantPast
        func push(_ e: LedgerEvent) {
            var copy = e
            if copy.timestamp < lastTime { copy.timestamp = lastTime }
            lastTime = copy.timestamp
            fx[TaxTime.dayKST(copy.timestamp)] = Decimal(rng.int(1_200...1_500))
            events.append(copy)
        }

        // 씨앗: 빗썸에서 원화로 USDT 를 산다
        do {
            let t = nextTime(sameInstant: false)
            let q = rng.qty(2_000, 5_000)
            var e = LedgerEvent(projectID: pid, accountID: bithumb.id, timestamp: t,
                                type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
                                quantity: q, quoteAmountKRW: q * 1_400, sourceKind: "gen")
            stamp(&e, bithumb, [("USDT", q)])
            push(e)
        }

        for _ in 0..<steps {
            let sameInstant = rng.bool(15)
            let t = nextTime(sameInstant: sameInstant)
            switch rng.int(1...6) {
            case 1: // 빗썸 원화 매수 (USDT 또는 BTC)
                let asset = rng.bool() ? "USDT" : "BTC"
                let q = asset == "USDT" ? rng.qty(100, 900) : rng.qty(0, 1)
                guard q > 0 else { continue }
                var e = LedgerEvent(projectID: pid, accountID: bithumb.id, timestamp: t,
                                    type: .buy, baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("KRW"),
                                    quantity: q, quoteAmountKRW: q * Decimal(rng.int(1_000...90_000_000)), sourceKind: "gen")
                stamp(&e, bithumb, [(asset, q)])
                push(e)

            case 2: // 빗썸 원화 매도 (보유 범위 안에서만)
                let asset = rng.bool() ? "USDT" : "BTC"
                let have = held[key(bithumb, asset)] ?? 0
                guard have > 1 else { continue }
                let q = have / Decimal(rng.int(2...4))
                var e = LedgerEvent(projectID: pid, accountID: bithumb.id, timestamp: t,
                                    type: .sell, baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("KRW"),
                                    quantity: -q, quoteAmountKRW: q * Decimal(rng.int(1_000...90_000_000)),
                                    feeAmount: Decimal(rng.int(0...500)), feeAsset: AssetSymbol("KRW"),
                                    sourceKind: "gen")
                stamp(&e, bithumb, [(asset, -q)])
                push(e)

            case 3: // 빗썸 → 바이낸스 USDT 전송 (수수료로 일부 소실)
                let have = held[key(bithumb, "USDT")] ?? 0
                guard have > 10 else { continue }
                let sent = have / Decimal(rng.int(2...5))
                let lost = sent / Decimal(rng.int(50...500))
                let received = sent - lost
                var out = LedgerEvent(projectID: pid, accountID: bithumb.id, timestamp: t,
                                      type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -sent,
                                      sourceKind: "gen")
                stamp(&out, bithumb, [("USDT", -sent)])
                push(out)
                var into = LedgerEvent(projectID: pid, accountID: binance.id,
                                       timestamp: t.addingTimeInterval(TimeInterval(rng.int(60...7_200))),
                                       type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: received,
                                       sourceKind: "gen")
                stamp(&into, binance, [("USDT", received)])
                push(into)
                links.append(TransferLink(id: LinkID(), projectID: pid,
                                          fromEventID: out.id, toEventID: into.id, status: .confirmed,
                                          withdrawnQty: sent, receivedQty: received, score: 1, note: nil))

            case 4: // 바이낸스 코인↔코인 매수 (수수료를 USDT 또는 BNB 로)
                let usdt = held[key(binance, "USDT")] ?? 0
                guard usdt > 20 else { continue }
                let spend = usdt / Decimal(rng.int(2...5))
                let asset = rng.bool() ? "BTC" : "ETH"
                let q = spend / Decimal(rng.int(1_000...60_000))
                guard q > 0 else { continue }
                let feeInQuote = rng.bool(60)
                let fee = feeInQuote ? spend / 1_000 : q / 1_000
                var e = LedgerEvent(projectID: pid, accountID: binance.id, timestamp: t,
                                    type: .buy, baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("USDT"),
                                    quantity: q, quoteAmount: spend,
                                    feeAmount: fee, feeAsset: AssetSymbol(feeInQuote ? "USDT" : asset),
                                    sourceKind: "gen")
                // 매수의 기초자산 수수료는 **받는 수량에서** 깎이고, 견적자산 수수료는 별도로 나간다
                let changes: [(String, Decimal)] = feeInQuote
                    ? [(asset, q), ("USDT", -spend - fee)]
                    : [(asset, q - fee), ("USDT", -spend)]
                stamp(&e, binance, changes)
                push(e)

            case 5: // 바이낸스 코인↔코인 매도
                let asset = rng.bool() ? "BTC" : "ETH"
                let have = held[key(binance, asset)] ?? 0
                guard have > 0 else { continue }
                let q = have / Decimal(rng.int(2...4))
                guard q > 0 else { continue }
                let proceeds = q * Decimal(rng.int(1_000...60_000))
                let feeInQuote = rng.bool(70)
                let fee = feeInQuote ? proceeds / 1_000 : q / 1_000
                var e = LedgerEvent(projectID: pid, accountID: binance.id, timestamp: t,
                                    type: .sell, baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("USDT"),
                                    quantity: -q, quoteAmount: proceeds,
                                    feeAmount: fee, feeAsset: AssetSymbol(feeInQuote ? "USDT" : asset),
                                    sourceKind: "gen")
                // 매도의 기초자산 수수료는 체결 수량과 **별도로** 빠진다
                let changes: [(String, Decimal)] = feeInQuote
                    ? [(asset, -q), ("USDT", proceeds - fee)]
                    : [(asset, -q - fee), ("USDT", proceeds)]
                stamp(&e, binance, changes)
                push(e)

            case 6: // 보상 (에어드롭·이자)
                let asset = ["USDT", "BTC", "ETH"][rng.int(0...2)]
                let q = rng.qty(0, 1) / 100
                guard q > 0 else { continue }
                let acc = rng.bool() ? bithumb : binance
                var e = LedgerEvent(projectID: pid, accountID: acc.id, timestamp: t,
                                    type: .income, baseAsset: AssetSymbol(asset), quantity: q,
                                    sourceKind: "gen")
                stamp(&e, acc, [(asset, q)])
                push(e)

            default:
                break
            }
        }

        // 의제취득가에 필요한 시가는 전부 채운다 (없으면 정상 계산도 blocked 가 된다)
        var market: [String: Decimal] = [:]
        for k in held.keys {
            let asset = String(k.split(separator: "|").last ?? "")
            market[asset] = Decimal(rng.int(1_000...80_000_000))
        }
        return Scenario(accounts: accounts, events: events, links: links,
                        fxRates: fx, marketPrices: market, intendedHoldings: held)
    }

    private func run(_ s: Scenario) throws -> (ReplayResult, TaxYearSummary, VerificationReport) {
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(s.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: s.fxRates, marketPrices: s.marketPrices
        )
        let replay = try engine.replay(events: s.events, links: s.links)
        let summary = TaxAggregator.aggregate(
            projectID: s.accounts[0].projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: replay.extraDeductibleByYear[2027] ?? 0,
            abandonedTransferCostKRW: replay.abandonedByYear[2027] ?? 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: s.events, summaryRerun: summary, links: s.links, fxPublished: s.fxRates
        ))
        return (replay, summary, report)
    }

    // MARK: - 어떤 입력에도 깨지면 안 되는 것

    func testInvariantsHoldForRandomScenarios() throws {
        for seed in UInt64(1)...200 {
            let s = makeScenario(seed: seed)
            let (replay, summary, report) = try run(s)

            let criticals = report.issues.filter { $0.severity == "critical" }
            XCTAssertTrue(
                criticals.isEmpty,
                "seed \(seed): 정상 시나리오에서 Critical 이 났다\n"
                    + criticals.map { "\($0.id) \($0.message) [\($0.context ?? "")]" }.joined(separator: "\n")
            )

            // 보유 수량·총원가는 음수가 될 수 없다
            for row in replay.holdings.rows {
                XCTAssertGreaterThanOrEqual(row.quantity, 0, "seed \(seed) \(row.asset.code) 음수 수량")
                XCTAssertGreaterThanOrEqual(row.totalCostKRW, -1, "seed \(seed) \(row.asset.code) 음수 원가")
            }
            // 세액은 음수가 될 수 없고, 과세표준이 0이면 세액도 0이다
            XCTAssertGreaterThanOrEqual(summary.totalTaxKRW, 0, "seed \(seed)")
            if summary.taxBaseKRW == 0 { XCTAssertEqual(summary.totalTaxKRW, 0, "seed \(seed)") }
            // 소득금액을 **건별 구성요소**로 다시 더한다.
            //
            // 예전에는 `Σ pnl − 추가공제` 와 비교했는데, 집계기가 소득금액을 **글자 그대로 같은 식**으로
            // 만들어서 실패할 수 없는 검사였다 (5차 감사 회차 20). pnl 을 믿지 않고
            // 양도 − 취득 − 비용 으로 다시 더해야 엔진의 pnl 이 틀렸을 때 걸린다.
            let recomputed = summary.disposals.reduce(Decimal(0)) {
                $0 + ($1.proceedsKRW - $1.costKRW - $1.feesKRW)
            } - summary.extraDeductibleKRW
            XCTAssertLessThanOrEqual(Money.abs(recomputed - summary.netIncomeKRW), 1, "seed \(seed)")
            // 리포트에 나란히 찍히는 세 숫자도 산수가 맞아야 한다
            XCTAssertLessThanOrEqual(
                Money.abs((summary.totalProceedsKRW - summary.totalCostsKRW) - summary.netIncomeKRW), 1,
                "seed \(seed): 총수입 − 필요경비 ≠ 소득금액"
            )
        }
    }

    /// 같은 입력이면 언제나 같은 결과여야 한다 (신고자료 재현성)
    func testReplayIsDeterministic() throws {
        for seed in UInt64(1)...60 {
            let s = makeScenario(seed: seed)
            let (a, sa, _) = try run(s)
            let (b, sb, _) = try run(s)
            XCTAssertEqual(a.disposals.count, b.disposals.count, "seed \(seed)")
            XCTAssertEqual(sa.netIncomeKRW, sb.netIncomeKRW, "seed \(seed)")
            XCTAssertEqual(sa.totalTaxKRW, sb.totalTaxKRW, "seed \(seed)")
            XCTAssertEqual(
                a.holdings.rows.map { "\($0.asset.code):\(Money.decimalString($0.quantity))" },
                b.holdings.rows.map { "\($0.asset.code):\(Money.decimalString($0.quantity))" },
                "seed \(seed)"
            )
        }
    }

    /// 생성기가 **의도한** 잔고와 엔진 결과가 같아야 한다.
    /// (전송으로 다른 계정에 넘어간 몫까지 포함해 계정×자산 단위로 맞춘다)
    func testEngineMatchesGeneratorIntent() throws {
        for seed in UInt64(1)...80 {
            let s = makeScenario(seed: seed)
            let (replay, _, _) = try run(s)
            var actual: [String: Decimal] = [:]
            for row in replay.holdings.rows {
                guard let acc = row.accountID else { continue }
                actual["\(acc.raw.uuidString)|\(row.asset.code)"] = row.quantity
            }
            for (key, want) in s.intendedHoldings where !key.hasSuffix("|KRW") {
                let got = actual[key] ?? 0
                XCTAssertLessThanOrEqual(
                    Money.abs(want - got), Money.qtyEpsilon,
                    "seed \(seed) \(key.split(separator: "|").last ?? ""): 의도 \(Money.decimalString(want)) / 엔진 \(Money.decimalString(got))"
                )
            }
        }
    }

    // MARK: - 검출기가 실제로 검출하는가 (변이 테스트)
    //
    // 「검사를 붙였다」와 「검사가 작동한다」는 다르다. 일부러 망가뜨려 놓고 잡히는지 본다.

    func testBalanceReconcilerCatchesMissingEvent() throws {
        var caught = 0
        var attempted = 0
        for seed in UInt64(1)...60 {
            let s = makeScenario(seed: seed)
            XCTAssertTrue(BalanceReconciler.reconcile(events: s.events).isEmpty,
                          "seed \(seed): 멀쩡한 시나리오에서 잔고가 어긋났다")

            // 중간 거래 하나를 통째로 빼 본다 (원본 일부가 빠진 상황).
            //
            // **뒤에 같은 자산 거래가 남아 있는** 것만 고른다. 자산의 마지막 거래를 빼면 그 뒤에
            // 대조할 잔고가 없어 원리상 못 잡는다 — 검출기의 한계이지 결함이 아니다.
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
        XCTAssertGreaterThan(attempted, 30)
        XCTAssertEqual(caught, attempted, "거래가 빠졌는데 잔고 대조가 못 잡았다")
    }

    func testBalanceReconcilerCatchesWrongQuantity() throws {
        var caught = 0
        var attempted = 0
        for seed in UInt64(1)...60 {
            let s = makeScenario(seed: seed)
            let targets = s.events.indices.filter { s.events[$0].type == .buy }
            guard let victim = targets.dropFirst(targets.count / 2).first else { continue }
            attempted += 1
            var broken = s.events
            // 수량을 1% 틀리게 읽은 상황 (파싱 오류·단위 오해)
            broken[victim].quantity = broken[victim].quantity * Decimal(string: "1.01")!
            if !BalanceReconciler.reconcile(events: broken).isEmpty { caught += 1 }
        }
        XCTAssertGreaterThan(attempted, 30)
        XCTAssertEqual(caught, attempted, "수량이 틀렸는데 잔고 대조가 못 잡았다")
    }

    /// 자료가 중간부터 시작해 앞부분 보유가 없는 경우 — 「자료 시작 전 보유분」으로 잡아야 한다
    func testBalanceReconcilerReportsOpeningBalance() throws {
        var reported = 0
        var attempted = 0
        for seed in UInt64(1)...40 {
            let s = makeScenario(seed: seed)
            guard s.events.count > 12 else { continue }
            attempted += 1
            let truncated = Array(s.events.dropFirst(6))
            let findings = BalanceReconciler.reconcile(events: truncated)
            if findings.contains(where: { $0.kind == .openingBalance }) { reported += 1 }
        }
        XCTAssertGreaterThan(attempted, 20)
        XCTAssertEqual(reported, attempted, "앞부분이 잘린 자료를 「시작 전 보유분」으로 알리지 못했다")
    }
}
