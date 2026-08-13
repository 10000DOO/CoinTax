import XCTest
@testable import CoinTax

/// **원가 엔진과 「수량 규칙 한 벌」이 언제나 같은 답을 내는가** — 전수 대조.
///
/// 네 번의 감사에서 새어 나간 결함 중 가장 많은 것이
/// 「같은 규칙을 두 곳에 따로 적어 놓고 한쪽만 고친 것」이었다 (A-03 · D-2 · D4-1).
/// 한 건씩 손으로 고르면 또 빠뜨리므로, **거래 종류 × 수수료를 낸 자산 × 순액 여부**를
/// 전부 돌려 `CostBasisEngine` 의 보유 수량과 `LedgerDelta` 의 수량 합을 맞춘다.
///
/// 이 둘이 어긋나면 사용자에게는 두 가지로 나타난다 —
/// 보유 현황의 수량이 틀리거나, 정상 자료인데 `V-QTY-01` Critical 로 내보내기가 잠긴다.
final class LedgerRuleParityTests: XCTestCase {

    private let base = AssetSymbol("BTC")
    private let quote = AssetSymbol("USDT")
    private let other = AssetSymbol("BNB")
    private let krw = AssetSymbol("KRW")

    /// 과세 시작 이후로 잡아 의제 재기동이 끼어들지 않게 한다 (수량만 보는 검사).
    private func t(_ dayOffset: Int) -> Date {
        TaxTime.dateKST(year: 2027, month: 3, day: 1).addingTimeInterval(TimeInterval(dayOffset) * 86_400)
    }

    private struct Fixture {
        var account: Account
        var far: Account
        var events: [LedgerEvent]
    }

    /// BTC 100 · USDT 10,000 · BNB 100 을 원화로 사 둔 계정
    private func seeded(_ pid: ProjectID) -> Fixture {
        let acc = Account.defaults(for: .binance, projectID: pid)
        let far = Account.defaults(for: .bithumb, projectID: pid)
        func krwBuy(_ asset: AssetSymbol, _ qty: Decimal, _ cost: Decimal, _ day: Int) -> LedgerEvent {
            var e = LedgerEvent(
                projectID: pid, accountID: acc.id, timestamp: t(day), type: .buy,
                baseAsset: asset, quoteAsset: krw, quantity: qty, quoteAmountKRW: cost,
                sourceKind: "parity", rawRef: "s0000\(day)"
            )
            e.fingerprint = "seed-\(asset.code)"
            return e
        }
        return Fixture(account: acc, far: far, events: [
            krwBuy(base, 100, 100_000_000, 1),
            krwBuy(quote, 10_000, 14_000_000, 2),
            krwBuy(other, 100, 10_000_000, 3)
        ])
    }

