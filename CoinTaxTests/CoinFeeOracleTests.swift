import XCTest
@testable import CoinTax

/// **코인으로 낸 수수료**가 의제 재기동을 걸칠 때의 숫자를 손계산과 대조한다 (5차 감사 회차 33).
///
/// 03-tax-rules §7 의 확정 규칙:
/// 「코인으로 낸 수수료(USDT·BNB…)는 **그 자산 장부에서 처분**하고 **장부 원가**를 부대비용으로」.
/// 그래서 수수료로 쓴 코인도 2027-01-01 의제 재기동을 받고,
/// **재기동 뒤에 낸 수수료는 원가가 올라간다** — 이 상호작용은 손으로 확인된 적이 없었다.
final class CoinFeeOracleTests: XCTestCase {

    /// 손계산
    /// ```text
    /// 2026-05-01 BNB 10 매수 40만                     → BNB 10 @40,000
    /// 2026-06-01 BTC 1 매수 5,000만 · 수수료 BNB 1
    ///     수수료: BNB 1 을 장부에서 처분 → 원가 40,000
    ///     BTC 취득원가 = 5,000만 + 40,000 = 50,040,000
    ///     BNB 남은 9 @40,000 = 360,000
    /// 2027-01-01 0시 시가 BTC 6,000만 · BNB 50,000 → 의제 재기동
    ///     BTC max(50,040,000, 60,000,000) = 60,000,000
    ///     BNB max(40,000, 50,000)         = 50,000 → 9개 450,000
    /// 2027-03-01 BTC 1 매도 7,000만 · 수수료 BNB 2
    ///     양도 7,000만 − 취득 6,000만 − 수수료(BNB 2 × 50,000 = 100,000)
    ///     → 소득 9,900,000 · BNB 남은 7 @50,000
    /// 과세표준 7,400,000 → 국세 1,480,000 · 지방세 148,000 · 합계 1,628,000
    /// ```
    func testCoinFeeCostFollowsDeemedReboot() throws {
        let pid = ProjectID()
        let binance = Account.defaults(for: .binance, projectID: pid)

        let bnbBuy = LedgerEvent(
            projectID: pid, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 5, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BNB"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10, quoteAmountKRW: 400_000, sourceKind: "oracle", rawRef: "r1"
        )
        let btcBuy = LedgerEvent(
            projectID: pid, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000,
            feeAmount: 1, feeAsset: AssetSymbol("BNB"), sourceKind: "oracle", rawRef: "r2"
        )
        let btcSell = LedgerEvent(
            projectID: pid, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1, hour: 10),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 70_000_000,
            feeAmount: 2, feeAsset: AssetSymbol("BNB"), sourceKind: "oracle", rawRef: "r3"
        )
        let events = [bnbBuy, btcBuy, btcSell]

        let replay = try CostBasisEngine(
            policies: .v1Default, accountsByID: [binance.id: binance],
            fxRates: [:], marketPrices: ["BTC": 60_000_000, "BNB": 50_000]
        ).replay(events: events, links: [])

        // 의제: BTC 는 시가 채택, BNB 도 시가 채택
        let btcDeemed = try XCTUnwrap(replay.deemedPositions.first { $0.asset.code == "BTC" })
        XCTAssertEqual(btcDeemed.bookUnitKRW, 50_040_000, "매수 수수료가 취득원가에 한 번만 가산돼야 한다")
        XCTAssertEqual(btcDeemed.deemedUnitKRW, 60_000_000)
        let bnbDeemed = try XCTUnwrap(replay.deemedPositions.first { $0.asset.code == "BNB" })
        XCTAssertEqual(bnbDeemed.quantity, 9, "수수료로 1개 나갔다")
        XCTAssertEqual(bnbDeemed.bookUnitKRW, 40_000)
        XCTAssertEqual(bnbDeemed.deemedUnitKRW, 50_000, "수수료로 쓸 코인도 의제 재기동을 받는다")

        let disposal = try XCTUnwrap(replay.disposals.first { $0.asset.code == "BTC" })
        XCTAssertEqual(disposal.proceedsKRW, 70_000_000)
        XCTAssertEqual(disposal.costKRW, 60_000_000)
        XCTAssertEqual(disposal.feesKRW, 100_000, "BNB 2개 × 재기동 단가 50,000")
        XCTAssertEqual(disposal.pnlKRW, 9_900_000)

        let bnbLeft = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "BNB" })
        XCTAssertEqual(bnbLeft.quantity, 7, "10 − 1(매수수수료) − 2(매도수수료)")
        XCTAssertEqual(bnbLeft.totalCostKRW, 350_000, "7 × 50,000")

        let summary = TaxAggregator.aggregate(
            projectID: pid, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        XCTAssertEqual(summary.totalCostsKRW, 60_100_000, "취득가 6,000만 + 수수료 10만")
        XCTAssertEqual(summary.netIncomeKRW, 9_900_000)
        XCTAssertEqual(summary.taxBaseKRW, 7_400_000)
        XCTAssertEqual(summary.nationalTaxKRW, 1_480_000)
        XCTAssertEqual(summary.localTaxKRW, 148_000)
        XCTAssertEqual(summary.totalTaxKRW, 1_628_000)

        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: events, summaryRerun: summary, links: []
        ))
        let criticals = report.issues.filter { $0.severity == "critical" }
        XCTAssertTrue(criticals.isEmpty, "정상 경로에서 Critical: " + criticals.map(\.id).joined(separator: ", "))
    }

    /// 수수료를 **원화로** 낸 같은 자료와 비교 — 코인 수수료가 이중으로 빠지지 않는지 본다.
    ///
    /// 원화 수수료 10만원이면 필요경비도 10만원이다. 코인으로 내도 **장부 원가만큼만** 빠져야 하고,
    /// 그 코인의 수량이 따로 줄어야 한다 (수량과 금액을 둘 다 빼면 이중 계상이다).
    func testKRWFeeAndCoinFeeDeductTheSameOnce() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        func sell(fee: Decimal?, feeAsset: AssetSymbol?) -> [LedgerEvent] {
            [
                LedgerEvent(projectID: pid, accountID: acc.id,
                            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 5, hour: 10),
                            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: "o", rawRef: "r1"),
                LedgerEvent(projectID: pid, accountID: acc.id,
                            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 5, hour: 10),
                            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                            quantity: -1, quoteAmountKRW: 60_000_000,
                            feeAmount: fee, feeAsset: feeAsset, sourceKind: "o", rawRef: "r2")
            ]
        }
        func income(_ events: [LedgerEvent]) throws -> Decimal {
            let r = try CostBasisEngine(policies: .v1Default, accountsByID: [acc.id: acc],
                                        fxRates: [:], marketPrices: [:])
                .replay(events: events, links: [])
            return r.disposals.reduce(Decimal(0)) { $0 + $1.pnlKRW }
        }
        let noFee = try income(sell(fee: nil, feeAsset: nil))
        let krwFee = try income(sell(fee: 100_000, feeAsset: AssetSymbol("KRW")))
        XCTAssertEqual(noFee, 10_000_000)
        XCTAssertEqual(krwFee, 9_900_000, "원화 수수료는 그대로 필요경비")
    }
}
