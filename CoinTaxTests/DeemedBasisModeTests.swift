import XCTest
@testable import CoinTax

/// TQ-01: 의제취득가 비교 단위를 평균/건별 둘 다 지원하는지 확인.
///
/// 문서 예시: 4천만원 1개 + 8천만원 1개 보유, 2026-12-31 시가 6천만원
///   평균 방식 → 평균 6천만 vs 시가 6천만 → 취득가 1.2억
///   건별 방식 → max(4천,6천) + max(8천,6천) → 취득가 1.4억
final class DeemedBasisModeTests: XCTestCase {
    private let projectID = ProjectID()

    private func fixture(mode: DeemedBasisMode) throws -> ReplayResult {
        // 선입선출 계정 (해외) — 건별 구분이 있는 쪽
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let cheap = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2025, month: 3, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 40_000_000, sourceKind: "t", rawRef: "r1"
        )
        let pricey = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 80_000_000, sourceKind: "t", rawRef: "r2"
        )
        // 2027년에 2개 전량 매도
        let sell = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -2, quoteAmountKRW: 200_000_000, sourceKind: "t", rawRef: "r3"
        )
        var policies = PolicyBundle.v1Default
        policies.deemed = MaxBookMarketDeemedPolicy(mode: mode)
        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: [acc.id: acc],
            fxRates: [:],
            marketPrices: ["BTC": 60_000_000]
        )
        return try engine.replay(events: [cheap, pricey, sell], links: [])
    }

    func testPositionAverageMode() throws {
        let replay = try fixture(mode: .positionAverage)
        let pos = try XCTUnwrap(replay.deemedPositions.first)
        XCTAssertEqual(pos.bookUnitKRW, 60_000_000, "평균 취득단가")
        XCTAssertEqual(pos.deemedUnitKRW, 60_000_000, "평균 60,000,000 vs 시가 60,000,000 → 60,000,000")
        XCTAssertEqual(pos.totalDeemedKRW, 120_000_000)
        XCTAssertEqual(pos.lotCount, 1)
        XCTAssertEqual(pos.basisMode, DeemedBasisMode.positionAverage.rawValue)

        let disp = try XCTUnwrap(replay.disposals.first)
        XCTAssertEqual(disp.costKRW, 120_000_000)
        XCTAssertEqual(disp.pnlKRW, 80_000_000, "2억 − 1.2억")
    }

    func testPerLotMode() throws {
        let replay = try fixture(mode: .perLot)
        let pos = try XCTUnwrap(replay.deemedPositions.first)
        XCTAssertEqual(pos.bookUnitKRW, 60_000_000, "표시용 평균 단가는 그대로")
        XCTAssertEqual(pos.totalDeemedKRW, 140_000_000, "max(4천,6천)+max(8천,6천)")
        XCTAssertEqual(pos.deemedUnitKRW, 70_000_000, "가중 평균 단가")
        XCTAssertEqual(pos.lotCount, 2, "lot 두 개가 각각 재기동")
        XCTAssertEqual(pos.basisMode, DeemedBasisMode.perLot.rawValue)

        let disp = try XCTUnwrap(replay.disposals.first)
        XCTAssertEqual(disp.costKRW, 140_000_000)
        XCTAssertEqual(disp.pnlKRW, 60_000_000, "2억 − 1.4억")
    }

    /// 두 방식의 세액 차이가 문서 예시(2천만원 취득가 차이 → 세액 440만원)와 맞는지
    func testTaxDifferenceBetweenModes() throws {
        func tax(_ mode: DeemedBasisMode) throws -> Decimal {
            let replay = try fixture(mode: mode)
            var policies = PolicyBundle.v1Default
            policies.deemed = MaxBookMarketDeemedPolicy(mode: mode)
            let s = TaxAggregator.aggregate(
                projectID: projectID, disposals: replay.disposals, taxYear: 2027,
                extraDeductible: 0, abandonedTransferCostKRW: 0,
                deemed: replay.deemedPositions, policies: policies
            )
            return s.totalTaxKRW
        }
        let avg = try tax(.positionAverage)
        let lot = try tax(.perLot)
        XCTAssertEqual(avg - lot, 4_400_000, "취득가 2천만원 차이 × 22%")
    }

    /// 이동평균 계정(빗썸)은 매입 건 구분이 없으므로 두 방식 결과가 같아야 한다
    func testMovingAverageAccountUnaffectedByMode() throws {
        let acc = Account.defaults(for: .bithumb, projectID: projectID)
        func run(_ mode: DeemedBasisMode) throws -> Decimal {
            let b1 = LedgerEvent(
                projectID: projectID, accountID: acc.id,
                timestamp: TaxTime.dateKST(year: 2025, month: 3, day: 1),
                type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: 1, quoteAmountKRW: 40_000_000, sourceKind: "t", rawRef: "r1"
            )
            let b2 = LedgerEvent(
                projectID: projectID, accountID: acc.id,
                timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
                type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: 1, quoteAmountKRW: 80_000_000, sourceKind: "t", rawRef: "r2"
            )
            var policies = PolicyBundle.v1Default
            policies.deemed = MaxBookMarketDeemedPolicy(mode: mode)
            let engine = CostBasisEngine(
                policies: policies, accountsByID: [acc.id: acc],
                fxRates: [:], marketPrices: ["BTC": 60_000_000]
            )
            let replay = try engine.replay(events: [b1, b2], links: [])
            return try XCTUnwrap(replay.deemedPositions.first).totalDeemedKRW
        }
        XCTAssertEqual(try run(.positionAverage), try run(.perLot), "이동평균 계정은 방식 차이가 없다")
    }

    func testPolicyIDReflectsMode() {
        XCTAssertEqual(MaxBookMarketDeemedPolicy(mode: .positionAverage).id, "max_book_market_2026-12-31")
        XCTAssertEqual(MaxBookMarketDeemedPolicy(mode: .perLot).id, "max_lot_market_2026-12-31")
        XCTAssertEqual(DeemedBasisMode.positionAverage.other, .perLot)
    }

    /// 확인 필요 항목이 앱에 실제로 남아 있는지 (사용자 요구)
    func testOpenQuestionsArePresentAndComplete() {
        XCTAssertGreaterThanOrEqual(TaxOpenQuestions.all.count, 18)
        XCTAssertFalse(TaxOpenQuestions.needsConfirmation.isEmpty)
        XCTAssertFalse(TaxOpenQuestions.watchLegislation.isEmpty)
        // 결정한 4개 항목이 목록에 있어야 한다
        let ids = Set(TaxOpenQuestions.all.map(\.id))
        for required in ["TQ-01", "TQ-02", "TQ-03", "TQ-05"] {
            XCTAssertTrue(ids.contains(required), "\(required) 누락")
        }
        // 모든 항목에 질문 문장과 영향 설명이 있어야 한다
        for q in TaxOpenQuestions.all {
            XCTAssertFalse(q.title.isEmpty, "\(q.id) title")
            XCTAssertFalse(q.currentAssumption.isEmpty, "\(q.id) assumption")
            XCTAssertFalse(q.whatToAsk.isEmpty, "\(q.id) question")
            XCTAssertFalse(q.impact.isEmpty, "\(q.id) impact")
        }
        XCTAssertEqual(TaxOpenQuestions.exportLines().count, TaxOpenQuestions.all.count)
    }

    /// 공개 시세 폴백은 기본으로 꺼져 있어야 한다 (TQ-05 결정)
    func testPublicFallbackIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: "fx.allowPublicFallback")
        XCTAssertFalse(FXPreferences.allowPublicFallback)
    }

    /// 기본 의제 방식은 보수적인 평균
    func testDefaultDeemedModeIsConservative() {
        UserDefaults.standard.removeObject(forKey: "deemed.basisMode")
        XCTAssertEqual(DeemedPreferences.basisMode, .positionAverage)
        XCTAssertEqual(PolicyBundle.v1Default.deemed.mode, .positionAverage)
    }
}

