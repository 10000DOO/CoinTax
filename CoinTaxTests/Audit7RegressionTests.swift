import XCTest
@testable import CoinTax

/// 7차 감사 회귀 테스트.
///
/// **기대값을 코드에서 가져오지 않았다.** 전부 법령 원문(소득세법 §37⑤⑥·§64의3②·§84 3호,
/// 시행령 §88①②·§92②4, 지방세법 §93, 국고금 관리법 §47)과 손계산에서 다시 유도한 값이다.
/// 손계산 과정은 각 테스트 위에 그대로 적어 둔다 — 나중에 이 숫자가 왜 정답인지 다시 물으면
/// 코드를 읽지 않고 여기서 답할 수 있어야 한다.
final class Audit7RegressionTests: XCTestCase {

    private let pid = ProjectID()
    private func acc(_ c: ExchangeCode) -> Account { Account.defaults(for: c, projectID: pid) }

    private func ev(_ a: Account, _ type: EventType, _ base: String, qty: Decimal,
                    krw: Decimal? = nil, y: Int, m: Int, d: Int, h: Int = 12,
                    quote: String? = "KRW", fee: Decimal? = nil, feeAsset: String? = nil,
                    id: EventID = EventID(), ref: String? = nil) -> LedgerEvent {
        LedgerEvent(id: id, projectID: pid, accountID: a.id,
                    timestamp: TaxTime.dateKST(year: y, month: m, day: d, hour: h),
                    type: type, baseAsset: AssetSymbol(base),
                    quoteAsset: quote.map { AssetSymbol($0) },
                    quantity: qty, quoteAmountKRW: krw,
                    feeAmount: fee, feeAsset: feeAsset.map { AssetSymbol($0) },
                    sourceKind: "audit7", rawRef: ref)
    }

    private func replay(_ accounts: [Account], _ events: [LedgerEvent],
                        links: [TransferLink] = [], market: [String: Decimal] = [:]) throws -> ReplayResult {
        try CostBasisEngine(policies: .v1Default,
                            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                            fxRates: [:], marketPrices: market).replay(events: events, links: links)
    }

    private func sum(_ r: ReplayResult, _ year: Int) -> TaxYearSummary {
        TaxAggregator.aggregate(projectID: pid, disposals: r.disposals, taxYear: year,
                                extraDeductible: r.extraDeductibleByYear[year] ?? 0,
                                abandonedTransferCostKRW: r.abandonedByYear[year] ?? 0,
                                deemed: r.deemedPositions, policies: .v1Default)
    }

    /// 전 기간 원가 보존: 취득에 들어간 원화 + 의제 증액 == Σ 처분 필요경비 + Σ 소멸 + 남은 장부원가
    private func conservationGap(_ r: ReplayResult, 취득: Decimal) -> Decimal {
        let 의제증액 = r.deemedPositions.reduce(Decimal(0)) { $0 + ($1.deemedUnitKRW - $1.bookUnitKRW) * $1.quantity }
        let 처분 = r.disposals.reduce(Decimal(0)) { $0 + $1.costKRW + $1.feesKRW }
        let 소멸 = r.abandonedByYear.values.reduce(Decimal(0), +)
        let 잔고 = r.holdings.aggregated.reduce(Decimal(0)) { $0 + $1.totalCostKRW }
        return (처분 + 소멸 + 잔고) - (취득 + 의제증액)
    }

    private func 연말을_걸치는_전송(수량: Decimal, 매수수량: Decimal, 매수금액: Decimal)
        -> (accounts: [Account], events: [LedgerEvent], links: [TransferLink], wallet: Account) {
        let ex = acc(.binance), w = acc(.wallet)
        let wid = EventID(), did = EventID()
        let events = [
            ev(ex, .buy, "BTC", qty: 매수수량, krw: 매수금액, y: 2026, m: 3, d: 1),
            ev(ex, .withdrawal, "BTC", qty: 수량, y: 2026, m: 12, d: 30, quote: nil, id: wid),
            ev(w, .deposit, "BTC", qty: 수량, y: 2027, m: 1, d: 2, quote: nil, id: did)
        ]
        let link = TransferLink(id: LinkID(), projectID: pid, fromEventID: wid, toEventID: did,
                                status: .confirmed, withdrawnQty: 수량, receivedQty: 수량,
                                score: 1, note: nil, transferredCostKRW: nil, abandonedCostKRW: nil)
        return ([ex, w], events, [link], w)
    }