    private func replay(_ f: Fixture, _ extra: [LedgerEvent], links: [TransferLink] = []) throws -> ReplayResult {
        var fx: [String: Decimal] = [:]
        for e in f.events + extra { fx[TaxTime.dayKST(e.timestamp)] = 1_400 }
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: [f.account.id: f.account, f.far.id: f.far],
            fxRates: fx,
            marketPrices: [:]
        )
        return try engine.replay(events: f.events + extra, links: links)
    }

    private func expectedQuantities(_ events: [LedgerEvent]) -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        for e in events where e.type != .ignored {
            for c in LedgerDelta.bookChanges(for: e) {
                out["\(e.accountID.raw.uuidString)|\(c.asset.code)", default: 0] += c.delta
            }
        }
        return out
    }

    private func actualQuantities(_ r: ReplayResult) -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        for row in r.holdings.rows {
            guard let acc = row.accountID else { continue }
            out["\(acc.raw.uuidString)|\(row.asset.code)"] = row.quantity
        }
        return out
    }

    private func assertEngineMatchesRule(
        _ f: Fixture, _ extra: [LedgerEvent], links: [TransferLink] = [],
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let r = try replay(f, extra, links: links)
        let want = expectedQuantities(f.events + extra)
        let got = actualQuantities(r)
        // 재고 부족이면 원리상 차이가 남는다 — 이 검사는 충분한 재고만 쓴다
        XCTAssertTrue(r.shortfallKeys.isEmpty, "\(label): 재고 부족이 났다 (검사 설정 오류)", file: file, line: line)
        for (key, w) in want {
            let g = got[key] ?? 0
            XCTAssertLessThanOrEqual(
                Money.abs(w - g), Money.qtyEpsilon,
                "\(label) — \(key.split(separator: "|").last ?? ""): 규칙 \(Money.decimalString(w)) / 엔진 \(Money.decimalString(g))",
                file: file, line: line
            )
        }
    }

    private func feeVariants() -> [(String, AssetSymbol?)] {
        [("수수료자산 없음", nil), ("기초자산", base), ("견적자산", quote), ("제3자산", other), ("원화", krw)]
    }

    /// 원화 수수료는 코인 수량이 아니다. 코인 수량으로 쓰면 1,500원이 코인 1,500개를 지운다.
    private func feeAmount(for fa: AssetSymbol?) -> Decimal {
        fa == krw ? 1_500 : Decimal(string: "0.5")!
    }

    // MARK: - 매수·매도

    func testBuyFeeVariantsMatchRule() throws {
        for (name, fa) in feeVariants() {
            for net in [false, true] {
                let pid = ProjectID()
                let f = seeded(pid)
                var e = LedgerEvent(
                    projectID: pid, accountID: f.account.id, timestamp: t(10), type: .buy,
                    baseAsset: base, quoteAsset: quote, quantity: 10, quoteAmount: 500,
                    feeAmount: feeAmount(for: fa), feeAsset: fa,
                    sourceKind: "parity", rawRef: "s00010", quantityIsNetOfFee: net
                )
                e.fingerprint = "buy-\(name)-\(net)"
                try assertEngineMatchesRule(f, [e], "매수/\(name)/순액=\(net)")
            }
        }
    }

    func testSellFeeVariantsMatchRule() throws {
        for (name, fa) in feeVariants() {
            for net in [false, true] {
                let pid = ProjectID()
                let f = seeded(pid)
                var e = LedgerEvent(
                    projectID: pid, accountID: f.account.id, timestamp: t(10), type: .sell,
                    baseAsset: base, quoteAsset: quote, quantity: -10, quoteAmount: 500,
                    feeAmount: feeAmount(for: fa), feeAsset: fa,
                    sourceKind: "parity", rawRef: "s00010", quantityIsNetOfFee: net
                )
                e.fingerprint = "sell-\(name)-\(net)"
                try assertEngineMatchesRule(f, [e], "매도/\(name)/순액=\(net)")
            }
        }
    }

    // MARK: - 출금 (연결 없음 / 연결 있음) — 감사 D4-1 이 났던 자리

    func testUnlinkedWithdrawalFeeVariantsMatchRule() throws {
        for (name, fa) in feeVariants() {
            let pid = ProjectID()
            let f = seeded(pid)
            var e = LedgerEvent(
                projectID: pid, accountID: f.account.id, timestamp: t(10), type: .withdrawal,
                baseAsset: base, quantity: -10,
                feeAmount: feeAmount(for: fa), feeAsset: fa,
                sourceKind: "parity", rawRef: "s00010"
            )
            e.fingerprint = "wd-\(name)"
            try assertEngineMatchesRule(f, [e], "미연결 출금/\(name)")
        }
    }

    func testLinkedWithdrawalFeeVariantsMatchRule() throws {
        for (name, fa) in feeVariants() {
            let pid = ProjectID()
            let f = seeded(pid)
            var w = LedgerEvent(
                projectID: pid, accountID: f.account.id, timestamp: t(10), type: .withdrawal,
                baseAsset: base, quantity: -10,
                feeAmount: feeAmount(for: fa), feeAsset: fa,
                sourceKind: "parity", rawRef: "s00010"
            )
            w.fingerprint = "wdl-\(name)"
            var d = LedgerEvent(
                projectID: pid, accountID: f.far.id, timestamp: t(11), type: .deposit,
                baseAsset: base, quantity: 10, sourceKind: "parity", rawRef: "s00011"
            )
            d.fingerprint = "dep-\(name)"
            let link = TransferLink(
                id: LinkID(), projectID: pid, fromEventID: w.id, toEventID: d.id,
                status: .confirmed, withdrawnQty: 10, receivedQty: 10, score: 1, note: nil
            )
            try assertEngineMatchesRule(f, [w, d], links: [link], "연결 출금/\(name)")
        }
    }

    /// 규칙이 어긋나면 정상 자료인데 `V-QTY-01` Critical 로 내보내기가 잠긴다.
    /// 원화로 적힌 출금 수수료가 그 재현 조건이었다 (감사 D4-1).
    func testKRWWithdrawalFeeDoesNotBlockExport() throws {
        let pid = ProjectID()
        let f = seeded(pid)
        var e = LedgerEvent(
            projectID: pid, accountID: f.account.id, timestamp: t(10), type: .withdrawal,
            baseAsset: base, quantity: -10,
            feeAmount: 1_500, feeAsset: krw,
            sourceKind: "parity", rawRef: "s00010"
        )
        e.fingerprint = "wd-krwfee"
        let events = f.events + [e]
        let r = try replay(f, [e])
        let summary = TaxAggregator.aggregate(
            projectID: pid, disposals: r.disposals, taxYear: 2027,
            extraDeductible: r.extraDeductibleByYear[2027] ?? 0,
            abandonedTransferCostKRW: r.abandonedByYear[2027] ?? 0,
            deemed: r.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: r, policies: .v1Default,
            events: events, summaryRerun: summary, links: [], fxPublished: [:]
        ))
        let qty01 = report.issues.filter { $0.id == "V-QTY-01" && $0.severity == "critical" }
        XCTAssertTrue(qty01.isEmpty, "정상 자료인데 V-QTY-01 Critical: \(qty01.map(\.message))")
        // 원화 수수료는 코인을 건드리지 않는다 — BTC 는 딱 출금한 10개만 줄어야 한다
        let btc = actualQuantities(r)["\(f.account.id.raw.uuidString)|BTC"] ?? 0
        XCTAssertEqual(btc, 90, "원화 수수료가 BTC 수량을 건드렸다")
    }

    // MARK: - 규칙 그 자체 (넘겨짚기가 다시 들어오면 여기서 잡힌다)

    func testWithdrawalFeeRuleAnswersPerFeeAsset() {
        func event(feeAsset fa: AssetSymbol?, netOfFee: Bool = false, fee: Decimal? = 3) -> LedgerEvent {
            LedgerEvent(
                projectID: ProjectID(), accountID: AccountID(), timestamp: Date(),
                type: .withdrawal, baseAsset: base, quantity: -10,
                feeAmount: fee, feeAsset: fa, sourceKind: "parity", quantityIsNetOfFee: netOfFee
            )
        }
        // 자산 칸이 비면 보내는 코인으로 본다 (네트워크 수수료 관례)
        XCTAssertEqual(LedgerDelta.withdrawalFeeQuantity(event(feeAsset: nil)), 3)
        XCTAssertEqual(LedgerDelta.withdrawalFeeQuantity(event(feeAsset: base)), 3)
        // 원화·제3코인으로 적혀 있으면 **이 코인 수량은 줄지 않는다**
        XCTAssertNil(LedgerDelta.withdrawalFeeQuantity(event(feeAsset: krw)))
        XCTAssertNil(LedgerDelta.withdrawalFeeQuantity(event(feeAsset: other)))
        XCTAssertNil(LedgerDelta.withdrawalFeeQuantity(event(feeAsset: quote)))
        // 원본이 이미 순액이면 다시 빼지 않는다
        XCTAssertNil(LedgerDelta.withdrawalFeeQuantity(event(feeAsset: base, netOfFee: true)))
        XCTAssertNil(LedgerDelta.withdrawalFeeQuantity(event(feeAsset: base, fee: nil)))
        XCTAssertNil(LedgerDelta.withdrawalFeeQuantity(event(feeAsset: base, fee: 0)))
    }

    /// 재고가 모자라 수수료를 못 뺐으면 **할 일이 적힌 안내**(V-QTY-02)가 떠야 한다.
    /// 기록하지 않으면 원인 불명의 V-QTY-01 만 뜬다.
    func testWithdrawalFeeShortfallIsReported() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        var buy = LedgerEvent(
            projectID: pid, accountID: acc.id, timestamp: t(1), type: .buy,
            baseAsset: base, quoteAsset: krw, quantity: 10, quoteAmountKRW: 10_000_000,
            sourceKind: "parity", rawRef: "s00001"
        )
        buy.fingerprint = "b"
        // 10개 사서 10개를 보내는데 수수료가 1개 더 필요하다 → 1개 부족
        var wd = LedgerEvent(
            projectID: pid, accountID: acc.id, timestamp: t(2), type: .withdrawal,
            baseAsset: base, quantity: -10, feeAmount: 1, feeAsset: base,
            sourceKind: "parity", rawRef: "s00002"
        )
        wd.fingerprint = "w"
        let engine = CostBasisEngine(policies: .v1Default, accountsByID: [acc.id: acc], fxRates: [:], marketPrices: [:])
        let r = try engine.replay(events: [buy, wd], links: [])
        let shortfall = r.issues.filter { $0.id == "V-QTY-02" && $0.message.contains("출금 수수료") }
        XCTAssertFalse(shortfall.isEmpty, "수수료를 뺄 재고가 없었는데 아무 안내도 없다: \(r.issues.map(\.id))")
    }
}
