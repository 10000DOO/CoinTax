import XCTest
@testable import CoinTax

/// 사용자 승인으로 넣은 두 가지 안내 (5차 감사 후속).
///
/// ① 손으로 고른 거래소와 **파일 내용**이 다르면 알린다
/// ② 한 원본만 **한참 일찍 끝나면** 알린다 (조회기간을 짧게 받아온 자료)
final class DataGapWarningTests: XCTestCase {

    // MARK: ① 거래소를 손으로 골랐는데 파일이 다른 거래소 것일 때

    private func route(_ fileName: String, _ text: String) -> ImportRouter.Route {
        ImportRouter.route(FormatProbe.probe(text: text, fileName: fileName))
    }

    func testMismatchIsDetected() {
        let okxText = """
        UID:000,Account Type:Main,Time Zone:UTC+0
        id,Time,Type,Amount,Before Balance,After Balance,Symbol
        1,2027-06-01 09:00:00,Deposit,100,0,100,USDT
        """
        let r = route("OKX Funding History.csv", okxText)
        XCTAssertEqual(r.exchange, .okx, "이 파일은 OKX 로 판별돼야 한다")

        // 빗썸 계정을 골라 놓고 OKX 파일을 넣었다 → 알려야 한다
        XCTAssertEqual(ImportRouter.mismatch(route: r, chosenExchange: "bithumb"), .okx)
        // 같은 거래소를 골랐으면 조용해야 한다
        XCTAssertNil(ImportRouter.mismatch(route: r, chosenExchange: "okx"))
        // 「자동으로 구분」이면 애초에 물어볼 일이 없다
        XCTAssertNil(ImportRouter.mismatch(route: r, chosenExchange: nil))
    }

    /// 판별이 자신 없으면 **말하지 않는다** — 근거 없는 경고는 오탐이다
    func testLowConfidenceDoesNotWarn() {
        let vague = route("data.csv", "date,amount\n2027-01-01,1\n")
        XCTAssertFalse(vague.isConfident)
        XCTAssertNil(ImportRouter.mismatch(route: vague, chosenExchange: "bithumb"))
    }

    // MARK: ② 한 원본만 일찍 끝날 때

    private func event(_ source: String, _ year: Int, _ month: Int, _ ref: String) -> LedgerEvent {
        LedgerEvent(
            projectID: ProjectID(), accountID: AccountID(),
            timestamp: TaxTime.dateKST(year: year, month: month, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: source, rawRef: ref
        )
    }

    private func issues(_ events: [LedgerEvent]) -> [VerificationIssue] {
        let s = TaxAggregator.aggregate(
            projectID: ProjectID(), disposals: [], taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0, deemed: [], policies: .v1Default
        )
        let r = ReplayResult(
            disposals: [], holdings: HoldingsSnapshot(asOf: Date(), rows: [], aggregated: []),
            deemedPositions: [], abandonedTotal: 0, extraDeductible: 0, warnings: [],
            transferCostDetails: [], missingMarketAssets: [], missingFXDays: [], fxResolutions: []
        )
        return Verifier.verify(VerifierInput(summary: s, replay: r, policies: .v1Default,
                                             events: events, summaryRerun: s, links: []))
            .issues.filter { $0.id == "V-IMP-06" }
    }

    /// 빗썸은 6월까지, 바이낸스는 12월까지 → 빗썸 자료가 짧게 잘렸을 수 있다
    func testOneSourceEndingMuchEarlierIsReported() {
        let found = issues([
            event("bithumb-certificate-pdf-v1", 2027, 1, "r1"),
            event("bithumb-certificate-pdf-v1", 2027, 6, "r2"),
            event("binance-spot-xlsx-v1", 2027, 1, "r3"),
            event("binance-spot-xlsx-v1", 2027, 12, "r4")
        ])
        XCTAssertEqual(found.count, 1, "일찍 끝난 원본을 알리지 않았다")
        let text = (found.first?.context ?? "") + (found.first?.message ?? "")
        XCTAssertTrue(text.contains("bithumb-certificate-pdf-v1"), "어느 원본인지 짚어야 한다: \(text)")
        XCTAssertFalse(text.contains("binance"), "최근까지 있는 원본을 지적하면 안 된다: \(text)")
    }

    /// 비슷한 시기에 끝나면 조용해야 한다 (오탐 방지)
    func testSimilarEndDatesStayQuiet() {
        XCTAssertTrue(issues([
            event("bithumb-certificate-pdf-v1", 2027, 11, "r1"),
            event("binance-spot-xlsx-v1", 2027, 12, "r2")
        ]).isEmpty)
    }

    /// 원본이 하나뿐이면 비교할 대상이 없다 — 말하지 않는다
    func testSingleSourceStaysQuiet() {
        XCTAssertTrue(issues([
            event("bithumb-certificate-pdf-v1", 2027, 1, "r1"),
            event("bithumb-certificate-pdf-v1", 2027, 6, "r2")
        ]).isEmpty)
    }

    /// 막지는 않는다 — 그 거래소를 안 쓴 것일 수도 있다
    func testItIsOnlyAWarning() {
        let found = issues([
            event("bithumb-certificate-pdf-v1", 2027, 1, "r1"),
            event("binance-spot-xlsx-v1", 2027, 12, "r2")
        ])
        XCTAssertEqual(found.first?.severity, "warning")
    }
}
