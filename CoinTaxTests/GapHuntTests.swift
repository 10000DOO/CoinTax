import XCTest
import SwiftData
@testable import CoinTax

/// 2차 전수 점검(빈틈 사냥)에서 찾은 항목의 회귀 테스트.
final class GapHuntTests: XCTestCase {
    private let projectID = ProjectID()

    // MARK: G1 — 유효하지 않은 링크가 입금을 삼키지 않아야 한다

    /// 출금 수량이 0인 링크: 예전에는 입금이 건너뛰기만 되고 입고가 안 돼 **자산이 사라졌다**
    func testZeroQuantityLinkDoesNotSwallowDeposit() throws {
        let dom = Account.defaults(for: .bithumb, projectID: projectID)
        let ovs = Account.defaults(for: .binance, projectID: projectID)
        let w = LedgerEvent(
            projectID: projectID, accountID: dom.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: 0,
            sourceKind: "t", rawRef: "r1"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: ovs.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 2),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 10,
            sourceKind: "t", rawRef: "r2"
        )
        let link = TransferLink(id: LinkID(), projectID: projectID, fromEventID: w.id, toEventID: d.id,
                                status: .confirmed, withdrawnQty: 0, receivedQty: 10)
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: [dom.id: dom, ovs.id: ovs],
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: [w, d], links: [link])
        XCTAssertTrue(replay.issues.contains { $0.id == "V-QTY-03" && $0.severity == "critical" })
        let row = try XCTUnwrap(replay.holdings.rows.first { $0.accountID == ovs.id })
        XCTAssertEqual(row.quantity, 10, "링크가 무효면 입금은 일반 입금으로 남아야 한다 — 사라지면 안 된다")
    }

    /// 링크가 가리키는 출금이 `ignored` 로 제외된 경우도 같은 문제였다
    func testLinkToIgnoredWithdrawalDoesNotSwallowDeposit() throws {
        let dom = Account.defaults(for: .bithumb, projectID: projectID)
        let ovs = Account.defaults(for: .binance, projectID: projectID)
        let w = LedgerEvent(
            projectID: projectID, accountID: dom.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
            type: .ignored, baseAsset: AssetSymbol("USDT"), quantity: -10,
            sourceKind: "t", rawRef: "r1"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: ovs.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 2),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 9.9,
            sourceKind: "t", rawRef: "r2"
        )
        let link = TransferLink(id: LinkID(), projectID: projectID, fromEventID: w.id, toEventID: d.id,
                                status: .confirmed, withdrawnQty: 10, receivedQty: 9.9)
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [dom.id: dom, ovs.id: ovs],
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: [w, d], links: [link])
        XCTAssertTrue(replay.issues.contains { $0.id == "V-QTY-03" })
        let row = try XCTUnwrap(replay.holdings.rows.first { $0.accountID == ovs.id })
        XCTAssertEqual(row.quantity, Decimal(string: "9.9")!)
    }

    // MARK: G2 — 정책이 어떤 입력에도 프로세스를 죽이지 않아야 한다

    func testTransferPolicyDoesNotTrapOnZeroWithdrawn() {
        let r = AbandonLostCostPolicy().apply(
            outboundCostKRW: 140_000, withdrawnQty: 0, receivedQty: 0, explicitFeeCostKRW: 0
        )
        XCTAssertEqual(r.transferredCostKRW, 0)
        XCTAssertEqual(r.abandonedCostKRW, 140_000)
        XCTAssertEqual(r.deductibleExpenseKRW, 0)
        XCTAssertTrue(r.notes.contains("invalid_withdrawn_qty"))
    }

    // MARK: G3 — 의제 시가 자산 코드가 장부 키와 같은 정규화를 거쳐야 한다

    func testMarketPriceLookupUsesNormalizedAssetCode() throws {
        let acc = Account.defaults(for: .binance, projectID: projectID)
        // 이벤트는 별칭 티커(XBT)로 들어온다 → 장부 키는 BTC 로 정규화된다
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
            type: .buy, baseAsset: AssetSymbol("XBT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: "t", rawRef: "r1"
        )
        XCTAssertEqual(buy.baseAsset.code, "BTC")
        // 파이프라인이 정규화하므로 시가 키도 BTC 여야 한다
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: [:], marketPrices: [AssetSymbol(" btc ").code: 60_000_000]
        )
        let replay = try engine.replay(events: [buy], links: [])
        XCTAssertTrue(replay.missingMarketAssets.isEmpty, "공백·별칭 입력도 같은 정규화를 거쳐야 한다")
        XCTAssertEqual(replay.deemedPositions.first?.deemedUnitKRW, 60_000_000)
    }

    // MARK: G4 — 다른 과세연도 처분이 조용히 빠지지 않아야 한다

    func testOtherTaxYearDisposalsAreReported() throws {
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 5),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 2, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "r1"
        )
        let sell2027 = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 60_000_000, sourceKind: "t", rawRef: "r2"
        )
        let sell2028 = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2028, month: 3, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 70_000_000, sourceKind: "t", rawRef: "r3"
        )
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc], fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: [buy, sell2027, sell2028], links: [])
        XCTAssertEqual(replay.disposals.count, 2)

        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        XCTAssertEqual(summary.disposals.count, 1, "리포트는 선택한 해만 보여준다")

        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: [buy, sell2027, sell2028], summaryRerun: summary
        ))
        let notice = report.issues.first { $0.id == "V-TAX-06" }
        XCTAssertNotNil(notice, "다른 연도 처분이 있으면 알려야 한다")
        XCTAssertTrue(notice?.message.contains("2028년 1건") == true)
    }

    // MARK: G5 — 소액 전송(수수료가 1% 초과)도 후보로 제시되어야 한다

    func testSmallTransferWithHighFeeRatioIsStillSuggested() {
        let dom = Account.defaults(for: .bithumb, projectID: projectID)
        let ovs = Account.defaults(for: .binance, projectID: projectID)
        // 10 USDT 출금 → 9 USDT 입금 (수수료 1 USDT = 10%). 문서 05-decisions §7.1 의 예시 그대로.
        let w = LedgerEvent(
            projectID: projectID, accountID: dom.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 10),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -10,
            counterpartyHint: "binance", sourceKind: "t", rawRef: "r1"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: ovs.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 12),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 9,
            sourceKind: "t", rawRef: "r2"
        )
        let engine = TransferMatchingEngine(accountsByID: [dom.id: dom, ovs.id: ovs])
        let cands = engine.suggest(events: [w, d], existing: [])
        XCTAssertEqual(cands.count, 1, "미매칭으로 두면 취득원가가 소멸해 세금이 과대해진다")
        XCTAssertTrue(cands[0].note.contains("확인 필요"), "고신뢰 창 밖이면 표시해야 한다")
    }

    /// 손실률이 지나치게 크면(50% 초과) 후보로 제시하지 않는다
    func testAbsurdLossRatioIsNotSuggested() {
        let dom = Account.defaults(for: .bithumb, projectID: projectID)
        let ovs = Account.defaults(for: .binance, projectID: projectID)
        let w = LedgerEvent(
            projectID: projectID, accountID: dom.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 10),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -100,
            sourceKind: "t", rawRef: "r1"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: ovs.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 12),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 10,
            sourceKind: "t", rawRef: "r2"
        )
        let engine = TransferMatchingEngine(accountsByID: [dom.id: dom, ovs.id: ovs])
        XCTAssertTrue(engine.suggest(events: [w, d], existing: []).isEmpty)
    }

    /// 반올림 차이로 입금이 미세하게 큰 경우도 후보로 잡아야 한다
    func testSlightlyLargerDepositStillMatches() {
        let dom = Account.defaults(for: .bithumb, projectID: projectID)
        let ovs = Account.defaults(for: .binance, projectID: projectID)
        let w = LedgerEvent(
            projectID: projectID, accountID: dom.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 10),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -10,
            sourceKind: "t", rawRef: "r1"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: ovs.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 11),
            type: .deposit, baseAsset: AssetSymbol("USDT"),
            quantity: Decimal(string: "10.0000000001")!, sourceKind: "t", rawRef: "r2"
        )
        let engine = TransferMatchingEngine(accountsByID: [dom.id: dom, ovs.id: ovs])
        XCTAssertEqual(engine.suggest(events: [w, d], existing: []).count, 1)
    }

    // MARK: G6 — 건별 방식에서 채택 근거가 갈리면 그대로 표기

    func testPerLotMixedReasonIsLabelled() throws {
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
        var policies = PolicyBundle.v1Default
        policies.deemed = MaxBookMarketDeemedPolicy(mode: .perLot)
        let engine = CostBasisEngine(
            policies: policies, accountsByID: [acc.id: acc],
            fxRates: [:], marketPrices: ["BTC": 60_000_000]
        )
        let replay = try engine.replay(events: [cheap, pricey], links: [])
        let pos = try XCTUnwrap(replay.deemedPositions.first)
        XCTAssertTrue(pos.reason.hasPrefix("mixed"), "한 lot 은 시가, 한 lot 은 실제원가 → mixed (실제: \(pos.reason))")
        XCTAssertEqual(pos.lotCount, 2)
    }

    // MARK: G7 — 코인으로 낸 수수료는 환율을 요구하지 않는다 (장부 원가를 쓴다)

    @MainActor
    func testCryptoFeeDoesNotRequireFX() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = ProjectEntity(name: "fee-fx", defaultTaxYear: 2027)
        ctx.insert(project)
        let fx = FXService(modelContext: ctx, remoteClient: RemoteFXClientStub())
        let acc = Account.defaults(for: .binance, projectID: ProjectID(project.id))
        // 원화 금액이 이미 있고, 수수료는 USDT 다.
        // 엔진은 USDT 수수료를 **USDT 장부에서 처분**해 장부 원가를 부대비용으로 쓰므로 환율이 필요 없다.
        // 여기서 환율을 요구하면 쓰지도 않는 날짜 때문에 계산이 막힌다.
        let buy = LedgerEvent(
            projectID: ProjectID(project.id), accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000,
            feeAmount: 10, feeAsset: AssetSymbol("USDT"),
            sourceKind: "t", rawRef: "r1"
        )
        XCTAssertEqual(fx.missingDays(for: [buy], project: project), [])

        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc], fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: [buy], links: [])
        XCTAssertFalse(replay.issues.contains { $0.id == "V-FX-01" }, "수수료 때문에 환율 Critical 이 나면 안 된다")
    }

    // MARK: G8 — USDT 수수료가 USDT 장부에서 실제로 빠져야 한다

    func testUSDTFeeReducesUSDTBook() throws {
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let usdtIn = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1_000, quoteAmountKRW: 1_400_000, sourceKind: "t", rawRef: "r0"
        )
        // USDT 로 BTC 를 사면서 수수료도 USDT 로 냈다 → 대금 500 + 수수료 0.5 = 500.5 가 빠져야 한다
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: Decimal(string: "0.005")!, quoteAmount: 500,
            feeAmount: Decimal(string: "0.5")!, feeAsset: AssetSymbol("USDT"),
            sourceKind: "t", rawRef: "r1"
        )
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: [TaxTime.dayKST(buy.timestamp): 1_400], marketPrices: [:]
        )
        let replay = try engine.replay(events: [usdtIn, buy], links: [])
        let usdt = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "USDT" })
        XCTAssertEqual(usdt.quantity, Decimal(string: "499.5")!, "1000 − 500(대금) − 0.5(수수료)")
    }
}


