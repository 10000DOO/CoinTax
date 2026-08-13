import XCTest
@testable import CoinTax

/// 「거래소 잔고와 대조했다」는 안심이 **어디까지 유효한지** 사용자가 알 수 있는가 (5차 감사 회차 22).
///
/// 잔고 대조(V-BAL)는 이 앱에서 **유일하게 앱 밖에서 온 정답지**다.
/// 그런데 잔고 열이 있는 원본과 없는 원본을 섞어 넣으면, 없는 쪽은 외부 대조를 **한 번도 못 받는다.**
/// 예전에는 「하나라도 잔고가 있으면」 경고를 접었기 때문에,
/// 빗썸(잔고 있음) + 바이낸스(잔고 없음)를 넣은 사용자는 **바이낸스가 안 덮였다는 사실을 몰랐다.**
final class BalanceCoverageTests: XCTestCase {

    private func event(_ account: AccountID, _ source: String, _ balance: Decimal?, _ ref: String) -> LedgerEvent {
        LedgerEvent(
            projectID: ProjectID(), accountID: account,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000,
            sourceKind: source, rawRef: ref, balanceAfter: balance
        )
    }

    private func verify(_ events: [LedgerEvent]) -> [VerificationIssue] {
        let summary = TaxAggregator.aggregate(
            projectID: ProjectID(), disposals: [], taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0, deemed: [], policies: .v1Default
        )
        let replay = ReplayResult(
            disposals: [], holdings: HoldingsSnapshot(asOf: Date(), rows: [], aggregated: []),
            deemedPositions: [], abandonedTotal: 0, extraDeductible: 0, warnings: [],
            transferCostDetails: [], missingMarketAssets: [], missingFXDays: [], fxResolutions: []
        )
        return Verifier.verify(VerifierInput(summary: summary, replay: replay, policies: .v1Default,
                                             events: events, summaryRerun: summary, links: []))
            .issues.filter { $0.id == "V-BAL-03" }
    }

    /// 전부 잔고가 있으면 조용해야 한다
    func testAllStreamsCoveredIsQuiet() {
        let a = AccountID()
        XCTAssertTrue(verify([
            event(a, "bithumb-certificate-pdf-v1", 1, "r1"),
            event(a, "bithumb-certificate-pdf-v1", 2, "r2")
        ]).isEmpty)
    }

    /// 전부 잔고가 없으면 알려야 한다 (기존 동작)
    func testNoStreamCoveredIsReported() {
        let a = AccountID()
        XCTAssertFalse(verify([event(a, "binance-spot-xlsx-v1", nil, "r1")]).isEmpty)
    }

    /// **섞여 있으면** — 안 덮인 쪽을 짚어 줘야 한다.
    ///
    /// 빗썸에는 잔고 열이 있고 바이낸스에는 없다. 예전에는 빗썸 때문에 경고가 접혔고,
    /// 사용자는 바이낸스가 외부 대조를 못 받았다는 사실을 알 방법이 없었다.
    func testPartiallyCoveredNamesTheUncoveredStream() {
        let bithumb = AccountID()
        let binance = AccountID()
        let issues = verify([
            event(bithumb, "bithumb-certificate-pdf-v1", 1, "r1"),
            event(binance, "binance-spot-xlsx-v1", nil, "r2"),
            event(binance, "binance-spot-xlsx-v1", nil, "r3")
        ])
        XCTAssertFalse(issues.isEmpty, "잔고 열이 없는 원본이 있는데 아무 말도 하지 않았다")
        let text = issues.map { "\($0.message) \($0.context ?? "")" }.joined(separator: " ")
        XCTAssertTrue(text.contains("binance-spot-xlsx-v1"), "어느 원본이 안 덮였는지 짚어 주지 않았다: \(text)")
        XCTAssertFalse(text.contains("bithumb"), "덮인 원본까지 안 덮였다고 했다: \(text)")
    }
}

/// 파일 → 파서 선택이 **실행마다 같은가** (5차 감사 회차 29).
///
/// 점수가 같은 파서가 실제 파일명에서 나온다 — `binance-deposit-withdraw-history.csv` 는
/// 입금·출금 파서가 나란히 0.92 다. Swift 의 `sort` 는 안정성을 보장하지 않으므로,
/// 동점을 배열 순서에 맡기면 파서를 추가·재배치할 때 조용히 다른 파서가 선택될 수 있다.
final class ParserRankingDeterminismTests: XCTestCase {
    private func top(_ fileName: String) -> String? {
        let probe = FormatProbe.probe(text: "Date(UTC),Coin,Amount\n2027-01-01,BTC,1\n", fileName: fileName)
        return ParserRegistry.v1.ranked(for: probe).first?.parser.parserID
    }

    func testTiedScoresPickTheSameParserEveryTime() {
        for name in ["binance-deposit-withdraw-history.csv",
                     "입출금내역 deposit withdraw.csv",
                     "OKX Trading History and Funding History.csv"] {
            let first = top(name)
            XCTAssertNotNil(first, "\(name): 파서를 못 찾았다")
            for _ in 0..<20 {
                XCTAssertEqual(top(name), first, "\(name): 같은 파일인데 파서 선택이 달라졌다")
            }
        }
    }

    /// 동점이라도 **같은 거래소**로 가야 계정 배정이 흔들리지 않는다
    func testTiedParsersAgreeOnExchange() {
        for name in ["binance-deposit-withdraw-history.csv", "OKX Trading History and Funding History.csv"] {
            let probe = FormatProbe.probe(text: "Date(UTC),Coin,Amount\n2027-01-01,BTC,1\n", fileName: name)
            let ranked = ParserRegistry.v1.ranked(for: probe)
            guard ranked.count >= 2, ranked[0].score == ranked[1].score else { continue }
            let a = ImportRouter.exchange(forParserID: ranked[0].parser.parserID)
            let b = ImportRouter.exchange(forParserID: ranked[1].parser.parserID)
            XCTAssertEqual(a, b, "\(name): 동점 파서가 서로 다른 거래소로 간다 — 계정 배정이 흔들린다")
        }
    }
}
