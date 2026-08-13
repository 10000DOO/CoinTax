import XCTest
@testable import CoinTax

/// **손으로 먼저 답을 낸 뒤** 엔진에게 물어보는 검사 (5차 감사).
///
/// 기존 테스트는 대부분 「엔진이 낸 값」을 정답으로 박아 두었다. 그러면 엔진과 테스트가
/// 같은 오해를 공유해도 사이좋게 통과한다 (사용자 지적 · 감사 반복 원인 #2).
/// 여기 있는 숫자는 전부 세법 규칙(이동평균/선입선출 · 의제 max · 250만 공제 · 20%+2%)으로
/// **주석에 계산 과정을 적어 가며 손으로** 낸 값이다. 엔진이 다르면 엔진이 틀린 것이다.
final class OracleTaxPathTests: XCTestCase {

    private func aggregate(_ replay: ReplayResult, _ policies: PolicyBundle, year: Int, projectID: ProjectID) -> TaxYearSummary {
        TaxAggregator.aggregate(
            projectID: projectID,
            disposals: replay.disposals,
            taxYear: year,
            extraDeductible: replay.extraDeductibleByYear[year] ?? 0,
            abandonedTransferCostKRW: replay.abandonedByYear[year] ?? 0,
            deemed: replay.deemedPositions,
            policies: policies
        )
    }

    // MARK: - A. 빗썸(이동평균) → 의제 → 2027 매도

