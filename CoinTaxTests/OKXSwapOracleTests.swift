import XCTest
@testable import CoinTax

/// 코인↔코인 교환과 **거래소 안 내부 이동**이 섞인 경로를 손계산과 대조한다 (5차 감사 회차 32).
///
/// 이 조합에서만 나타나는 것들:
///   ① 코인끼리 바꾸면 **양쪽 다** 움직인다 — 받는 코인 취득 + 주는 코인 처분
///   ② 그 처분의 양도가액·취득가액은 **그날 환율**로 정해진다 (날마다 다르다)
///   ③ 펀딩↔거래 계정 이동(`transferInternal`)은 **장부를 건드리면 안 된다** (같은 계정·같은 자산)
///   ④ 그 전에 2027-01-01 의제 재기동이 한 번 끼어든다
final class OKXSwapOracleTests: XCTestCase {

    /// 손계산 (03-tax-rules §2.3 의 표시 예시와 같은 자릿수로 맞췄다)
    /// ```text
    /// 2026-11-01 빗썸 USDT 100,000 매수 1.3억          → 단가 1,300
    /// 2026-12-01 빗썸 → OKX 전송 100,000 (수수료 0)     → OKX 100,000 @1,300
    /// 2027-01-01 0시 시가 1,400 → 의제 max(1300,1400)  → OKX 100,000 @1,400 (1.4억)
    /// 2027-03-01 OKX 내부 이동 50,000 (펀딩→거래)       → 장부 불변
    /// 2027-03-02 BTC 1 을 USDT 50,000 으로 매수 (환율 1,450)
    ///     USDT 처분: 양도 50,000×1,450 = 7,250만 / 취득 50,000×1,400 = 7,000만 → 소득  250만
    ///     BTC 취득원가 = 7,250만
    /// 2027-04-01 BTC 1 매도 → USDT 60,000 (환율 1,500)
    ///     BTC  처분: 양도 60,000×1,500 = 9,000만 / 취득 7,250만          → 소득 1,750만
    ///     USDT 60,000 입고 @9,000만 (단가 1,500)
    /// 소득 합계 2,000만 → 과세표준 1,750만
    /// 국세 350만 · 지방세 35만 · 합계 385만
    /// 남은 USDT = 100,000 − 50,000 + 60,000 = 110,000
    /// ```
    func testCoinSwapWithInternalTransferAcrossTaxStart() throws {
        let pid = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: pid)
        let okx = Account.defaults(for: .okx, projectID: pid)

