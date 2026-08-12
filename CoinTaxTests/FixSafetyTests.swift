import XCTest
@testable import CoinTax

/// 앞선 수정이 **반대로 틀린 것은 아닌지** 되짚어 보강한 부분의 회귀 테스트.
///
/// 배경: OKX 수수료 관례는 저장소 문서의 「합성 예시」 숫자에만 근거했다.
/// 관례를 단정하는 대신 파일 안의 숫자로 판정하도록 바꿨고, 그 판정을 여기서 고정한다.
final class FixSafetyTests: XCTestCase {
    private let projectID = ProjectID()
    private lazy var accountID = AccountID()

    private func okxCSV(amount: String, fee: String, balanceChange: String) -> String {
        """
        UID:000,Account Type:Main,Time Zone:UTC+8
        id,Order id,Time,Trade Type,Symbol,Action,Amount,Trading Unit,Filled Price,PnL,Fee,Fee Unit,Position Change,Position Balance,Balance Change,Balance,Balance Unit
        1,100,2027-06-01 08:25:29,Spot,BTC-USDT,Buy,\(amount),BTC,90000,0,\(fee),BTC,0,0,\(balanceChange),\(balanceChange),BTC
        2,100,2027-06-01 08:25:29,Spot,BTC-USDT,Sell,900,USDT,90000,0,0,USDT,0,0,-900,100,USDT
        """
    }

    // MARK: 잔고증감이 순액인 경우 → 엔진이 다시 빼지 않아야 한다

    func testDetectsNetBalanceChange() throws {
        // 0.01 − 0.00001 = 0.00999  → 순액
        let result = try OKXTradingHistoryCSVParser().parse(
            text: okxCSV(amount: "0.01", fee: "-0.00001", balanceChange: "0.00999"),
            fileName: "t.csv", projectID: projectID, accountID: accountID
        )
        let buy = try XCTUnwrap(result.events.first { $0.type == .buy })
        XCTAssertTrue(buy.quantityIsNetOfFee, "Amount − Fee 와 일치하면 순액으로 판정")
        XCTAssertEqual(buy.quantity, Decimal(string: "0.00999")!)
        XCTAssertTrue(result.warnings.filter { $0.contains("판정하지 못") }.isEmpty)
    }

    // MARK: 잔고증감이 총액인 경우 → 엔진이 빼야 한다 (수정 전 동작이 옳은 경우)