/// 검증기 면제 범위가 자산별로만 적용되는지
final class ShortfallScopeTests: XCTestCase {
    private let projectID = ProjectID()

    /// BTC 에 재고 부족이 있어도 **USDT 의 수량 불일치는 계속 잡아야 한다**
    func testShortfallExemptionIsPerAssetNotGlobal() throws {
        let acc = Account.defaults(for: .binance, projectID: projectID)
        // BTC: 보유 0인데 매도 → 부족
        let btcSell = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 60_000_000, sourceKind: "t", rawRef: "r1"
        )
        // USDT: 정상 매수
        let usdtBuy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 2),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 100, quoteAmountKRW: 140_000, sourceKind: "t", rawRef: "r2"
        )
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc], fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: [btcSell, usdtBuy], links: [])

        // BTC 만 면제 대상이어야 한다
        XCTAssertEqual(replay.shortfallKeys.count, 1)
        XCTAssertTrue(replay.shortfallKeys.contains { $0.hasSuffix("|BTC") })
        XCTAssertFalse(replay.shortfallKeys.contains { $0.hasSuffix("|USDT") })

        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        // USDT 수량은 맞으므로 V-QTY-01 이 뜨면 안 된다
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: [btcSell, usdtBuy], summaryRerun: summary
        ))
        XCTAssertFalse(report.issues.contains { $0.id == "V-QTY-01" })
        XCTAssertTrue(report.issues.contains { $0.id == "V-QTY-02" })

        // 반대로 USDT 수량을 일부러 깨면 잡아야 한다
        var broken = replay
        broken.holdings = HoldingsSnapshot(
            asOf: Date(),
            rows: replay.holdings.rows.map { row in
                guard row.asset.code == "USDT" else { return row }
                var r = row
                r.quantity = 50   // 실제는 100
                return r
            },
            aggregated: replay.holdings.aggregated
        )
        let report2 = Verifier.verify(VerifierInput(
            summary: summary, replay: broken, policies: .v1Default,
            events: [btcSell, usdtBuy], summaryRerun: summary
        ))
        XCTAssertTrue(
            report2.issues.contains { $0.id == "V-QTY-01" && ($0.context ?? "").contains("USDT") },
            "다른 자산의 진짜 불일치는 부족 면제와 무관하게 잡혀야 한다"
        )
    }
}

