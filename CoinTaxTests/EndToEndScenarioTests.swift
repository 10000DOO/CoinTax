import XCTest
@testable import CoinTax

/// §10-3~5,11,12: 매칭 확정 → 원가 이전 → 실현손익·세액·abandon 비공제
final class EndToEndScenarioTests: XCTestCase {
    func testDomesticWithdrawOverseasDepositSellPipeline() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)
        let binance = Account.defaults(for: .binance, projectID: projectID)

        let tBuy = TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 10)
        let tW = TaxTime.dateKST(year: 2027, month: 2, day: 2, hour: 10)
        let tD = TaxTime.dateKST(year: 2027, month: 2, day: 2, hour: 12)
        let tSell = TaxTime.dateKST(year: 2027, month: 2, day: 10, hour: 12)

        let buy = LedgerEvent(
            projectID: projectID, accountID: bithumb.id, timestamp: tBuy, type: .buy,
            baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10, quoteAmountKRW: 140_000, sourceKind: "e2e"
        )
        let w = LedgerEvent(
            projectID: projectID, accountID: bithumb.id, timestamp: tW, type: .withdrawal,
            baseAsset: AssetSymbol("USDT"), quantity: -10, counterpartyHint: "binance", sourceKind: "e2e"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: binance.id, timestamp: tD, type: .deposit,
            baseAsset: AssetSymbol("USDT"), quantity: 9.9, sourceKind: "e2e"
        )
        let sell = LedgerEvent(
            projectID: projectID, accountID: binance.id, timestamp: tSell, type: .sell,
            baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: -9.9, quoteAmountKRW: 160_000, sourceKind: "e2e"
        )
        let events = [buy, w, d, sell]

        // suggest → confirm
        let matcher = TransferMatchingEngine(accountsByID: [bithumb.id: bithumb, binance.id: binance])
        let cands = matcher.suggest(events: events, existing: [])
        XCTAssertEqual(cands.count, 1)
        XCTAssertGreaterThanOrEqual(cands[0].score, 0.35)

        let link = TransferLink(
            id: LinkID(), projectID: projectID,
            fromEventID: w.id, toEventID: d.id,
            status: .confirmed,
            withdrawnQty: cands[0].withdrawnQty,
            receivedQty: cands[0].receivedQty
        )

        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: [bithumb.id: bithumb, binance.id: binance],
            fxRates: [:],
            marketPrices: [:]
        )
        let replay = try engine.replay(events: events, links: [link])
        XCTAssertEqual(replay.abandonedTotal, Decimal(1_400))
        XCTAssertEqual(replay.extraDeductible, 0)
        XCTAssertEqual(replay.disposals.count, 1)
        XCTAssertEqual(replay.disposals[0].pnlKRW, Decimal(21_400)) // 160000 - 138600

        let summary = TaxAggregator.aggregate(
            projectID: projectID,
            disposals: replay.disposals,
            taxYear: 2027,
            extraDeductible: replay.extraDeductible,
            abandonedTransferCostKRW: replay.abandonedTotal,
            deemed: replay.deemedPositions,
            policies: policies
        )
        XCTAssertEqual(summary.policyBundleID, "cointax-v1.1")
        XCTAssertEqual(summary.totalProceedsKRW, Decimal(160_000))
        XCTAssertEqual(summary.netIncomeKRW, Decimal(21_400))
        XCTAssertEqual(summary.basicDeductionKRW, Decimal(2_500_000))
        XCTAssertEqual(summary.taxBaseKRW, 0)
        XCTAssertEqual(summary.disclaimers.count, 4)
        XCTAssertEqual(TaxCopy.all, summary.disclaimers)

        let v = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: policies, events: events, summaryRerun: summary
        ))
        XCTAssertFalse(v.issues.contains { $0.id == "V-COST-03" && $0.severity == "critical" && $0.message.contains("필요경비에 포함") })
        // abandon not in deductible
        XCTAssertEqual(replay.extraDeductible, 0)
    }

    func testReportExportRequiresVerificationPass() throws {
        let policies = PolicyBundle.v1Default
        var summary = TaxYearSummary(
            projectID: ProjectID(), taxYear: 2027, status: .draft, policyBundleID: policies.id,
            totalProceedsKRW: 0, totalCostsKRW: 0, netIncomeKRW: 0, basicDeductionKRW: 2_500_000,
            taxBaseKRW: 0, nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
            abandonedTransferCostKRW: 0, disposals: [], deemed: [], disclaimers: policies.disclaimers,
            calculatedAt: Date(), verification: nil
        )
        XCTAssertThrowsError(try ReportCSVExporter.exportCSV(summary))

        let pass = VerificationReport(runID: UUID(), status: "passed", issues: [], calculatedAt: Date())
        summary.verification = pass
        let csv = try ReportCSVExporter.exportCSV(summary)
        XCTAssertTrue(csv.contains("cointax-v1.1"))
        XCTAssertTrue(csv.contains("totalProceedsKRW"))
        XCTAssertTrue(csv.contains("basicDeductionKRW"))
        XCTAssertTrue(csv.contains("disclaimer"))
        for d in TaxCopy.all {
            XCTAssertTrue(csv.contains(d.prefix(20)))
        }
    }

    func testDeemedMaxInFullReplay() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let acc = Account.defaults(for: .bithumb, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: "e2e"
        )
        let sell = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 80_000_000, sourceKind: "e2e"
        )
        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: [acc.id: acc],
            fxRates: [:],
            marketPrices: ["BTC": 60_000_000] // higher than book 50m
        )
        let replay = try engine.replay(events: [buy, sell], links: [])
        XCTAssertEqual(replay.deemedPositions.first?.deemedUnitKRW, Decimal(60_000_000))
        XCTAssertEqual(replay.disposals.first?.costKRW, Decimal(60_000_000))
        XCTAssertEqual(replay.disposals.first?.pnlKRW, Decimal(20_000_000))
    }
}
