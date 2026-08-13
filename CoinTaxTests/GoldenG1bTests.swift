import XCTest
@testable import CoinTax

final class GoldenG1bTests: XCTestCase {
    func testG1b_taxPositive() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)
        let binance = Account.defaults(for: .binance, projectID: projectID)

        let tBuy = TaxTime.dateKST(year: 2027, month: 1, day: 2, hour: 10)
        let tW = TaxTime.dateKST(year: 2027, month: 1, day: 3, hour: 10)
        let tD = TaxTime.dateKST(year: 2027, month: 1, day: 3, hour: 11)
        let tSell = TaxTime.dateKST(year: 2027, month: 1, day: 10, hour: 12)

        let buy = LedgerEvent(
            projectID: projectID, accountID: bithumb.id, timestamp: tBuy, type: .buy,
            baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10, quoteAmountKRW: 140_000, sourceKind: "test"
        )
        let w = LedgerEvent(
            projectID: projectID, accountID: bithumb.id, timestamp: tW, type: .withdrawal,
            baseAsset: AssetSymbol("USDT"), quantity: -10, sourceKind: "test"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: binance.id, timestamp: tD, type: .deposit,
            baseAsset: AssetSymbol("USDT"), quantity: 9.9, sourceKind: "test"
        )
        let sell = LedgerEvent(
            projectID: projectID, accountID: binance.id, timestamp: tSell, type: .sell,
            baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: -9.9, quoteAmountKRW: 10_000_000, sourceKind: "test"
        )
        let link = TransferLink(
            id: LinkID(), projectID: projectID,
            fromEventID: w.id, toEventID: d.id,
            status: .confirmed, withdrawnQty: 10, receivedQty: 9.9
        )

        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: [bithumb.id: bithumb, binance.id: binance],
            fxRates: [:],
            marketPrices: [:]
        )
        let replay = try engine.replay(events: [buy, w, d, sell], links: [link])
        let disp = try XCTUnwrap(replay.disposals.first)
        XCTAssertEqual(disp.pnlKRW, Decimal(9_861_400))

        let summary = TaxAggregator.aggregate(
            projectID: projectID,
            disposals: replay.disposals,
            taxYear: 2027,
            extraDeductible: 0,
            abandonedTransferCostKRW: replay.abandonedTotal,
            deemed: [],
            policies: policies
        )
        // 끝수는 국고금 관리법 §47 — 세액은 국세·지방세 **각각** 10원 버림
        let rounding = StatutoryKRWRoundingPolicy()
        XCTAssertEqual(summary.taxBaseKRW, Decimal(7_361_400))
        XCTAssertEqual(summary.nationalTaxKRW, rounding.floorPayableKRW(Decimal(7_361_400) * Decimal(string: "0.2")!))
        XCTAssertEqual(summary.localTaxKRW, rounding.floorPayableKRW(Decimal(7_361_400) * Decimal(string: "0.02")!))
        XCTAssertEqual(summary.nationalTaxKRW, Decimal(1_472_280))
        // 7,361,400 × 2% = 147,228 → 10원 버림 → 147,220
        XCTAssertEqual(summary.localTaxKRW, Decimal(147_220))
    }
}
