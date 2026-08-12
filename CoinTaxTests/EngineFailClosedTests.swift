import XCTest
@testable import CoinTax

/// 리뷰 1-2 / 1-7 / 1-8 / 1-6 회귀 테스트
/// 엔진은 예외로 계산을 중단하지 않고, 문제를 Critical 이슈로 보고해야 한다 (06-integrity fail-closed).
final class EngineFailClosedTests: XCTestCase {

    private func engine(
        accounts: [Account],
        fx: [String: Decimal] = [:],
        market: [String: Decimal] = [:]
    ) -> CostBasisEngine {
        CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) }),
            fxRates: fx,
            marketPrices: market
        )
    }

    // MARK: 1-7 재고 부족

    func testOversellReportsCriticalInsteadOfThrowing() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let sell = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 80_000_000, sourceKind: "t"
        )
        // 보유 0인데 1 BTC 매도 → 예외 없이 이슈로 보고되어야 한다
        let replay = try engine(accounts: [acc]).replay(events: [sell], links: [])
        XCTAssertEqual(replay.disposals.count, 1, "처분 기록은 남는다")
        XCTAssertTrue(replay.issues.contains { $0.id == "V-QTY-02" && $0.severity == "critical" })

        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0, deemed: [], policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default, events: [sell], summaryRerun: summary
        ))
        XCTAssertEqual(report.status, "failed")
        XCTAssertFalse(report.isExportAllowed, "fail-closed: 내보내기 잠금")
    }

    /// 미매칭 출금으로 재고가 빈 뒤 매도가 오는 실제 시나리오 (저장소 빗썸 샘플과 동일 구조)
    func testUnmatchedWithdrawThenSellDoesNotAbortCalculation() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .bithumb, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 5),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10, quoteAmountKRW: 140_000, sourceKind: "t", rawRef: "row1"
        )
        let out = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 6),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"),
            quantity: -10, sourceKind: "t", rawRef: "row2"
        )
        let sell = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            type: .sell, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: -5, quoteAmountKRW: 75_000, sourceKind: "t", rawRef: "row3"
        )
        let replay = try engine(accounts: [acc]).replay(events: [buy, out, sell], links: [])
        XCTAssertEqual(replay.abandonedTotal, 140_000, "미매칭 출금 원가는 소멸")
        XCTAssertEqual(replay.disposals.count, 1)
        XCTAssertEqual(replay.disposals[0].costKRW, 0, "재고가 없으므로 원가 0")
        XCTAssertTrue(replay.issues.contains { $0.id == "V-QTY-02" && $0.severity == "critical" })
    }

    // MARK: 1-2 코인 견적 환산

    func testCoinQuotedTradeIsNotConvertedWithUSDRate() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let day = TaxTime.dateKST(year: 2027, month: 4, day: 1)
        // ETH/BTC 매수 — 0.5 BTC 지불. USD 환율을 곱하면 "0.5 × 1400 = 700원"이라는 엉뚱한 값이 된다.
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id, timestamp: day,
            type: .buy, baseAsset: AssetSymbol("ETH"), quoteAsset: AssetSymbol("BTC"),
            quantity: 10, price: Decimal(string: "0.05"), quoteAmount: Decimal(string: "0.5"),
            sourceKind: "t"
        )
        let replay = try engine(accounts: [acc], fx: [TaxTime.dayKST(day): 1400], market: ["ETH": 1])
            .replay(events: [buy], links: [])
        XCTAssertTrue(
            replay.issues.contains { $0.id == "V-FX-01" && $0.severity == "critical" && $0.message.contains("BTC") },
            "환산 근거가 없으면 추정하지 말고 Critical로 보고"
        )
        let row = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "ETH" })
        XCTAssertEqual(row.totalCostKRW, 0, "임의 환산값을 넣지 않는다")
    }

    // MARK: 1-8 과세 대상 아닌 **원화 마켓** 처분은 환율을 요구하지 않는다

    func testPreTaxEraKRWMarketSellDoesNotRequireFX() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .bithumb, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2025, month: 6, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 2, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "r1"
        )
        // 2026년 원화 매도 — 과세 집계 대상이 아니고 원화라 환율이 아예 필요 없다
        let oldSell = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 60_000_000, sourceKind: "t", rawRef: "r2"
        )
        let replay = try engine(accounts: [acc], market: ["BTC": 60_000_000]).replay(events: [buy, oldSell], links: [])
        XCTAssertTrue(replay.missingFXDays.isEmpty, "과세 대상 아닌 원화 처분에 환율을 요구하지 않는다")
        XCTAssertTrue(replay.disposals.isEmpty)
        XCTAssertFalse(replay.issues.contains { $0.id == "V-FX-01" })
        // 남은 1 BTC 는 의제 적용을 받는다
        XCTAssertEqual(replay.deemedPositions.first?.deemedUnitKRW, 60_000_000)
    }

    /// 반대로 **코인↔코인** 처분은 과세 시작 전이라도 환율이 필요하다.
    /// 받은 USDT 의 취득원가가 그 시점 원화가액이고, 그 원가가 2027년 이후 손익의 출발점이 된다.
    /// 환율 없이 0원으로 두면 나중에 USDT 를 팔 때 전액이 이익으로 잡힌다.
    func testPreTaxEraCryptoQuoteSellRequiresFX() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2025, month: 6, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 2, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "r1"
        )
        let sellForUSDT = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: -1, price: 60_000, quoteAmount: 60_000, sourceKind: "t", rawRef: "r2"
        )
        let noFX = try engine(accounts: [acc], market: ["BTC": 60_000_000, "USDT": 1_400])
            .replay(events: [buy, sellForUSDT], links: [])
        XCTAssertEqual(noFX.missingFXDays, ["2026-06-01"], "코인↔코인 처분은 과세 전이라도 환율이 필요하다")
        XCTAssertTrue(noFX.issues.contains { $0.id == "V-FX-01" && $0.severity == "critical" })
        // 환율이 없어 USDT 를 입고하지 못했으면 수량 대조에서 그 자산을 빼야 한다.
        // 그러지 않으면 검증기가 수량 불일치를 덧붙여 진짜 원인을 가린다.
        XCTAssertTrue(noFX.shortfallKeys.contains { $0.hasSuffix("|USDT") })

        // 환율이 있으면 USDT 가 원화가액으로 입고된다
        let withFX = try engine(
            accounts: [acc],
            fx: ["2026-06-01": 1_400],
            market: ["BTC": 60_000_000, "USDT": 1_400]
        ).replay(events: [buy, sellForUSDT], links: [])
        XCTAssertTrue(withFX.missingFXDays.isEmpty)
        let usdt = try XCTUnwrap(withFX.holdings.rows.first { $0.asset.code == "USDT" })
        XCTAssertEqual(usdt.quantity, 60_000, "받은 USDT 가 장부에 들어와야 한다")
        XCTAssertEqual(usdt.totalCostKRW, 84_000_000, "60,000 USDT × 1,400원")
    }

    /// 코인으로 코인을 사면 쓴 코인이 장부에서 빠지고 그 처분이 손익으로 잡힌다.
    func testBuyWithCryptoQuoteDisposesQuoteAsset() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: projectID)
        // 2027년 USDT 취득 (1,300원) → 같은 해 1,400원 시점에 BTC 로 교환
        let usdtIn = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10_000, quoteAmountKRW: 13_000_000, sourceKind: "t", rawRef: "r1"
        )
        let swap = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: 1, price: 10_000, quoteAmount: 10_000, sourceKind: "t", rawRef: "r2"
        )
        let replay = try engine(accounts: [acc], fx: ["2027-03-01": 1_400]).replay(events: [usdtIn, swap], links: [])

        XCTAssertNil(replay.holdings.rows.first { $0.asset.code == "USDT" }, "USDT 를 다 썼으면 잔고가 남지 않는다")
        let btc = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "BTC" })
        XCTAssertEqual(btc.totalCostKRW, 14_000_000, "10,000 USDT × 1,400원이 BTC 취득가")

        let usdtDisposal = try XCTUnwrap(replay.disposals.first { $0.asset.code == "USDT" })
        XCTAssertEqual(usdtDisposal.proceedsKRW, 14_000_000)
        XCTAssertEqual(usdtDisposal.costKRW, 13_000_000)
        XCTAssertEqual(usdtDisposal.pnlKRW, 1_000_000, "USDT 환차익 100만원이 인식된다")
    }

    // MARK: 1-6 링크 중복

    func testDuplicateLinkToSameDepositIsCritical() throws {
        let projectID = ProjectID()
        let dom = Account.defaults(for: .bithumb, projectID: projectID)
        let ovs = Account.defaults(for: .binance, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: dom.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 20, quoteAmountKRW: 280_000, sourceKind: "t", rawRef: "r1"
        )
        let w1 = LedgerEvent(
            projectID: projectID, accountID: dom.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 2, hour: 9),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -10, sourceKind: "t", rawRef: "r2"
        )
        let w2 = LedgerEvent(
            projectID: projectID, accountID: dom.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 2, hour: 10),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -10, sourceKind: "t", rawRef: "r3"
        )
        let dep = LedgerEvent(
            projectID: projectID, accountID: ovs.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 2, hour: 11),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 9.9, sourceKind: "t", rawRef: "r4"
        )
        let l1 = TransferLink(id: LinkID(), projectID: projectID, fromEventID: w1.id, toEventID: dep.id,
                              status: .confirmed, withdrawnQty: 10, receivedQty: 9.9)
        let l2 = TransferLink(id: LinkID(), projectID: projectID, fromEventID: w2.id, toEventID: dep.id,
                              status: .confirmed, withdrawnQty: 10, receivedQty: 9.9)
        let replay = try engine(accounts: [dom, ovs]).replay(events: [buy, w1, w2, dep], links: [l1, l2])
        XCTAssertTrue(replay.issues.contains { $0.id == "V-QTY-04" && $0.severity == "critical" })
        XCTAssertEqual(replay.transferCostDetails.count, 1, "한 입금에 원가를 두 번 넣지 않는다")
        let row = try XCTUnwrap(replay.holdings.rows.first { $0.accountID == ovs.id })
        XCTAssertEqual(row.quantity, Decimal(string: "9.9"), "입금 수량이 두 배가 되면 안 된다")
    }

    // MARK: 1-9 제3자산(BNB) 수수료

    func testThirdAssetFeeConsumesItsOwnBook() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let day = TaxTime.dateKST(year: 2027, month: 5, day: 1)
        let bnbBuy = LedgerEvent(
            projectID: projectID, accountID: acc.id, timestamp: day,
            type: .buy, baseAsset: AssetSymbol("BNB"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 700_000, sourceKind: "t", rawRef: "r1"
        )
        let btcBuy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 2),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 100_000_000,
            feeAmount: Decimal(string: "0.1"), feeAsset: AssetSymbol("BNB"),
            sourceKind: "t", rawRef: "r2"
        )
        let replay = try engine(accounts: [acc]).replay(events: [bnbBuy, btcBuy], links: [])
        let btc = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "BTC" })
        XCTAssertEqual(btc.totalCostKRW, 100_070_000, "BNB 0.1개 장부원가 70,000원이 취득 부대비용에 가산")
        let bnb = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "BNB" })
        XCTAssertEqual(bnb.quantity, Decimal(string: "0.9"), "수수료로 쓴 BNB는 장부에서 빠진다")
    }
}