    func testDetectsGrossBalanceChange() throws {
        // 0.01 = Amount 그대로 → 총액. 수수료는 따로 빠진다.
        let result = try OKXTradingHistoryCSVParser().parse(
            text: okxCSV(amount: "0.01", fee: "-0.00001", balanceChange: "0.01"),
            fileName: "t.csv", projectID: projectID, accountID: accountID
        )
        let buy = try XCTUnwrap(result.events.first { $0.type == .buy })
        XCTAssertFalse(buy.quantityIsNetOfFee, "Amount 와 같으면 총액으로 판정 — 엔진이 수수료를 뺀다")

        let acc = Account.defaults(for: .okx, projectID: projectID)
        var event = buy
        event.accountID = acc.id
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: [TaxTime.dayKST(event.timestamp): 1400], marketPrices: [:]
        )
        let replay = try engine.replay(events: [event], links: [])
        let row = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "BTC" })
        XCTAssertEqual(row.quantity, Decimal(string: "0.00999")!, "총액 0.01 − 수수료 0.00001")
    }

    // MARK: 판정 불가 → 가정하지 않고 경고

    func testUnknownRelationWarnsAndKeepsGrossBehaviour() throws {
        // 세 값이 어느 관계에도 맞지 않는다
        let result = try OKXTradingHistoryCSVParser().parse(
            text: okxCSV(amount: "0.01", fee: "-0.00001", balanceChange: "0.007"),
            fileName: "t.csv", projectID: projectID, accountID: accountID
        )
        let buy = try XCTUnwrap(result.events.first { $0.type == .buy })
        XCTAssertFalse(buy.quantityIsNetOfFee, "판정 불가 시 기존 동작(총액) 유지")
        XCTAssertTrue(result.warnings.contains { $0.contains("판정하지 못") }, "조용히 넘어가지 않는다")
    }

    // MARK: OKX Trading 만 넣으면 외부 입출금 누락 → 검증이 막아야 한다

    func testOKXTradingWithoutFundingIsBlocked() throws {
        let acc = Account.defaults(for: .okx, projectID: projectID)
        let internalMove = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 2),
            type: .transferInternal, baseAsset: AssetSymbol("USDT"), quantity: 10,
            sourceKind: "okx-trading-history-csv-v1", rawRef: "row3"
        )
        let replay = ReplayResult(
            disposals: [], holdings: HoldingsBuilder.empty(), deemedPositions: [],
            abandonedTotal: 0, extraDeductible: 0, warnings: [], transferCostDetails: [],
            missingMarketAssets: [], missingFXDays: [], fxResolutions: []
        )
        let summary = TaxYearSummary(
            projectID: projectID, taxYear: 2027, status: .draft, policyBundleID: PolicyBundle.v1Default.id,
            totalProceedsKRW: 0, totalCostsKRW: 0, netIncomeKRW: 0, basicDeductionKRW: 2_500_000,
            taxBaseKRW: 0, nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
            abandonedTransferCostKRW: 0, disposals: [], deemed: [],
            disclaimers: PolicyBundle.v1Default.disclaimers, calculatedAt: Date(), verification: nil
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: [internalMove], summaryRerun: summary
        ))
        XCTAssertTrue(report.issues.contains { $0.id == "V-IMP-04" && $0.severity == "critical" },
                      "Funding History 없이 Trading 만 있으면 Critical")
        XCTAssertFalse(report.isExportAllowed)

        // Funding History 도 함께 있으면 통과
        let fundingDeposit = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 2),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 10,
            sourceKind: "okx-funding-history-csv-v1", rawRef: "row3"
        )
        let report2 = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: [internalMove, fundingDeposit], summaryRerun: summary
        ))
        XCTAssertFalse(report2.issues.contains { $0.id == "V-IMP-04" })
    }

    // MARK: 별칭 표가 서로 다른 자산을 합치지 않아야 한다

    func testAliasTableDoesNotMergeDistinctAssets() {
        XCTAssertEqual(AssetSymbol("XBT").code, "BTC", "같은 자산의 다른 티커는 합친다")
        XCTAssertEqual(AssetSymbol("BCHABC").code, "BCH")

        // 래핑·브릿지 토큰은 별개 자산 — 합치면 취득 이력이 섞인다
        XCTAssertEqual(AssetSymbol("WBTC").code, "WBTC")
        XCTAssertEqual(AssetSymbol("WETH").code, "WETH")
        XCTAssertEqual(AssetSymbol("USDT.E").code, "USDT.E")

        // 원화 연동 토큰을 KRW 로 합치면 엔진이 원장에서 제외해 버린다
        XCTAssertEqual(AssetSymbol("KRWT").code, "KRWT")
        XCTAssertFalse(AssetSymbol("KRWT").isKRW)

        // 네트워크 접미사를 임의로 자르지 않는다 (근거 없는 추측 금지)
        XCTAssertEqual(AssetSymbol("USDT-TRC20").code, "USDT-TRC20")
    }

    // MARK: 매도 수수료가 기초자산일 때 엔진과 검증기가 같은 수량을 봐야 한다

    func testBaseAssetFeeOnSellDoesNotCauseFalseCritical() throws {
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "r1"
        )
        // 매도 수수료가 기초자산(BTC)으로 붙은 경우
        let sell = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 4, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: Decimal(string: "-0.5")!, quoteAmountKRW: 60_000_000,
            feeAmount: Decimal(string: "0.001")!, feeAsset: AssetSymbol("BTC"),
            sourceKind: "t", rawRef: "r2"
        )
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc], fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: [buy, sell], links: [])
        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: replay.extraDeductible, abandonedTransferCostKRW: replay.abandonedTotal,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: [buy, sell], summaryRerun: summary
        ))
        XCTAssertFalse(
            report.issues.contains { $0.id == "V-QTY-01" },
            "엔진과 검증기가 같은 규칙을 써야 한다 — 거짓 실패 금지"
        )
        // 매도 수수료가 기초자산이면 체결 수량과 **별도로** 빠진다 (매수는 받는 수량에서 차감된다)
        let row = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "BTC" })
        XCTAssertEqual(row.quantity, Decimal(string: "0.499")!, "1 − 0.5(매도) − 0.001(수수료)")
        // 그 수수료의 장부 원가가 필요경비로 잡혀야 한다 (0.001 BTC × 1억/BTC)
        let disposal = try XCTUnwrap(replay.disposals.first { $0.asset.code == "BTC" })
        XCTAssertEqual(disposal.feesKRW, 100_000)
    }

    // MARK: 과거(2026년) 제3자산 수수료가 의제 검사에 거짓 실패를 내지 않아야 한다

    func testPreTaxThirdAssetFeeDoesNotCauseFalseDeemedCritical() throws {
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let bnb = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
            type: .buy, baseAsset: AssetSymbol("BNB"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 700_000, sourceKind: "t", rawRef: "r1"
        )
        let btc = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 4, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000,
            feeAmount: Decimal(string: "0.1")!, feeAsset: AssetSymbol("BNB"),
            sourceKind: "t", rawRef: "r2"
        )
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: [:], marketPrices: ["BTC": 60_000_000, "BNB": 800_000]
        )
        let replay = try engine.replay(events: [bnb, btc], links: [])
        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: [bnb, btc], summaryRerun: summary
        ))
        XCTAssertFalse(
            report.issues.contains { $0.id == "V-DEM-01" },
            "수수료로 쓴 BNB 0.1개를 검증기도 반영해야 한다"
        )
        let bnbPos = try XCTUnwrap(replay.deemedPositions.first { $0.asset.code == "BNB" })
        XCTAssertEqual(bnbPos.quantity, Decimal(string: "0.9")!)
    }
}
