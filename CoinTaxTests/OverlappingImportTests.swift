import XCTest
import SwiftData
@testable import CoinTax

/// 같은 거래소의 파일을 **기간이 겹치게** 여러 번 가져왔을 때 한 번만 계산되는지.
///
/// 거래ID가 있는 파일(바이낸스 입출금 TXID, OKX id/Order id)은 원래 걸러졌지만,
/// 거래ID가 없는 파일(바이낸스 Spot·빗썸 확인서)은 지문에 **행 번호**가 섞여 있어
/// 행 위치가 밀리면 같은 거래가 두 번 쌓였다.
@MainActor
final class OverlappingImportTests: XCTestCase {

    private func makeProject() throws -> (ModelContext, ProjectEntity) {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = try ProjectService(modelContext: ctx).createProject(name: "dedupe")
        return (ctx, project)
    }

    private func account(_ project: ProjectEntity, _ code: String) throws -> AccountEntity {
        try XCTUnwrap(project.accounts.first { $0.exchangeCode == code })
    }

    // MARK: 바이낸스 Spot — 거래ID 없음 + 행 번호가 밀리는 경우

    func testBinanceSpotOverlappingRangeCountsOnce() throws {
        let (ctx, project) = try makeProject()
        let acc = try account(project, "binance")
        let svc = ImportService(modelContext: ctx)

        // 1차: 6월 거래 2건
        let first = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        2027-06-02 10:00:00,BTC/USDT,BTC,USDT,BUY,51000,0.02,1020,0,USDT
        """
        let o1 = try svc.importText(first, fileName: "spot-06.csv", project: project, account: acc,
                                    parser: BinanceSpotXLSXParser())
        XCTAssertEqual(o1.inserted, 2)

        // 2차: 5~7월 재추출 — 앞에 5월 거래가 끼면서 6월 거래의 **행 번호가 밀린다**
        let second = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-05-01 10:00:00,BTC/USDT,BTC,USDT,BUY,49000,0.03,1470,0,USDT
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        2027-06-02 10:00:00,BTC/USDT,BTC,USDT,BUY,51000,0.02,1020,0,USDT
        2027-07-01 10:00:00,BTC/USDT,BTC,USDT,BUY,52000,0.04,2080,0,USDT
        """
        let o2 = try svc.importText(second, fileName: "spot-05-07.csv", project: project, account: acc,
                                    parser: BinanceSpotXLSXParser())
        XCTAssertEqual(o2.inserted, 2, "5월·7월만 새로 들어와야 한다")
        XCTAssertEqual(o2.skippedDupe, 2, "6월 2건은 이미 있다")
        XCTAssertEqual(project.events.count, 4)
        XCTAssertTrue(o2.parseResult.warnings.contains { $0.contains("건너뛰었습니다") })
    }

    // MARK: 같은 초에 체결된 서로 다른 두 건은 합쳐지면 안 된다

    func testGenuinelyIdenticalFillsAreBothKept() throws {
        let (ctx, project) = try makeProject()
        let acc = try account(project, "binance")
        let svc = ImportService(modelContext: ctx)

        let text = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        """
        let o = try svc.importText(text, fileName: "spot.csv", project: project, account: acc,
                                   parser: BinanceSpotXLSXParser())
        XCTAssertEqual(o.inserted, 2, "동일해 보여도 한 파일 안의 두 행은 두 건의 체결이다")
    }

    /// 위 파일을 다시 가져오면 2건 모두 건너뛴다 (개수까지 맞춰서 비교)
    func testDuplicateCountIsMatchedNotCollapsed() throws {
        let (ctx, project) = try makeProject()
        let acc = try account(project, "binance")
        let svc = ImportService(modelContext: ctx)

        let two = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        """
        _ = try svc.importText(two, fileName: "a.csv", project: project, account: acc, parser: BinanceSpotXLSXParser())

        // 같은 거래 2건 + 새 거래 1건
        let three = two + "\n2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT"
        let o = try svc.importText(three, fileName: "b.csv", project: project, account: acc, parser: BinanceSpotXLSXParser())
        XCTAssertEqual(o.skippedDupe, 2, "이미 있는 2건만 건너뛴다")
        XCTAssertEqual(o.inserted, 1, "늘어난 1건은 새로 넣는다")
        XCTAssertEqual(project.events.count, 3)
    }

    // MARK: 빗썸 확인서 — 줄 번호가 밀려도 한 번만

    func testBithumbOverlappingExtractCountsOnce() throws {
        let (ctx, project) = try makeProject()
        let acc = try account(project, "bithumb")
        let svc = ImportService(modelContext: ctx)

        let first = """
        2027-03-01|10:00:00|USDT|매수|10|14000|140000|-140350|지정가
        """
        _ = try svc.importText(first, fileName: "b1.txt", project: project, account: acc,
                               parser: BithumbCertificatePDFParser())

        let second = """
        2027-02-01|09:00:00|USDT|매수|5|13000|65000|-65160|지정가
        2027-03-01|10:00:00|USDT|매수|10|14000|140000|-140350|지정가
        """
        let o = try svc.importText(second, fileName: "b2.txt", project: project, account: acc,
                                   parser: BithumbCertificatePDFParser())
        XCTAssertEqual(o.inserted, 1, "2월 건만 새로 들어온다")
        XCTAssertEqual(o.skippedDupe, 1)
    }