/// 정책 번들이 한 곳에서만 만들어져 표시와 계산이 어긋나지 않는지 (G9)
@MainActor
final class PolicySingleSourceTests: XCTestCase {

    private func withDeemedMode(_ mode: DeemedBasisMode, _ body: () throws -> Void) rethrows {
        let saved = DeemedPreferences.basisMode
        defer { DeemedPreferences.basisMode = saved }
        DeemedPreferences.basisMode = mode
        try body()
    }

    func testEnvironmentAndPipelineSeeTheSamePolicy() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let env = AppEnvironment(container: container)

        try withDeemedMode(.positionAverage) {
            XCTAssertEqual(env.policies.deemed.mode, .positionAverage)
            XCTAssertEqual(env.pipeline.effectivePolicies.deemed.mode, .positionAverage)
            XCTAssertEqual(env.policies.id, "cointax-v1.2")
        }

        // 설정만 바꿔도 양쪽이 함께 따라와야 한다 (예전에는 파이프라인만 바뀌었다)
        try withDeemedMode(.perLot) {
            XCTAssertEqual(env.policies.deemed.mode, .perLot, "화면이 보는 정책")
            XCTAssertEqual(env.pipeline.effectivePolicies.deemed.mode, .perLot, "계산이 쓰는 정책")
            XCTAssertEqual(env.policies.id, env.pipeline.effectivePolicies.id)
        }
    }

    /// 기본값이 아닌 정책은 번들 id 로 구분되어야 한다 (감사 추적)
    func testNonDefaultPolicyBumpsBundleID() throws {
        try withDeemedMode(.positionAverage) {
            XCTAssertEqual(PolicyBundle.current.id, "cointax-v1.2", "기본값은 id 를 바꾸지 않는다")
        }
        try withDeemedMode(.perLot) {
            XCTAssertEqual(PolicyBundle.current.id, "cointax-v1.2+deemed_perLot")
            XCTAssertNotEqual(PolicyBundle.current.id, PolicyBundle.v1Default.id,
                              "과거 스냅샷과 구분되어야 어떤 정책으로 계산했는지 답할 수 있다")
        }
        // v1Default 자체는 잠금값이므로 변하지 않는다
        XCTAssertEqual(PolicyBundle.v1Default.id, "cointax-v1.2")
        XCTAssertEqual(PolicyBundle.v1Default.deemed.mode, .positionAverage)
    }

    /// 검증기는 요약의 정책 id 와 실제 정책이 일치하는지 본다 — id bump 후에도 통과해야 한다
    func testVerifierAcceptsBumpedBundleID() throws {
        try withDeemedMode(.perLot) {
            let policies = PolicyBundle.current
            let summary = TaxYearSummary(
                projectID: ProjectID(), taxYear: 2027, status: .draft,
                policyBundleID: policies.id,
                totalProceedsKRW: 0, totalCostsKRW: 0, netIncomeKRW: 0, basicDeductionKRW: 2_500_000,
                taxBaseKRW: 0, nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
                abandonedTransferCostKRW: 0, disposals: [], deemed: [],
                disclaimers: policies.disclaimers, calculatedAt: Date(), verification: nil
            )
            let replay = ReplayResult(
                disposals: [], holdings: HoldingsBuilder.empty(), deemedPositions: [],
                abandonedTotal: 0, extraDeductible: 0, warnings: [], transferCostDetails: [],
                missingMarketAssets: [], missingFXDays: [], fxResolutions: []
            )
            let report = Verifier.verify(VerifierInput(
                summary: summary, replay: replay, policies: policies, events: [], summaryRerun: summary
            ))
            XCTAssertFalse(report.issues.contains { $0.id == "V-POL-01" && $0.severity == "critical" })
        }
    }
}