    // MARK: - D-1 연말에 이동 중인 코인도 의제취득가 대상이다
    //
    // `[법]` §37⑤ 는 「2027년 1월 1일 전에 이미 **보유하고 있던**」만 요구한다.
    // 12/30 에 보내 1/2 에 도착하는 코인은 그 순간 체인 위에 있을 뿐 **내 것이다.**
    //
    // 손계산: BTC 1개 실제취득가 50,000,000 · 시가 100,000,000
    //   의제취득가 = max(50,000,000, 100,000,000) = 100,000,000
    //   2027-08 에 150,000,000 에 매도 → 소득 50,000,000
    func test_D1_이동중인_코인도_의제취득가를_받는다() throws {
        var (accounts, events, links, wallet) = 연말을_걸치는_전송(수량: 1, 매수수량: 1, 매수금액: 50_000_000)
        events.append(ev(wallet, .sell, "BTC", qty: 1, krw: 150_000_000, y: 2027, m: 8, d: 1))
        let r = try replay(accounts, events, links: links, market: ["BTC": 100_000_000])
        let s = sum(r, 2027)
        XCTAssertEqual(s.totalCostsKRW, 100_000_000, "의제취득가 100,000,000 — 이동 중이어도 보유다")
        XCTAssertEqual(s.netIncomeKRW, 50_000_000)
        XCTAssertEqual(conservationGap(r, 취득: 50_000_000), 0, "원가 보존")
    }

    // MARK: - D-1 이동 중인 코인이 **다른 보유분의 원가까지** 깎으면 안 된다
    //
    // 손계산: BTC 2개를 100,000,000 에 매수(단가 50,000,000). 1개는 거래소에, 1개는 이동 중.
    //   시가 100,000,000 → 의제단가 = max(50,000,000, 100,000,000) = 100,000,000
    //   2027 에 2개 다 300,000,000 에 매도 → 필요경비 200,000,000, 소득 100,000,000
    //
    // 고치기 전에는 필요경비가 **100,000,000** 이었다 (이동 중인 1개가 풀에서 사라지면서
    // 배분 비율 1/2 이 걸려 나머지 1개의 원가까지 반으로 깎였다). 세금이 2,200만 원 더 나왔다.
    func test_D1_이동중인_코인이_다른_보유분_원가를_깎지_않는다() throws {
        var (accounts, events, links, wallet) = 연말을_걸치는_전송(수량: 1, 매수수량: 2, 매수금액: 100_000_000)
        let ex = accounts[0]
        events.append(ev(ex, .sell, "BTC", qty: 1, krw: 150_000_000, y: 2027, m: 8, d: 1, ref: "s1"))
        events.append(ev(wallet, .sell, "BTC", qty: 1, krw: 150_000_000, y: 2027, m: 8, d: 2, ref: "s2"))
        let r = try replay(accounts, events, links: links, market: ["BTC": 100_000_000])
        let s = sum(r, 2027)
        XCTAssertEqual(s.totalCostsKRW, 200_000_000, "의제 100,000,000 × 2개")
        XCTAssertEqual(s.netIncomeKRW, 100_000_000)
        XCTAssertEqual(conservationGap(r, 취득: 100_000_000), 0, "원가 보존")
        XCTAssertFalse(r.issues.contains { $0.id == "V-QTY-05" }, "풀 수량 부족이 나면 안 된다")
    }