        let buy = LedgerEvent(
            projectID: pid, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 11, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 100_000, quoteAmountKRW: 130_000_000, sourceKind: "oracle", rawRef: "r1"
        )
        let out = LedgerEvent(
            projectID: pid, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 12, day: 1, hour: 10),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -100_000,
            sourceKind: "oracle", rawRef: "r2"
        )
        let into = LedgerEvent(
            projectID: pid, accountID: okx.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 12, day: 1, hour: 12),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 100_000,
            sourceKind: "oracle", rawRef: "r3"
        )
        // 펀딩 → 거래 계정 (같은 OKX 계정 안의 이동) — 장부를 건드리면 안 된다
        let internalMove = LedgerEvent(
            projectID: pid, accountID: okx.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1, hour: 10),
            type: .transferInternal, baseAsset: AssetSymbol("USDT"), quantity: -50_000,
            sourceKind: "oracle", rawRef: "r4"
        )
        // USDT 로 BTC 를 산다 → BTC 취득 + USDT 처분
        let swapIn = LedgerEvent(
            projectID: pid, accountID: okx.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 2, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: 1, price: 50_000, quoteAmount: 50_000, sourceKind: "oracle", rawRef: "r5"
        )
        // BTC 를 팔아 USDT 를 받는다 → BTC 처분 + USDT 취득
        let swapOut = LedgerEvent(
            projectID: pid, accountID: okx.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 4, day: 1, hour: 10),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: -1, price: 60_000, quoteAmount: 60_000, sourceKind: "oracle", rawRef: "r6"
        )
        let link = TransferLink(
            id: LinkID(), projectID: pid, fromEventID: out.id, toEventID: into.id,
            status: .confirmed, withdrawnQty: 100_000, receivedQty: 100_000
        )

        let replay = try CostBasisEngine(
            policies: .v1Default,
            accountsByID: [bithumb.id: bithumb, okx.id: okx],
            fxRates: ["2027-03-02": 1_450, "2027-04-01": 1_500],
            marketPrices: ["USDT": 1_400]
        ).replay(events: [buy, out, into, internalMove, swapIn, swapOut], links: [link])

        // 의제: OKX 에 USDT 100,000 이 단가 1,400 으로 재기동 (빗썸은 비어 있다)
        XCTAssertEqual(replay.deemedPositions.count, 1)
        let dem = try XCTUnwrap(replay.deemedPositions.first)
        XCTAssertEqual(dem.asset.code, "USDT")
        XCTAssertEqual(dem.quantity, 100_000)
        XCTAssertEqual(dem.deemedUnitKRW, 1_400, "max(장부 1,300 · 시가 1,400)")
        XCTAssertEqual(dem.totalDeemedKRW, 140_000_000)

        // 처분 두 건 — USDT leg 과 BTC
        let usdtLeg = try XCTUnwrap(replay.disposals.first { $0.asset.code == "USDT" })
        XCTAssertEqual(usdtLeg.proceedsKRW, 72_500_000, "50,000 × 1,450")
        XCTAssertEqual(usdtLeg.costKRW, 70_000_000, "50,000 × 1,400 (의제 단가)")
        XCTAssertEqual(usdtLeg.pnlKRW, 2_500_000)

        let btcLeg = try XCTUnwrap(replay.disposals.first { $0.asset.code == "BTC" })
        XCTAssertEqual(btcLeg.costKRW, 72_500_000, "USDT 로 산 BTC 의 취득원가는 그 시점 원화가액")
        XCTAssertEqual(btcLeg.proceedsKRW, 90_000_000, "60,000 × 1,500")
        XCTAssertEqual(btcLeg.pnlKRW, 17_500_000)

        // 내부 이동은 수량을 바꾸지 않는다
        let usdtRow = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "USDT" })
        XCTAssertEqual(usdtRow.quantity, 110_000, "100,000 − 50,000 + 60,000 (내부 이동은 무관)")
        XCTAssertNil(replay.holdings.rows.first { $0.asset.code == "BTC" }, "BTC 는 전량 처분했다")

        let summary = TaxAggregator.aggregate(
            projectID: pid, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: replay.abandonedByYear[2027] ?? 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        XCTAssertEqual(summary.netIncomeKRW, 20_000_000)
        XCTAssertEqual(summary.taxBaseKRW, 17_500_000)
        XCTAssertEqual(summary.nationalTaxKRW, 3_500_000)
        XCTAssertEqual(summary.localTaxKRW, 350_000)
        XCTAssertEqual(summary.totalTaxKRW, 3_850_000, "03-tax-rules §2.3 표시 예시와 같은 자릿수")

        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: [buy, out, into, internalMove, swapIn, swapOut],
            summaryRerun: summary, links: [link]
        ))
        let criticals = report.issues.filter { $0.severity == "critical" }
        XCTAssertTrue(criticals.isEmpty, "정상 경로에서 Critical: " + criticals.map(\.id).joined(separator: ", "))
    }

    /// 내부 이동을 **빠뜨리면** 결과가 달라지는가 — 달라지면 안 된다 (장부 기준 무관)
    func testInternalTransferDoesNotChangeAnyNumber() throws {
        let pid = ProjectID()
        let okx = Account.defaults(for: .okx, projectID: pid)
        let deposit = LedgerEvent(
            projectID: pid, accountID: okx.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 5, hour: 10),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 1_000,
            sourceKind: "oracle", rawRef: "r1"
        )
        let move = LedgerEvent(
            projectID: pid, accountID: okx.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 10),
            type: .transferInternal, baseAsset: AssetSymbol("USDT"), quantity: -400,
            sourceKind: "oracle", rawRef: "r2"
        )
        func run(_ events: [LedgerEvent]) throws -> (qty: Decimal, cost: Decimal) {
            let r = try CostBasisEngine(policies: .v1Default, accountsByID: [okx.id: okx],
                                        fxRates: [:], marketPrices: [:])
                .replay(events: events, links: [])
            let row = r.holdings.rows.first { $0.asset.code == "USDT" }
            return (row?.quantity ?? 0, row?.totalCostKRW ?? 0)
        }
        let withMove = try run([deposit, move])
        let without = try run([deposit])
        XCTAssertEqual(withMove.qty, without.qty, "내부 이동이 보유 수량을 바꿨다")
        XCTAssertEqual(withMove.cost, without.cost, "내부 이동이 취득원가를 바꿨다")
        XCTAssertEqual(withMove.qty, 1_000)
    }
}
