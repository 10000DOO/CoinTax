import XCTest
@testable import CoinTax

/// 바이낸스 Transaction History — 거래내역·입금내역·출금내역이 못 잡는 것을 채운다.
///
/// 실데이터에서 「보유보다 많이 썼다」로 계산이 막힌 두 곳의 원인이 이 파일에만 있는
/// `Referral Commission` → `Binance Convert` 경로였다 (docs/parsers/binance-transaction-history.md).
final class BinanceTransactionHistoryTests: XCTestCase {

    private let parser = BinanceTransactionHistoryCSVParser()
    private let fileName = "Binance-Transaction-History-202608120614(UTC+9)-part1-of1.csv"

    private func parse(_ csv: String, name: String? = nil) throws -> ParseResult {
        try parser.parse(text: csv, fileName: name ?? fileName, projectID: ProjectID(), accountID: AccountID())
    }

    private let sample = """
    User ID,Time,Account,Operation,Coin,Change,Remark
    1,2026-01-02 10:00:00,Spot,Deposit,USDT,1000,
    1,2026-01-03 11:00:00,Spot,Transaction Buy,BTC,0.01,
    1,2026-01-03 11:00:00,Spot,Transaction Spend,USDT,-900,
    1,2026-01-03 11:00:00,Spot,Transaction Fee,BNB,-0.001,
    1,2026-01-04 12:00:00,Spot,Referral Commission,USDC,2.5,
    1,2026-01-05 13:00:01,Spot,Binance Convert,USDC,-2.5,
    1,2026-01-05 13:00:02,Spot,Binance Convert,USDT,2.49,
    1,2026-01-06 14:00:00,Spot,Withdraw,BTC,-0.005,Withdraw fee is included
    1,2026-01-07 15:00:00,Spot,Simple Earn Flexible Interest,USDT,0.12,
    """

    // MARK: 인식

    func testDetectsByFileName() {
        let probe = FormatProbe.probe(text: sample, fileName: fileName)
        XCTAssertGreaterThan(parser.detect(probe), 0.9)
        XCTAssertEqual(ParserRegistry.v1.resolve(for: probe)?.parserID, "binance-transaction-history-csv-v1")
        XCTAssertEqual(ImportRouter.route(probe).exchange, .binance)
        XCTAssertTrue(ImportRouter.route(probe).isConfident)
    }

    /// 파일명을 못 믿는 경우에도 `Operation` 열로 알아본다.
    func testDetectsByHeaderAlone() {
        let probe = FormatProbe.probe(text: sample, fileName: "export.csv")
        XCTAssertGreaterThanOrEqual(parser.detect(probe), 0.9)
    }

    /// 다른 바이낸스 파일을 이 파서가 가로채면 안 된다.
    func testDoesNotStealSpotFile() {
        let spot = """
        Time,Pair,Side,Price,Executed,Amount,Fee
        2026-01-03 11:00:00,BTCUSDT,BUY,90000,0.01BTC,900USDT,0.001BNB
        """
        let probe = FormatProbe.probe(text: spot, fileName: "Binance-Spot-Trade-History-202601(UTC+9).csv")
        XCTAssertEqual(parser.detect(probe), 0)
        XCTAssertEqual(ParserRegistry.v1.resolve(for: probe)?.parserID, "binance-spot-xlsx-v1")
    }

    // MARK: 매핑

    /// 매매 행은 Spot 거래내역에서 읽는다 — 여기서 또 읽으면 거래가 두 배가 된다.
    func testSpotRowsAreSkippedWithoutWarning() throws {
        let r = try parse(sample)
        XCTAssertTrue(r.events.filter { $0.type == .buy && $0.baseAsset.code == "BTC" }.isEmpty,
                      "Transaction Buy 를 매수로 만들면 Spot 파일과 중복된다")
        XCTAssertEqual(r.ignoredCount, 3, "Buy/Spend/Fee 3행")
        XCTAssertTrue(r.warnings.isEmpty, "정상 동작이므로 경고를 내지 않는다: \(r.warnings)")
    }

