import XCTest
@testable import CoinTax

final class FXHolidayPolicyTests: XCTestCase {
    /// 공휴일·주말 미고시 → 직전 고시일 (서삼46015-11986 취지)
    func testHolidayUsesPreviousPublishedRate() {
        let published: [String: Decimal] = [
            "2027-01-08": 1300, // 금요일 고시
            // 1/9 토, 1/10 일 미고시
            "2027-01-11": 1310  // 월요일
        ]
        let sat = FXHolidayPolicy.resolve(eventDay: "2027-01-09", published: published)
        XCTAssertEqual(sat?.rate, 1300)
        XCTAssertEqual(sat?.sourceDate, "2027-01-08")
        XCTAssertEqual(sat?.usedPreviousPublished, true)
        XCTAssertEqual(sat?.sourceTag, "previousBusinessDay")

        let sun = FXHolidayPolicy.resolve(eventDay: "2027-01-10", published: published)
        XCTAssertEqual(sun?.rate, 1300)
        XCTAssertEqual(sun?.sourceDate, "2027-01-08")
        XCTAssertTrue(sun?.usedPreviousPublished == true)
    }

    func testSameDayPublishedNotRolled() {
        let published: [String: Decimal] = ["2027-03-15": 1400]
        let r = FXHolidayPolicy.resolve(eventDay: "2027-03-15", published: published)
        XCTAssertEqual(r?.rate, 1400)
        XCTAssertEqual(r?.sourceDate, "2027-03-15")
        XCTAssertEqual(r?.usedPreviousPublished, false)
        XCTAssertEqual(r?.sourceTag, "sameDay")
    }

    func testLongHolidayLookbackWithin14Days() {
        var published: [String: Decimal] = ["2027-02-01": 1200]
        // 2/2~2/14 미고시, 2/15 거래
        let r = FXHolidayPolicy.resolve(eventDay: "2027-02-10", published: published)
        XCTAssertEqual(r?.sourceDate, "2027-02-01")
        XCTAssertEqual(r?.rate, 1200)
    }

    func testEngineAppliesHolidayRateToSell() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: projectID)
        // 금요일 매수(KRW), 일요일 매도(USDT 견적) → 미고시일 환율 롤백
        let buyKRW = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 8, hour: 12),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10, quoteAmountKRW: 13_000, sourceKind: "t"
        )
        let sellSun = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 10, hour: 12), // Sunday
            type: .sell, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("USDT"),
            quantity: -10, price: 1, quoteAmount: 10, sourceKind: "t"
        )
        // Only Friday rate 1300 — Sunday sell uses rolled rate for proceeds
        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: [acc.id: acc],
            fxRates: ["2027-01-08": 1300],
            marketPrices: [:]
        )
        let replay = try engine.replay(events: [buyKRW, sellSun], links: [])
        XCTAssertEqual(replay.disposals.count, 1)
        // proceeds = 10 USDT * 1300 = 13000
        XCTAssertEqual(replay.disposals[0].proceedsKRW, 13_000)
        XCTAssertTrue(replay.fxResolutions.contains { $0.eventDay == "2027-01-10" && $0.sourceDate == "2027-01-08" })
        XCTAssertTrue(replay.warnings.contains { $0.contains("직전 고시일") })
    }

    func testVFX03WarnsWhenSourceDateMissingOnRoll() {
        let policies = PolicyBundle.v1Default
        let summary = TaxYearSummary(
            projectID: ProjectID(), taxYear: 2027, status: .draft, policyBundleID: policies.id,
            totalProceedsKRW: 0, totalCostsKRW: 0, netIncomeKRW: 0, basicDeductionKRW: 2_500_000,
            taxBaseKRW: 0, nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
            abandonedTransferCostKRW: 0, disposals: [], deemed: [], disclaimers: [],
            calculatedAt: Date(), verification: nil
        )
        let bad = FXResolvedRate(
            eventDay: "2027-01-10", rate: 1300, sourceDate: "",
            usedPreviousPublished: true, sourceTag: "previousBusinessDay"
        )
        let replay = ReplayResult(
            disposals: [], holdings: HoldingsBuilder.empty(), deemedPositions: [],
            abandonedTotal: 0, extraDeductible: 0, warnings: [], transferCostDetails: [],
            missingMarketAssets: [], missingFXDays: [], fxResolutions: [bad]
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: policies, events: [], summaryRerun: summary
        ))
        XCTAssertTrue(report.issues.contains { $0.id == "V-FX-03" && $0.severity == "warning" })
    }
}
