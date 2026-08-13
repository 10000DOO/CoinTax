import XCTest
@testable import CoinTax

/// 거래 **시각**이 말이 되는 값인지 (5차 감사 회차 35).
///
/// 회차 12 에서 환율 날짜에 「두 자리 연도가 서기 27년이 된다」를 찾아 막았다.
/// 거래 시각에도 같은 갈래가 있는지 본다 — 이쪽이 훨씬 아프다:
/// **과세연도가 바뀌면 그 거래가 신고 대상에서 통째로 빠진다.**
///
/// 바이낸스는 출금 내역에 실제로 두 자리 연도를 쓴다(`25-12-21`, `parsers/binance-withdraw-history.md`).
/// 그래서 다른 export 에도 두 자리 연도가 섞여 들어올 수 있다.
final class EventDateSanityTests: XCTestCase {

    /// 바이낸스 Spot CSV 에 두 자리 연도가 오면 어느 해로 가는가
    func testTwoDigitYearInSpotFileIsNotSilentlyAccepted() throws {
        let csv = """
        Date(UTC),Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        27-03-01 10:00:00,BTC,USDT,BUY,50000,1,50000,0,USDT
        """
        let result = try BinanceSpotXLSXParser().parse(
            text: csv, fileName: "spot.csv", projectID: ProjectID(), accountID: AccountID()
        )
        // 읽었다면 **말이 되는 연도**여야 한다. 서기 27년이면 과세연도 밖으로 빠져나간다.
        for e in result.events {
            let year = TaxTime.calendarYearKST(e.timestamp)
            XCTAssertTrue(
                (2000...2100).contains(year),
                """
                거래 시각이 서기 \(year)년으로 읽혔다 — 그 거래는 과세 집계에서 조용히 빠진다.
                (두 자리 연도를 네 자리로 오해한 것)
                """
            )
        }
        // 세기를 추측하지 않고 **못 읽었다고 알린다** — 조용히 틀리는 것보다 낫다
        XCTAssertTrue(result.events.isEmpty, "말이 안 되는 연도를 그대로 받아들였다")
        XCTAssertTrue(
            result.warnings.contains { $0.contains("시각") || $0.contains("날짜") },
            "건너뛴 사실을 알리지 않았다: \(result.warnings)"
        )
    }

    /// 제네릭 표 매핑은 `yy-MM-dd` 형식을 뒤에 갖고 있어, 범위 검사 덕에 **올바른 연도로** 읽힌다
    func testGenericMapperFallsBackToTwoDigitYearFormat() throws {
        let csv = """
        date,type,asset,quantity,total
        27-03-01 10:00:00,buy,BTC,1,50000000
        """
        let result = try GenericTabularMapper(timeZoneIdentifier: "Asia/Seoul")
            .parse(text: csv, fileName: "g.csv", projectID: ProjectID(), accountID: AccountID())
        let e = try XCTUnwrap(result.events.first, "오류: \(result.errors)")
        XCTAssertEqual(TaxTime.calendarYearKST(e.timestamp), 2027, "두 자리 연도 형식이 뒤에 있으므로 제대로 읽혀야 한다")
    }

    /// 출금 파서는 두 자리 연도를 **정상 처리**해야 한다 (바이낸스 실제 포맷)
    func testWithdrawParserStillReadsTwoDigitYears() throws {
        let csv = """
        Date(UTC+0),Coin,Network,Amount,Fee,Address,TXID,Status
        25-12-21 00:51:45,BTC,BTC,0.02,0.000015,addr,txid,Completed
        """
        let result = try BinanceWithdrawXLSXParser().parse(
            text: csv, fileName: "withdraw.csv", projectID: ProjectID(), accountID: AccountID()
        )
        let e = try XCTUnwrap(result.events.first, "경고: \(result.warnings)")
        XCTAssertEqual(TaxTime.calendarYearKST(e.timestamp), 2025, "바이낸스 출금은 두 자리 연도가 정상 포맷이다")
    }

    /// 말이 안 되는 연도의 거래가 장부에 들어오면 **과세 집계에서 빠진다**는 사실을 고정한다.
    /// (막지 못했을 때 무슨 일이 생기는지 — 왜 위에서 막아야 하는지의 근거)
    func testOutOfRangeYearWouldEscapeTaxableTotals() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        func trade(_ year: Int, _ type: EventType, _ krw: Decimal, _ ref: String) -> LedgerEvent {
            LedgerEvent(
                projectID: pid, accountID: acc.id,
                timestamp: TaxTime.dateKST(year: year, month: 3, day: 1, hour: 10),
                type: type, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: type == .sell ? -1 : 1, quoteAmountKRW: krw,
                sourceKind: "sanity", rawRef: ref
            )
        }
        // 서기 27년에 사고 판 것처럼 읽힌 거래
        let replay = try CostBasisEngine(policies: .v1Default, accountsByID: [acc.id: acc],
                                         fxRates: [:], marketPrices: [:])
            .replay(events: [trade(27, .buy, 50_000_000, "r1"), trade(27, .sell, 70_000_000, "r2")], links: [])
        let summary = TaxAggregator.aggregate(
            projectID: pid, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        XCTAssertEqual(replay.disposals.count, 1, "장부에는 처분이 남는다")
        XCTAssertEqual(summary.disposals.count, 0, "그런데 2027 신고 집계에는 안 들어온다")
        XCTAssertEqual(summary.totalTaxKRW, 0, "2,000만원 이익이 세액에 반영되지 않는다")
    }
}