    func testDepositAndWithdraw() throws {
        let r = try parse(sample)
        let dep = try XCTUnwrap(r.events.first { $0.type == .deposit })
        XCTAssertEqual(dep.baseAsset.code, "USDT")
        XCTAssertEqual(dep.quantity, 1000)

        let wd = try XCTUnwrap(r.events.first { $0.type == .withdrawal })
        XCTAssertEqual(wd.baseAsset.code, "BTC")
        XCTAssertEqual(wd.quantity, Decimal(string: "-0.005"))
        // Change 가 수수료까지 합친 총량이라 수수료를 또 빼면 이중 차감이 된다
        XCTAssertTrue(wd.quantityIsNetOfFee)
        XCTAssertNil(wd.feeAmount)
    }

    /// 리퍼럴 보상·이자는 공짜로 받은 것 → 취득가 0원 (income).
    func testRewardsBecomeIncome() throws {
        let r = try parse(sample)
        let income = r.events.filter { $0.type == .income }
        XCTAssertEqual(Set(income.map(\.baseAsset.code)), ["USDC", "USDT"])
        XCTAssertEqual(income.first { $0.baseAsset.code == "USDC" }?.quantity, Decimal(string: "2.5"))
    }

    /// 파일명 `(UTC+9)` 로 시각을 해석해야 한다. UTC 로 읽으면 하루가 밀려
    /// 환율 적용일과 과세연도가 달라진다.
    func testTimeZoneFromFileName() throws {
        let r = try parse(sample)
        let dep = try XCTUnwrap(r.events.first { $0.type == .deposit })
        XCTAssertEqual(r.meta["timezone"], TimeZone(secondsFromGMT: 9 * 3600)?.identifier)
        XCTAssertEqual(dep.timestamp, TaxTime.dateKST(year: 2026, month: 1, day: 2, hour: 10))
    }

    // MARK: 코인 바꾸기

    /// 두 행이 한 건의 매수로 묶여야 낸 코인이 처분되고 받은 코인에 원가가 얹힌다.
    func testConvertPairsIntoOneBuy() throws {
        let r = try parse(sample)
        let convert = try XCTUnwrap(r.events.first { $0.memo == "코인 바꾸기" })
        XCTAssertEqual(convert.type, .buy)
        XCTAssertEqual(convert.baseAsset.code, "USDT")
        XCTAssertEqual(convert.quantity, Decimal(string: "2.49"))
        XCTAssertEqual(convert.quoteAsset?.code, "USDC")
        XCTAssertEqual(convert.quoteAmount, Decimal(string: "2.5"))
        // 낸 코인이 그 시점에 장부에 있어야 하므로 이른 쪽 시각을 쓴다
        XCTAssertEqual(convert.timestamp, TaxTime.dateKST(year: 2026, month: 1, day: 5, hour: 13, minute: 0, second: 1))
    }

    /// 순서가 (받은 것, 내보낸 것) 으로 뒤집혀 찍혀도 같은 결과여야 한다 (실데이터에 둘 다 있다).
    func testConvertPairsRegardlessOfRowOrder() throws {
        let csv = """
        User ID,Time,Account,Operation,Coin,Change,Remark
        1,2026-01-05 13:00:01,Spot,Binance Convert,USDT,2.49,
        1,2026-01-05 13:00:02,Spot,Binance Convert,USDC,-2.5,
        """
        let convert = try XCTUnwrap(try parse(csv).events.first)
        XCTAssertEqual(convert.type, .buy)
        XCTAssertEqual(convert.baseAsset.code, "USDT")
        XCTAssertEqual(convert.quoteAsset?.code, "USDC")
    }

    /// 여러 쌍이 섞여 있어도 각각 맞게 묶인다.
    /// 실데이터는 두 쌍이 31초 간격으로 이어 붙어 있어, 잘못 묶으면 자산이 뒤바뀐다.
    func testMultipleConvertPairs() throws {
        let csv = """
        User ID,Time,Account,Operation,Coin,Change,Remark
        1,2026-02-01 10:00:10,Spot,Binance Convert,USDT,-1.5,
        1,2026-02-01 10:00:10,Spot,Binance Convert,BTC,0.00002,
        1,2026-02-01 10:00:40,Spot,Binance Convert,BTC,0.00001,
        1,2026-02-01 10:00:41,Spot,Binance Convert,USDC,-0.75,
        """
        let r = try parse(csv)
        let buys = r.events.filter { $0.type == .buy }
        XCTAssertEqual(buys.count, 2, "두 쌍이 각각 한 건으로: \(r.warnings)")
        XCTAssertTrue(r.warnings.isEmpty, r.warnings.joined(separator: " / "))
        XCTAssertEqual(buys.compactMap(\.quoteAsset?.code).sorted(), ["USDC", "USDT"])
        // BTC 유입 합계가 보존되어야 한다 — 실데이터에서 「보유보다 많은 출금」의 정체가 이것이었다
        let btcIn = buys.filter { $0.baseAsset.code == "BTC" }.reduce(Decimal(0)) { $0 + $1.quantity }
        XCTAssertEqual(btcIn, Decimal(string: "0.00003"))
    }