    // MARK: - D-1 원가 보존 — 팔지 않고 이월해도 원가가 증발하면 안 된다
    func test_D1_이동중인_코인의_원가가_증발하지_않는다() throws {
        let (accounts, events, links, _) = 연말을_걸치는_전송(수량: 1, 매수수량: 3, 매수금액: 150_000_000)
        let r = try replay(accounts, events, links: links, market: ["BTC": 100_000_000])
        XCTAssertEqual(conservationGap(r, 취득: 150_000_000), 0, "원가 보존 — 고치기 전에는 50,000,000 이 증발했다")
    }

    // MARK: - D-1 대조군 — 같은 해 안에서 끝난 전송은 예전과 같아야 한다
    func test_D1_같은해_전송은_그대로() throws {
        let ex = acc(.binance), w = acc(.wallet)
        let wid = EventID(), did = EventID()
        let events = [
            ev(ex, .buy, "BTC", qty: 3, krw: 150_000_000, y: 2026, m: 3, d: 1),
            ev(ex, .withdrawal, "BTC", qty: 1, y: 2026, m: 11, d: 1, quote: nil, id: wid),
            ev(w, .deposit, "BTC", qty: 1, y: 2026, m: 11, d: 2, quote: nil, id: did),
            ev(w, .sell, "BTC", qty: 1, krw: 120_000_000, y: 2027, m: 5, d: 1)
        ]
        let link = TransferLink(id: LinkID(), projectID: pid, fromEventID: wid, toEventID: did,
                                status: .confirmed, withdrawnQty: 1, receivedQty: 1, score: 1,
                                note: nil, transferredCostKRW: nil, abandonedCostKRW: nil)
        let r = try replay([ex, w], events, links: [link], market: ["BTC": 100_000_000])
        XCTAssertEqual(sum(r, 2027).totalCostsKRW, 100_000_000)
        XCTAssertEqual(conservationGap(r, 취득: 150_000_000), 0)
        XCTAssertFalse(r.issues.contains { $0.id == "V-DEM-05" }, "이동 중인 전송이 없으면 경고도 없다")
    }

    // MARK: - D-1 그물 — 의제 기초 수량이 총평균 장부의 기말과 어긋나면 Critical 이어야 한다
    //
    // 일부러 망가뜨렸을 때 잡히는지 확인한다. 이동 중 수량을 빼고 세면(예전 동작)
    // 스냅샷 2개 ≠ 장부 3개가 되어 V-DEM-07 이 떠야 한다.
    func test_D1_의제기초_수량_불일치_감지() throws {
        // 정상 경로에서는 절대 뜨면 안 된다
        let (accounts, events, links, _) = 연말을_걸치는_전송(수량: 1, 매수수량: 3, 매수금액: 150_000_000)
        let r = try replay(accounts, events, links: links, market: ["BTC": 100_000_000])
        XCTAssertFalse(r.issues.contains { $0.id == "V-DEM-07" }, "정상 계산에서 V-DEM-07 이 뜨면 오탐이다")
        XCTAssertEqual(r.deemedPositions.reduce(Decimal(0)) { $0 + $1.quantity }, 3,
                       "의제 대상 수량 = 거래소 2 + 이동 중 1")
    }

