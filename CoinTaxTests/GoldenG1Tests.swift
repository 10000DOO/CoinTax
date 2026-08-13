import XCTest
@testable import CoinTax

final class GoldenG1Tests: XCTestCase {
    func testG1_transferAndSell_taxZero() throws {
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
            quantity: -9.9, quoteAmountKRW: 150_000, sourceKind: "test"
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

        XCTAssertEqual(replay.transferCostDetails.count, 1)
        let td = try XCTUnwrap(replay.transferCostDetails.first)
        XCTAssertEqual(td.transferredCostKRW, Decimal(138_600))
        XCTAssertEqual(td.abandonedCostKRW, Decimal(1_400))
        XCTAssertEqual(replay.abandonedTotal, Decimal(1_400))

        XCTAssertEqual(replay.disposals.count, 1)
        let disp = try XCTUnwrap(replay.disposals.first)
        XCTAssertEqual(disp.costKRW, Decimal(138_600))
        XCTAssertEqual(disp.proceedsKRW, Decimal(150_000))
        XCTAssertEqual(disp.pnlKRW, Decimal(11_400))

        let summary = TaxAggregator.aggregate(
            projectID: projectID,
            disposals: replay.disposals,
            taxYear: 2027,
            extraDeductible: replay.extraDeductible,
            abandonedTransferCostKRW: replay.abandonedTotal,
            deemed: replay.deemedPositions,
            policies: policies
        )
        XCTAssertEqual(summary.netIncomeKRW, Decimal(11_400))
        XCTAssertEqual(summary.taxBaseKRW, 0)
        XCTAssertEqual(summary.totalTaxKRW, 0)
        XCTAssertEqual(summary.abandonedTransferCostKRW, Decimal(1_400))

        let v = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: policies, events: [buy, w, d, sell], summaryRerun: summary
        ))
        // may fail V-DEM if missing market for empty pre-tax — no pre-tax holdings
        XCTAssertFalse(v.issues.contains { $0.id == "V-TAX-02" && $0.severity == "critical" })
        XCTAssertEqual(summary.policyBundleID, "cointax-v1.2")
    }
}