    // MARK: 거래ID가 있는 파일 — 기존에도 걸러졌는지 재확인

    func testBinanceDepositTXIDDedupe() throws {
        let (ctx, project) = try makeProject()
        let acc = try account(project, "binance")
        let svc = ImportService(modelContext: ctx)

        let text = """
        Date(UTC+0),Coin,Network,Amount,Address,TXID,Status
        27-06-01 10:00:00,USDT,TRX,9.9,addr1,txid1,Completed
        """
        _ = try svc.importText(text, fileName: "d1.csv", project: project, account: acc,
                               parser: BinanceDepositXLSXParser())
        // 같은 입금 + 새 입금
        let text2 = text + "\n27-07-01 10:00:00,USDT,TRX,5.0,addr2,txid2,Completed"
        let o = try svc.importText(text2, fileName: "d2.csv", project: project, account: acc,
                                   parser: BinanceDepositXLSXParser())
        XCTAssertEqual(o.skippedDupe, 1)
        XCTAssertEqual(o.inserted, 1)
    }

    // MARK: OKX 두 파일 — 같은 내부 이동이 양쪽에 찍혀도 수량이 늘지 않는다

    func testOKXTradingAndFundingInternalMoveNotDoubleCounted() throws {
        let (ctx, project) = try makeProject()
        let acc = try account(project, "okx")
        let svc = ImportService(modelContext: ctx)

        // Trading History: 거래 계정 쪽 기록
        let trading = """
        UID:000,Account Type:Main,Time Zone:UTC+0
        id,Order id,Time,Trade Type,Symbol,Action,Amount,Trading Unit,Filled Price,PnL,Fee,Fee Unit,Position Change,Position Balance,Balance Change,Balance,Balance Unit
        1,tr-1,2027-06-02 12:00:00,Transfer,,Transfer in,0,cont,0,0,0,USDT,0,0,100,100,USDT
        """
        _ = try svc.importText(trading, fileName: "OKX Trading History.csv", project: project, account: acc)

        // Funding History: 펀딩 계정 쪽 같은 이동
        let funding = """
        UID:000,Account Type:Main,Time Zone:UTC+0
        id,Time,Type,Amount,Before Balance,After Balance,Symbol
        f1,2027-06-02 12:00:00,To unified trading account,-100,100,0,USDT
        f2,2027-06-01 09:00:00,Deposit,100,0,100,USDT
        """
        _ = try svc.importText(funding, fileName: "OKX Funding History.csv", project: project, account: acc)

        let ps = ProjectService(modelContext: ctx)
        let events = ps.domainEvents(for: project)
        let accounts = ps.domainAccounts(for: project)
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) }),
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: events, links: [])
        let row = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "USDT" })
        XCTAssertEqual(row.quantity, 100, "외부 입금 100 만 잡혀야 한다 — 내부 이동은 수량을 바꾸지 않는다")
    }

    // MARK: 이미 쌓인 중복은 검증기가 알려준다

    func testVerifierFlagsCrossFileDuplicates() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: projectID)
        func event(file: UUID, rawRef: String) -> LedgerEvent {
            LedgerEvent(
                projectID: projectID, accountID: acc.id,
                sourceFileID: SourceFileID(file),
                timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
                type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: 1, quoteAmountKRW: 50_000_000,
                sourceKind: "binance-spot-xlsx-v1", rawRef: rawRef
            )
        }
        let events = [event(file: UUID(), rawRef: "row2"), event(file: UUID(), rawRef: "row5")]
        let replay = ReplayResult(
            disposals: [], holdings: HoldingsBuilder.empty(), deemedPositions: [],
            abandonedTotal: 0, extraDeductible: 0, warnings: [], transferCostDetails: [],
            missingMarketAssets: [], missingFXDays: [], fxResolutions: []
        )
        let summary = TaxYearSummary(
            projectID: projectID, taxYear: 2027, status: .draft, policyBundleID: PolicyBundle.v1Default.id,
            totalProceedsKRW: 0, totalCostsKRW: 0, netIncomeKRW: 0, basicDeductionKRW: 2_500_000,
            taxBaseKRW: 0, nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
            abandonedTransferCostKRW: 0, disposals: [], deemed: [],
            disclaimers: PolicyBundle.v1Default.disclaimers, calculatedAt: Date(), verification: nil
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default, events: events, summaryRerun: summary
        ))
        XCTAssertTrue(report.issues.contains { $0.id == "V-IMP-05" },
                      "행 번호만 다른 같은 거래가 두 파일에 있으면 알려야 한다")
    }
}