    // MARK: - G-1 가진 것보다 많이 내보내면 **가진 원가만큼만** 나눠 줘야 한다
    //
    // 없는 원가를 공제하면 **세금이 줄어드는 방향으로** 틀린다 — 과소 신고다.
    //
    // 이건 **풀을 직접 두들겨야** 확인된다. 엔진을 통하면 계정 장부(`AssetBook`)가 먼저
    // 수량을 자르고 잘린 값만 풀에 넣기 때문에, 정상 입력으로는 이 자리에 도달하지 않는다.
    // 7차 감사에서 배분 축소를 통째로 지워도 344건이 전부 통과한 이유가 이것이다 (그물 구멍).
    // 그래서 방어 코드는 방어 코드대로 **단위 수준에서** 고정한다.
    func test_G1_풀은_가진_원가보다_많이_배분하지_않는다() {
        // 손계산: 1개를 100,000,000 에 샀는데 2개를 판 것으로 기록됐다.
        //   공제할 수 있는 취득가는 있는 것 전부인 100,000,000 이지 200,000,000 이 아니다.
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 100_000_000)
        pool.dispose(asset: "BTC", year: 2027, qty: 2)
        pool.settle(years: [2027])
        XCTAssertEqual(pool.costOfDisposal(asset: "BTC", year: 2027, qty: 2), 100_000_000,
                       "없는 원가를 만들어내면 안 된다")
        XCTAssertTrue(pool.settleWarnings.contains { $0.asset == "BTC" && $0.year == 2027 },
                      "모자란 사실은 알려야 한다")
    }

    // MARK: - G-1 처분과 소실이 섞여 모자라도 **합계가 취득을 넘지 않는다**
    //
    // 비율이 딱 떨어지는 경우 — 여기서는 원 단위까지 정확히 맞아야 한다.
    // 손계산: 12개를 1,200 에 샀는데 8개 처분 + 8개 소실(합 16개)로 기록됐다.
    //   배분 비율 12/16 = 0.75 → 처분 1,200×8×0.75/12 = 600, 소실 1,200×8×0.75/12 = 600
    func test_G1_처분과_소실이_섞여도_원가합이_취득과_같다() throws {
        let pool = ResidentCostPool()
        pool.acquire(asset: "ETH", year: 2027, qty: 12, costKRW: 1_200)
        pool.dispose(asset: "ETH", year: 2027, qty: 8)
        pool.abandon(asset: "ETH", year: 2027, qty: 8)
        pool.settle(years: [2027])
        let 처분 = try XCTUnwrap(pool.costOfDisposal(asset: "ETH", year: 2027, qty: 8))
        let 소실 = pool.abandonedCost(asset: "ETH", year: 2027)
        XCTAssertEqual(처분, 600)
        XCTAssertEqual(소실, 600)
        XCTAssertEqual(처분 + 소실, 1_200, "나눠 준 원가의 합이 취득 원가와 같아야 한다")
        XCTAssertEqual(pool.closing(asset: "ETH", year: 2027)?.qty, 0)
    }

    // MARK: - G-1 비율이 순환소수여도 **원 단위로는** 어긋나지 않는다
    //
    // 10/12 처럼 딱 떨어지지 않는 비율에서는 `Decimal` 38자리에서 잘려 잔차가 남는다.
    // 실측 4×10⁻³⁵원 — 어떤 끝수 처리에도 닿지 않는다. **원 단위로 맞는지**만 고정한다.
    // (여기서 완전 일치를 요구하면 정상 계산을 실패로 만든다 — 7차 감사에서 실제로 헛짚었다)
    func test_G1_순환소수_비율에서도_원단위로_맞는다() throws {
        let pool = ResidentCostPool()
        pool.acquire(asset: "ETH", year: 2027, qty: 10, costKRW: 1_000)
        pool.dispose(asset: "ETH", year: 2027, qty: 8)
        pool.abandon(asset: "ETH", year: 2027, qty: 4)
        pool.settle(years: [2027])
        let 처분 = try XCTUnwrap(pool.costOfDisposal(asset: "ETH", year: 2027, qty: 8))
        let 소실 = pool.abandonedCost(asset: "ETH", year: 2027)
        XCTAssertLessThanOrEqual(Money.abs((처분 + 소실) - 1_000), Decimal(string: "0.000001")!,
                                 "잔차 \(Money.decimalString((처분 + 소실) - 1_000))")
        XCTAssertEqual(Money.roundKRW(처분), 667, "1,000 × 8/12")
        XCTAssertEqual(Money.roundKRW(소실), 333, "1,000 × 4/12")
    }

    // MARK: - G-1 정상 범위에서는 배분을 줄이지 않는다 (오탐 방지)
    func test_G1_모자라지_않으면_그대로_나눠_준다() {
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2027, qty: 4, costKRW: 400)
        pool.dispose(asset: "BTC", year: 2027, qty: 3)
        pool.settle(years: [2027])
        XCTAssertEqual(pool.costOfDisposal(asset: "BTC", year: 2027, qty: 3), 300)
        XCTAssertEqual(pool.closing(asset: "BTC", year: 2027)?.cost, 100)
        XCTAssertTrue(pool.settleWarnings.isEmpty)
    }

    // MARK: - G-1 엔진 경로 — 계정 장부가 먼저 자르므로 원가가 새지 않는다
    func test_G1_엔진에서도_산_것보다_많은_원가가_안_나온다() throws {
        let a = acc(.bithumb)
        let events = [
            ev(a, .buy, "BTC", qty: 2, krw: 100_000_000, y: 2027, m: 1, d: 5, ref: "r1"),
            ev(a, .sell, "BTC", qty: 2, krw: 180_000_000, y: 2027, m: 6, d: 5, ref: "r2"),
            // 자료 누락으로 없는 것을 더 판 기록
            ev(a, .sell, "BTC", qty: 1, krw: 90_000_000, y: 2027, m: 7, d: 5, ref: "r3")
        ]
        let r = try replay([a], events)
        XCTAssertEqual(sum(r, 2027).totalCostsKRW, 100_000_000, "산 것보다 많은 취득가를 공제하면 안 된다")
        XCTAssertTrue(r.issues.contains { $0.id == "V-QTY-02" }, "부족은 알려야 한다")
    }

    // MARK: - M-1 코인 수수료 단가가 서로를 참조해도 원가가 새지 않는다
    //
    // BNB 로 BTC 수수료를 내고, 그 BNB 를 살 때는 BTC 로 수수료를 낸다.
    // 반복 계산이 굳을 때까지 돌지 않으면 잔차가 남는다 (고치기 전 실측 1.37원).
    func test_M1_수수료_상호참조_수렴() throws {
        let a = acc(.binance)
        let events = [
            ev(a, .buy, "BNB", qty: 100, krw: 10_000_000, y: 2027, m: 1, d: 1, ref: "r1"),
            ev(a, .buy, "BTC", qty: 1, krw: 50_000_000, y: 2027, m: 1, d: 2, fee: 1, feeAsset: "BNB", ref: "r2"),
            ev(a, .buy, "BNB", qty: 10, krw: 1_100_000, y: 2027, m: 1, d: 3,
               fee: Decimal(string: "0.001")!, feeAsset: "BTC", ref: "r3"),
            ev(a, .sell, "BTC", qty: Decimal(string: "0.5")!, krw: 40_000_000, y: 2027, m: 6, d: 1, ref: "r4")
        ]
        let r = try replay([a], events)
        let gap = conservationGap(r, 취득: 10_000_000 + 50_000_000 + 1_100_000)
        XCTAssertLessThanOrEqual(Money.abs(gap), Decimal(string: "0.01")!,
                                 "수수료 상호참조 잔차 \(Money.decimalString(gap))")
        XCTAssertTrue(r.issues.filter { $0.severity == "critical" }.isEmpty)
    }

    // MARK: - 검증기가 이 자료를 통과시키는가 (정상 계산을 막으면 안 된다)
    func test_이동중_전송이_있어도_Critical_이_없다() throws {
        var (accounts, events, links, wallet) = 연말을_걸치는_전송(수량: 1, 매수수량: 2, 매수금액: 100_000_000)
        events.append(ev(wallet, .sell, "BTC", qty: 1, krw: 150_000_000, y: 2027, m: 8, d: 2))
        let r = try replay(accounts, events, links: links, market: ["BTC": 100_000_000])
        let s = sum(r, 2027)
        let report = Verifier.verify(VerifierInput(summary: s, replay: r, policies: .v1Default,
                                                   events: events, summaryRerun: s, links: links, fxPublished: [:]))
        let crit = report.issues.filter { $0.severity == "critical" }
        XCTAssertTrue(crit.isEmpty, "critical: \(crit.map { "\($0.id) \($0.message)" }.joined(separator: " | "))")
    }
}