    /// 손계산:
    ///   2026-03-01 BTC 1 매수 5,000만  → 수량 1, 원가 5,000만
    ///   2026-06-01 BTC 1 매수 7,000만  → 수량 2, 원가 1.2억, 평단 6,000만 (이동평균)
    ///   2027-01-01 0시 시가 8,000만    → 의제단가 = max(6,000만, 8,000만) = 8,000만
    ///                                    장부 = 2 × 8,000만 = 1.6억
    ///   2027-05-01 BTC 1 매도 9,000만  → 양도 9,000만 − 취득 8,000만 = 소득 1,000만
    ///   과세표준 = 1,000만 − 250만 = 750만
    ///   국세 750만×20% = 150만 / 지방 750만×2% = 15만 / 합계 165만
    func testA_bithumbMovingAverage_deemed_then2027Sell() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)

        func buy(_ month: Int, _ krw: Decimal) -> LedgerEvent {
            LedgerEvent(
                projectID: projectID, accountID: bithumb.id,
                timestamp: TaxTime.dateKST(year: 2026, month: month, day: 1, hour: 10),
                type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: 1, quoteAmountKRW: krw, sourceKind: "test"
            )
        }
        let sell = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 1, hour: 10),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 90_000_000, sourceKind: "test"
        )
        let events = [buy(3, 50_000_000), buy(6, 70_000_000), sell]

        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: [bithumb.id: bithumb],
            fxRates: [:],
            marketPrices: ["BTC": 80_000_000]
        )
        let replay = try engine.replay(events: events, links: [])

        let dem = try XCTUnwrap(replay.deemedPositions.first)
        XCTAssertEqual(dem.quantity, 2)
        XCTAssertEqual(dem.bookUnitKRW, 60_000_000)
        XCTAssertEqual(dem.deemedUnitKRW, 80_000_000, "의제단가 = max(장부 6,000만, 시가 8,000만)")
        XCTAssertEqual(dem.reason, "market")

        let d = try XCTUnwrap(replay.disposals.first)
        XCTAssertEqual(d.costKRW, 80_000_000, "의제 재기동 후 1개 출고 원가")
        XCTAssertEqual(d.pnlKRW, 10_000_000)

        let s = aggregate(replay, policies, year: 2027, projectID: projectID)
        XCTAssertEqual(s.netIncomeKRW, 10_000_000)
        XCTAssertEqual(s.taxBaseKRW, 7_500_000)
        XCTAssertEqual(s.nationalTaxKRW, 1_500_000)
        XCTAssertEqual(s.localTaxKRW, 150_000)
        XCTAssertEqual(s.totalTaxKRW, 1_650_000)
    }

    // MARK: - B. 바이낸스(선입선출) → 의제 두 방식 → 2027 부분 매도

    /// 손계산 (lot: 2개@300만, 3개@400만 → 총 5개 / 1,800만 / 평단 360만, 시가 350만):
    ///   평균 방식: 의제단가 = max(360만, 350만) = 360만  → 장부 5 × 360만 = 1,800만
    ///     2027 4개 매도 2,000만 → 취득 4×360만 = 1,440만 → 소득 560만
    ///     과표 310만 → 국세 62만 / 지방 6.2만 / 합계 68.2만
    ///   건별 방식: lot1 max(300만,350만)=350만, lot2 max(400만,350만)=400만
    ///     장부 = 2×350만 + 3×400만 = 1,900만
    ///     2027 4개 매도(FIFO) → 2×350만 + 2×400만 = 1,500만 → 소득 500만
    ///     과표 250만 → 국세 50만 / 지방 5만 / 합계 55만
    func testB_binanceFIFO_deemedBothModes() throws {
        let projectID = ProjectID()
        let binance = Account.defaults(for: .binance, projectID: projectID)

        func buy(_ month: Int, _ qty: Decimal, _ krw: Decimal) -> LedgerEvent {
            LedgerEvent(
                projectID: projectID, accountID: binance.id,
                timestamp: TaxTime.dateKST(year: 2026, month: month, day: 1, hour: 10),
                type: .buy, baseAsset: AssetSymbol("ETH"), quoteAsset: AssetSymbol("KRW"),
                quantity: qty, quoteAmountKRW: krw, sourceKind: "test"
            )
        }
        let sell = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1, hour: 10),
            type: .sell, baseAsset: AssetSymbol("ETH"), quoteAsset: AssetSymbol("KRW"),
            quantity: -4, quoteAmountKRW: 20_000_000, sourceKind: "test"
        )
        let events = [buy(2, 2, 6_000_000), buy(5, 3, 12_000_000), sell]

        // 평균 방식 (기본)
        var policies = PolicyBundle.v1Default
        var engine = CostBasisEngine(
            policies: policies, accountsByID: [binance.id: binance],
            fxRates: [:], marketPrices: ["ETH": 3_500_000]
        )
        var replay = try engine.replay(events: events, links: [])
        var dem = try XCTUnwrap(replay.deemedPositions.first)
        XCTAssertEqual(dem.deemedUnitKRW, 3_600_000, "평균 방식: max(평단 360만, 시가 350만)")
        XCTAssertEqual(dem.reason, "actual")
        var s = aggregate(replay, policies, year: 2027, projectID: projectID)
        XCTAssertEqual(s.totalCostsKRW, 14_400_000)
        XCTAssertEqual(s.netIncomeKRW, 5_600_000)
        XCTAssertEqual(s.taxBaseKRW, 3_100_000)
        XCTAssertEqual(s.totalTaxKRW, 682_000)

        // 「건별 방식」 비교는 폐지됐다 — `[영]` §88① 이 거주자별 총평균법이 되면서
        // 매입 건(lot) 개념이 사라졌다 (작업문서 Q1). 위 평균 방식이 유일한 계산이다.
        XCTAssertEqual(dem.lotCount, 1)
        XCTAssertEqual(replay.deemedPositions.count, 1)
    }

    // MARK: - C. 코인↔코인 교환 (환율 경유) — 양쪽 leg

    /// 손계산 (USD/KRW = 1,400, 시가 USDT = 1,350원):
    ///   2026-11-01 USDT 1,000 취득 1,300,000원 (단가 1,300)
    ///   의제단가 = max(1,300, 1,350) = 1,350 → 장부 1,000 × 1,350 = 1,350,000
    ///   2027-02-10 BTC 0.01 을 USDT 500 으로 매수 (price 50,000 USDT/BTC)
    ///     USDT leg: 양도 500 × 1,400 = 700,000 / 취득 500 × 1,350 = 675,000 → 소득 25,000
    ///     BTC 취득원가 = 700,000
    ///   2027-03-15 BTC 0.01 매도 800,000원 → 소득 100,000
    ///   합계 소득 125,000 (< 250만) → 세액 0
    func testC_coinToCoin_bothLegs_withFX() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let binance = Account.defaults(for: .binance, projectID: projectID)

        let acquire = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 11, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1_000, quoteAmountKRW: 1_300_000, sourceKind: "test"
        )
        let swap = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 10, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: Decimal(string: "0.01")!, price: 50_000, quoteAmount: 500, sourceKind: "test"
        )
        let sell = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 15, hour: 10),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: Decimal(string: "-0.01")!, quoteAmountKRW: 800_000, sourceKind: "test"
        )

        let engine = CostBasisEngine(
            policies: policies, accountsByID: [binance.id: binance],
            fxRates: ["2027-02-10": 1_400],
            marketPrices: ["USDT": 1_350]
        )
        let replay = try engine.replay(events: [acquire, swap, sell], links: [])

        let usdtLeg = try XCTUnwrap(replay.disposals.first { $0.asset.code == "USDT" })
        XCTAssertEqual(usdtLeg.proceedsKRW, 700_000)
        XCTAssertEqual(usdtLeg.costKRW, 675_000)
        XCTAssertEqual(usdtLeg.pnlKRW, 25_000)

        let btcLeg = try XCTUnwrap(replay.disposals.first { $0.asset.code == "BTC" })
        XCTAssertEqual(btcLeg.costKRW, 700_000, "USDT 로 산 BTC 의 취득원가는 그 시점 원화가액")
        XCTAssertEqual(btcLeg.pnlKRW, 100_000)

        let s = aggregate(replay, policies, year: 2027, projectID: projectID)
        XCTAssertEqual(s.netIncomeKRW, 125_000)
        XCTAssertEqual(s.taxBaseKRW, 0)
        XCTAssertEqual(s.totalTaxKRW, 0)
    }

    // MARK: - D. 연말을 걸치는 전송 (의제 사각지대)

    /// 손계산:
    ///   2026-06-01 빗썸 USDT 10 매수 13,000원 (단가 1,300)
    ///   2026-12-31 23:00 출금 10 → 2027-01-02 01:00 바이낸스 입금 9.9
    ///   과세 시작 시점에 어느 장부에도 없다 → 의제 대상 0건 + 경고
    ///   입고 원가 = 13,000 × (9.9/10) = 12,870
    ///   2027-06-01 9.9 매도 20,000원 → 소득 20,000 − 12,870 = 7,130
    func testD_transferAcrossYearEnd_missesDeemed_butWarns() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)
        let binance = Account.defaults(for: .binance, projectID: projectID)

        let buy = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10, quoteAmountKRW: 13_000, sourceKind: "test"
        )
        let w = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 12, day: 31, hour: 23),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -10, sourceKind: "test"
        )
        let d = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2, hour: 1),
            type: .deposit, baseAsset: AssetSymbol("USDT"),
            quantity: Decimal(string: "9.9")!, sourceKind: "test"
        )
        let sell = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1, hour: 10),
            type: .sell, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: Decimal(string: "-9.9")!, quoteAmountKRW: 20_000, sourceKind: "test"
        )
        let link = TransferLink(
            id: LinkID(), projectID: projectID, fromEventID: w.id, toEventID: d.id,
            status: .confirmed, withdrawnQty: 10, receivedQty: Decimal(string: "9.9")!
        )

        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: [bithumb.id: bithumb, binance.id: binance],
            fxRates: [:], marketPrices: ["USDT": 1_500]
        )
        let replay = try engine.replay(events: [buy, w, d, sell], links: [link])

        XCTAssertTrue(replay.deemedPositions.isEmpty, "이동 중이라 의제 대상이 없다")
        XCTAssertTrue(replay.issues.contains { $0.id == "V-DEM-05" }, "사용자에게 반드시 알려야 한다")

        let disp = try XCTUnwrap(replay.disposals.first)
        XCTAssertEqual(disp.costKRW, 12_870)
        XCTAssertEqual(disp.pnlKRW, 7_130)
    }

    // MARK: - E. 손실만 난 해 → 다음 해 이익 (이월 금지)

    /// 손계산:
    ///   2027: 5,000만에 산 것을 4,000만에 매도 → 소득 −1,000만 → 과표 0, 세액 0
    ///   2028: 3,000만에 산 것을 4,000만에 매도 → 소득 +1,000만
    ///         **이월 없음** → 과표 = 1,000만 − 250만 = 750만 → 세액 165만
    func testE_lossYearDoesNotCarryForward() throws {
        let policies = PolicyBundle.v1Default
        let projectID = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)

        func trade(_ year: Int, _ month: Int, _ type: EventType, _ qty: Decimal, _ krw: Decimal) -> LedgerEvent {
            LedgerEvent(
                projectID: projectID, accountID: bithumb.id,
                timestamp: TaxTime.dateKST(year: year, month: month, day: 1, hour: 10),
                type: type, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: qty, quoteAmountKRW: krw, sourceKind: "test"
            )
        }
        let events = [
            trade(2027, 1, .buy, 1, 50_000_000),
            trade(2027, 6, .sell, -1, 40_000_000),
            trade(2028, 1, .buy, 1, 30_000_000),
            trade(2028, 6, .sell, -1, 40_000_000)
        ]
        let engine = CostBasisEngine(
            policies: policies, accountsByID: [bithumb.id: bithumb],
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: events, links: [])

        let s27 = aggregate(replay, policies, year: 2027, projectID: projectID)
        XCTAssertEqual(s27.netIncomeKRW, -10_000_000)
        XCTAssertEqual(s27.taxBaseKRW, 0)
        XCTAssertEqual(s27.totalTaxKRW, 0)

        let s28 = aggregate(replay, policies, year: 2028, projectID: projectID)
        XCTAssertEqual(s28.netIncomeKRW, 10_000_000, "전년 손실은 이월되지 않는다")
        XCTAssertEqual(s28.taxBaseKRW, 7_500_000)
        XCTAssertEqual(s28.totalTaxKRW, 1_650_000)
    }

    // MARK: - F. 기본공제 경계

    func testF_basicDeductionBoundary() {
        let p = KROtherIncomeTaxRatePolicy()
        let r = StatutoryKRWRoundingPolicy()

        let exact = p.compute(incomeKRW: 2_500_000, rounding: r)
        XCTAssertEqual(exact.taxBaseKRW, 0)
        XCTAssertEqual(exact.totalTaxKRW, 0)

        // 과세표준 10원 → 국세 2원·지방세 0.2원. 둘 다 **10원 미만이라 버려져 0** 이 된다
        // (국고금 관리법 §47① · 지방세기본법 §59). 예전에는 반올림해 2원이 남았다.
        let overByTen = p.compute(incomeKRW: 2_500_010, rounding: r)
        XCTAssertEqual(overByTen.taxBaseKRW, 10)
        XCTAssertEqual(overByTen.nationalTaxKRW, 0)
        XCTAssertEqual(overByTen.localTaxKRW, 0)

        let negative = p.compute(incomeKRW: -1, rounding: r)
        XCTAssertEqual(negative.taxBaseKRW, 0)
        XCTAssertEqual(negative.totalTaxKRW, 0)
    }

    // MARK: - G. 끝수 계산 (국고금 관리법 §47 · 지방세기본법 §59)

    /// 손계산으로 고정한다. 국세와 지방세를 **각각** 10원 버림해야 하고,
    /// 합계를 절사하면 국세청 계산과 어긋난다.
    func testG_statutoryRounding() {
        let p = KROtherIncomeTaxRatePolicy()
        let r = StatutoryKRWRoundingPolicy()

        // 소득 12,345,678.9 → 과세표준 9,845,678.9 → **1원 미만 버림** → 9,845,678
        let s = p.compute(incomeKRW: Decimal(string: "12345678.9")!, rounding: r)
        XCTAssertEqual(s.taxBaseKRW, 9_845_678, "과세표준은 1원 미만을 버린다 (§47②)")

        // 국세 9,845,678 × 20% = 1,969,135.6 → 10원 버림 → 1,969,130
        XCTAssertEqual(s.nationalTaxKRW, 1_969_130)
        // 지방세 9,845,678 × 2% = 196,913.56 → 10원 버림 → 196,910
        XCTAssertEqual(s.localTaxKRW, 196_910)
        XCTAssertEqual(s.totalTaxKRW, 2_166_040)

        // 합쳐서 절사했다면 2,166,049.16 → 2,166,040 으로 **우연히 같아지는** 구간이 있다.
        // 각각 절사가 달라지는 값으로 한 번 더 고정한다.
        //   과세표준 1,000,009 → 국세 200,001.8 → 200,000 / 지방세 20,000.18 → 20,000
        //   합산 후 절사였다면 220,001.98 → 220,000 (같음). 아래는 갈리는 값이다.
        //   과세표준 3,500,049 → 국세 700,009.8 → 700,000 / 지방세 70,000.98 → 70,000 → 합 770,000
        //   합산 후 절사: 770,010.78 → 770,010  ← 10원 차이
        let split = p.compute(incomeKRW: 2_500_000 + 3_500_049, rounding: r)
        XCTAssertEqual(split.taxBaseKRW, 3_500_049)
        XCTAssertEqual(split.nationalTaxKRW, 700_000)
        XCTAssertEqual(split.localTaxKRW, 70_000)
        XCTAssertEqual(split.totalTaxKRW, 770_000, "각각 절사한 합이어야 한다 (합산 후 절사면 770,010)")
    }
}