    /// 짝이 없으면 잔고는 맞추고 알린다 — 조용히 버리면 나중에 「보유보다 많이 썼다」로 터진다.
    func testUnpairedConvertKeepsBalanceAndWarns() throws {
        let csv = """
        User ID,Time,Account,Operation,Coin,Change,Remark
        1,2026-01-05 13:00:01,Spot,Binance Convert,USDT,2.49,
        """
        let r = try parse(csv)
        let e = try XCTUnwrap(r.events.first)
        XCTAssertEqual(e.type, .income, "받은 것은 취득가 0원으로 두고 수량은 살린다")
        XCTAssertEqual(e.quantity, Decimal(string: "2.49"))
        XCTAssertFalse(r.warnings.isEmpty, "상대 줄을 못 찾았다는 사실을 알려야 한다")
    }

    // MARK: 모르는 종류

    func testUnknownOperationIsReported() throws {
        let csv = """
        User ID,Time,Account,Operation,Coin,Change,Remark
        1,2026-01-05 13:00:00,Spot,Some Brand New Thing,DOGE,123,
        """
        let r = try parse(csv)
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertEqual(r.ignoredCount, 1)
        XCTAssertTrue(r.warnings.contains { $0.contains("Some Brand New Thing") }, r.warnings.joined())
    }

    func testHeaderMismatchIsRejected() {
        XCTAssertThrowsError(try parse("Time,Coin,Amount\n2026-01-01 00:00:00,BTC,1"))
    }

    // MARK: 예전 입금/출금 내역과 겹칠 때

    /// Transaction History 와 입금·출금 내역은 **같은 입출금을 다르게 적는다**
    /// (입금 20초·출금 26분 차, 출금액은 수수료 합산 — 실측). 내용 기준 중복 제거에 안 걸린다.
    /// 둘 다 넣으면 입출금이 두 번 잡혀 보유 수량과 취득원가가 부풀므로 Critical 로 막아야 한다.
    func testOverlappingBinanceSourcesAreBlocked() {
        func summary(_ events: [LedgerEvent]) -> VerificationReport {
            let policies = PolicyBundle.v1Default
            let s = TaxAggregator.aggregate(
                projectID: ProjectID(), disposals: [], taxYear: 2027,
                extraDeductible: 0, abandonedTransferCostKRW: 0, deemed: [], policies: policies
            )
            let replay = ReplayResult(
                disposals: [], holdings: HoldingsBuilder.empty(), deemedPositions: [],
                abandonedTotal: 0, extraDeductible: 0, warnings: [], transferCostDetails: [],
                missingMarketAssets: [], missingFXDays: [], fxResolutions: []
            )
            return Verifier.verify(VerifierInput(summary: s, replay: replay, policies: policies,
                                                events: events, summaryRerun: s))
        }
        func deposit(_ source: String) -> LedgerEvent {
            LedgerEvent(projectID: ProjectID(), accountID: AccountID(),
                        timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
                        type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 100,
                        sourceKind: source)
        }
        let txOnly = summary([deposit("binance-transaction-history-csv-v1")])
        XCTAssertFalse(txOnly.issues.contains { $0.id == "V-IMP-05" }, "한 종류만 있으면 문제없다")

        let both = summary([deposit("binance-transaction-history-csv-v1"), deposit("binance-deposit-xlsx-v1")])
        let issue = both.issues.first { $0.id == "V-IMP-05" }
        XCTAssertNotNil(issue, "겹치면 막아야 한다")
        XCTAssertEqual(issue?.severity, "critical")
        XCTAssertFalse(both.isExportAllowed)

        let legacyOnly = summary([deposit("binance-deposit-xlsx-v1"), deposit("binance-withdraw-xlsx-v1")])
        XCTAssertFalse(legacyOnly.issues.contains { $0.id == "V-IMP-05" }, "예전 조합만 쓰는 자료도 계속 받는다")
    }
}