/// TQ-02: 총수입금액을 총액 기준으로 통일했는지 (빗썸도 해외와 같은 기준)
final class GrossProceedsBasisTests: XCTestCase {
    func testBithumbSellUsesGrossAmountAndSplitsFee() throws {
        // 거래금액 75,000 / 정산금액 74,850 → 수수료 150
        let text = """
        # date|time|asset|type|qty|price|tradeAmt|settle|memo
        2027-03-01|10:00:00|USDT|매수|10|14000|140000|-140350|지정가
        2027-03-10|12:00:00|USDT|매도|5|15000|75000|74850|시장가
        """
        let projectID = ProjectID()
        let acc = Account.defaults(for: .bithumb, projectID: projectID)
        let result = try BithumbCertificatePDFParser().parse(
            text: text, fileName: "c.txt", projectID: projectID, accountID: acc.id
        )
        let sell = try XCTUnwrap(result.events.first { $0.type == .sell })
        XCTAssertEqual(sell.quoteAmountKRW, 75_000, "양도가액은 수수료 차감 전 총액")
        XCTAssertEqual(sell.feeAmount, 150, "거래금액 − 정산금액 = 수수료")
        XCTAssertEqual(sell.feeAsset?.code, "KRW")

        let buy = try XCTUnwrap(result.events.first { $0.type == .buy })
        XCTAssertEqual(buy.quoteAmountKRW, 140_350, "매수는 정산금액(수수료 포함 총지출) 그대로")
        XCTAssertNil(buy.feeAmount, "매수 수수료는 취득가에 이미 포함")

        // 소득금액은 기준을 바꿔도 같아야 한다: 74,850 − 70,175 = 4,675
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: result.events, links: [])
        let disp = try XCTUnwrap(replay.disposals.first)
        XCTAssertEqual(disp.proceedsKRW, 75_000)
        XCTAssertEqual(disp.feesKRW, 150)
        XCTAssertEqual(disp.costKRW, 70_175, "140,350 × 5/10")
        XCTAssertEqual(disp.pnlKRW, 4_675, "순액 74,850 − 원가 70,175 와 동일")
    }

    /// 거래금액 칸이 비어 있으면 정산금액으로 폴백하고 소득금액은 유지
    func testFallsBackToSettlementWhenGrossMissing() throws {
        let text = """
        2027-03-10|12:00:00|USDT|매도|5|15000||74850|시장가
        """
        let projectID = ProjectID()
        let result = try BithumbCertificatePDFParser().parse(
            text: text, fileName: "c.txt", projectID: projectID, accountID: AccountID()
        )
        let sell = try XCTUnwrap(result.events.first { $0.type == .sell })
        XCTAssertEqual(sell.quoteAmountKRW, 74_850)
        XCTAssertNil(sell.feeAmount)
    }
}