/// 중복 판정 키가 표기 차이·파서 차이에 흔들리지 않는지
@MainActor
final class ContentKeyRobustnessTests: XCTestCase {

    /// 같은 수량을 `0.01` 과 `0.01000000` 으로 쓴 두 파일 → 한 번만
    func testDecimalPaddingDoesNotDefeatDedupe() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = try ProjectService(modelContext: ctx).createProject(name: "pad")
        let acc = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let svc = ImportService(modelContext: ctx)

        let compact = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        """
        let padded = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000.00000000,0.01000000,500.00,0.00000000,USDT
        """
        _ = try svc.importText(compact, fileName: "a.csv", project: project, account: acc, parser: BinanceSpotXLSXParser())
        let o = try svc.importText(padded, fileName: "b.csv", project: project, account: acc, parser: BinanceSpotXLSXParser())
        XCTAssertEqual(o.inserted, 0, "0.01 과 0.01000000 은 같은 수량이다")
        XCTAssertEqual(o.skippedDupe, 1)
        XCTAssertEqual(project.events.count, 1)
    }

    /// 프리셋으로 한 번, 제네릭 매핑으로 한 번 → 한 번만
    func testSameTradeViaDifferentParsersCountsOnce() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = try ProjectService(modelContext: ctx).createProject(name: "parsers")
        let acc = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let svc = ImportService(modelContext: ctx)

        let preset = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        """
        _ = try svc.importText(preset, fileName: "spot.csv", project: project, account: acc, parser: BinanceSpotXLSXParser())

        // 같은 거래를 제네릭 컬럼 매핑으로 다시 (수수료 컬럼 이름만 다름)
        let generic = """
        Date,Type,Asset,Quote Asset,Amount,Price,Total,Fee,Fee Coin
        2027-06-01 10:00:00,buy,BTC,USDT,0.01,50000,500,0,USDT
        """
        let o = try svc.importText(generic, fileName: "manual.csv", project: project, account: acc,
                                   parser: GenericTabularMapper())
        XCTAssertEqual(o.inserted, 0, "파서가 달라도 같은 계정의 같은 거래다")
        XCTAssertEqual(project.events.count, 1)
    }

    func testCanonicalDecimalStripsPadding() {
        XCTAssertEqual(Fingerprint.canonicalDecimal(Decimal(string: "0.01000000")!), "0.01")
        XCTAssertEqual(Fingerprint.canonicalDecimal(Decimal(string: "0.01")!), "0.01")
        XCTAssertEqual(Fingerprint.canonicalDecimal(Decimal(string: "500.00")!), "500")
        XCTAssertEqual(Fingerprint.canonicalDecimal(Decimal(string: "100")!), "100")
        XCTAssertEqual(Fingerprint.canonicalDecimal(Decimal(string: "-0.5000")!), "-0.5")
        XCTAssertEqual(Fingerprint.canonicalDecimal(Decimal(0)), "0")
    }

    /// 같은 파일을 다른 계정에 넣으려 하면 파일 단계에서 먼저 막는다 (계정 오지정 방지)
    func testSameFileIntoAnotherAccountIsRejected() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = try ProjectService(modelContext: ctx).createProject(name: "accounts")
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let okx = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "okx" })
        let svc = ImportService(modelContext: ctx)

        let text = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        """
        _ = try svc.importText(text, fileName: "a.csv", project: project, account: binance, parser: BinanceSpotXLSXParser())
        XCTAssertThrowsError(
            try svc.importText(text, fileName: "b.csv", project: project, account: okx, parser: BinanceSpotXLSXParser())
        ) { err in
            XCTAssertEqual((err as? CoinTaxError)?.code, "E_DUPLICATE_FILE")
        }
        XCTAssertEqual(project.events.count, 1)
    }

    /// 계정이 다르면 별개 원장이므로 내용이 같아도 합치지 않는다 (의도된 동작)
    func testDifferentAccountsKeepSeparateLedgers() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = try ProjectService(modelContext: ctx).createProject(name: "accounts")
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let okx = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "okx" })
        let svc = ImportService(modelContext: ctx)

        let a = """
        Date(UTC),Pair,Base Asset,Quote Asset,Type,Price,Amount,Total,Fee,Fee Coin
        2027-06-01 10:00:00,BTC/USDT,BTC,USDT,BUY,50000,0.01,500,0,USDT
        """
        // 파일 내용은 다르지만(주석 한 줄) 거래 내용은 동일
        let b = a + "\n2027-08-01 10:00:00,BTC/USDT,BTC,USDT,BUY,53000,0.05,2650,0,USDT"
        _ = try svc.importText(a, fileName: "a.csv", project: project, account: binance, parser: BinanceSpotXLSXParser())
        let o = try svc.importText(b, fileName: "b.csv", project: project, account: okx, parser: BinanceSpotXLSXParser())
        XCTAssertEqual(o.inserted, 2, "계정이 다르면 같은 내용이라도 각각의 원장에 남는다")
        XCTAssertEqual(project.events.count, 3)
    }
}
