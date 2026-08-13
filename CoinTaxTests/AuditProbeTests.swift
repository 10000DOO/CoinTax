import XCTest
@testable import CoinTax

/// 감사용 **탐침** 테스트 (2026-08-12 3차 감사).
///
/// 여기 있는 단정값은 「지금 코드가 이렇게 동작한다」를 기록한 것이 아니라,
/// **문서가 정한 규칙에서 손으로 계산한 값**이다. 코드가 다르면 코드를 의심한다.
/// 확정된 결함은 정식 회귀 테스트로 옮기고 이 파일은 정리한다.
final class AuditProbeTests: XCTestCase {

    // MARK: - 공통

    private func fifoAccount() -> Account {
        Account.defaults(for: .binance, projectID: ProjectID())
    }

    private func maAccount(projectID: ProjectID) -> Account {
        Account.defaults(for: .bithumb, projectID: projectID)
    }

    private func replay(
        _ events: [LedgerEvent],
        accounts: [Account],
        links: [TransferLink] = [],
        fx: [String: Decimal] = [:],
        market: [String: Decimal] = [:],
        policies: PolicyBundle = .v1Default
    ) throws -> ReplayResult {
        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: fx,
            marketPrices: market
        )
        return try engine.replay(events: events, links: links)
    }

    private func verify(
        _ r: ReplayResult,
        events: [LedgerEvent],
        summary: TaxYearSummary,
        links: [TransferLink] = [],
        policies: PolicyBundle = .v1Default
    ) -> VerificationReport {
        Verifier.verify(VerifierInput(
            summary: summary, replay: r, policies: policies,
            events: events, summaryRerun: summary, links: links
        ))
    }

    private func summarize(_ r: ReplayResult, projectID: ProjectID, year: Int, policies: PolicyBundle = .v1Default) -> TaxYearSummary {
        TaxAggregator.aggregate(
            projectID: projectID, disposals: r.disposals, taxYear: year,
            extraDeductible: r.extraDeductibleByYear[year] ?? 0,
            abandonedTransferCostKRW: r.abandonedByYear[year] ?? 0,
            deemed: r.deemedPositions, policies: policies
        )
    }

    // MARK: - C-1 수수료 자산이 비어 있을 때

    /// 매도에 수수료 금액은 있는데 **수수료 자산이 없으면**,
    /// 엔진은 「기초자산으로 낸 것」으로 보고 그 코인을 장부에서 빼고,
    /// 수량 규칙 한 벌(LedgerDelta)은 아무것도 빼지 않는다 → 정상 자료가 Critical 로 막힌다.
    func testProbe_C1_sellFeeWithoutFeeAsset() throws {
        let acc = fifoAccount()
        let pid = acc.projectID
        let buy = LedgerEvent(
            projectID: pid, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
            type: .buy, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10, quoteAmountKRW: 1_000, sourceKind: "probe", rawRef: "s1"
        )
        let sell = LedgerEvent(
            projectID: pid, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .sell, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
            quantity: -2, quoteAmountKRW: 500,
            feeAmount: Decimal(string: "0.5"), feeAsset: nil,   // ← 자산 미기재
            sourceKind: "probe", rawRef: "s2"
        )
        let r = try replay([buy, sell], accounts: [acc])
        let holding = r.holdings.rows.first { $0.asset.code == "XYZ" }?.quantity ?? 0

        // LedgerDelta 가 보는 기대 수량 (검증기·잔고대조가 쓰는 규칙 한 벌)
        let expected = [buy, sell].flatMap { LedgerDelta.bookChanges(for: $0) }
            .reduce(Decimal(0)) { $0 + $1.delta }

        let s = summarize(r, projectID: pid, year: 2027)
        let report = verify(r, events: [buy, sell], summary: s)
        let qty01 = report.issues.filter { $0.id == "V-QTY-01" && $0.severity == "critical" }

        print("PROBE C-1: 엔진 보유=\(Money.decimalString(holding)) / 규칙 기대=\(Money.decimalString(expected)) / V-QTY-01 critical=\(qty01.count)")
        XCTAssertEqual(holding, expected, "엔진과 수량 규칙이 같은 답을 내야 한다")
        XCTAssertTrue(qty01.isEmpty, "정상 자료에서 V-QTY-01 Critical 이 나면 안 된다: \(qty01.map(\.message))")
    }

    /// 매수도 같은 조건에서 **수수료가 통째로 사라진다** — 취득가가 그만큼 작아진다.
    /// 같은 경제적 거래인데 원본이 수수료 자산을 적었는지 여부로 취득가가 달라지면 안 된다.
    func testProbe_C1b_buyFeeWithoutFeeAssetIsDropped() throws {
        func cost(feeAsset: AssetSymbol?) throws -> Decimal {
            let acc = fifoAccount()
            let buy = LedgerEvent(
                projectID: acc.projectID, accountID: acc.id,
                timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
                type: .buy, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
                quantity: 10, quoteAmountKRW: 1_000,
                feeAmount: 50, feeAsset: feeAsset, sourceKind: "probe", rawRef: "s1"
            )
            let r = try replay([buy], accounts: [acc])
            return r.holdings.rows.first { $0.asset.code == "XYZ" }?.totalCostKRW ?? 0
        }
        let withAsset = try cost(feeAsset: AssetSymbol("KRW"))
        let without = try cost(feeAsset: nil)
        print("PROBE C-1b: 수수료자산 기재=\(Money.decimalString(withAsset)) / 미기재=\(Money.decimalString(without))")
        XCTAssertEqual(withAsset, without, "수수료 자산 기재 여부로 취득가액이 달라지면 안 된다")
    }

    /// 제네릭 매핑처럼 「fee」 열만 있고 「fee coin」 열이 없는 파일 —
    /// 수수료가 **원화 금액**이면 그 숫자만큼 코인을 처분한다.
    func testProbe_C1c_krwFeeAmountConsumesCoins() throws {
        let acc = fifoAccount()
        let buy = LedgerEvent(
            projectID: acc.projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
            type: .buy, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10_000, quoteAmountKRW: 10_000_000, sourceKind: "probe", rawRef: "s1"
        )
        // 원화 수수료 1,500원인데 자산 칸이 비어 있다
        let sell = LedgerEvent(
            projectID: acc.projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .sell, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1_000, quoteAmountKRW: 1_200_000,
            feeAmount: 1_500, feeAsset: nil, sourceKind: "probe", rawRef: "s2"
        )
        let r = try replay([buy, sell], accounts: [acc])
        let holding = r.holdings.rows.first { $0.asset.code == "XYZ" }?.quantity ?? 0
        print("PROBE C-1c: 남은 수량=\(Money.decimalString(holding)) (기대 9000)")
        XCTAssertEqual(holding, 9_000, "원화 수수료가 코인 수량을 깎으면 안 된다")
    }

    // MARK: - C-2 OKX 매도 총수입금액이 순액인가

    /// OKX 실파일 구조: 한 주문이 두 줄(받는 자산 / 주는 자산)이고,
    /// **받는 쪽 Balance Change 는 수수료를 이미 뺀 값**이다.
    /// 문서(IMPLEMENTATION §6.4)는 「총액 기준 통일」이므로 양도가액은 1,000 USDT 여야 한다.
    func testProbe_C2_okxSellProceedsShouldBeGross() throws {
        let csv = """
        UID:000,Account Type:Main,Time Zone:UTC+9
        id,Order id,Time,Trade Type,Symbol,Action,Amount,Trading Unit,Filled Price,PnL,Fee,Fee Unit,Position Change,Position Balance,Balance Change,Balance,Balance Unit
        11,500,2027-03-01 10:00:00,Spot,BTC-USDT,Buy,1000,BTC,100000,0,-1,USDT,0,0,999,999,USDT
        10,500,2027-03-01 10:00:00,Spot,BTC-USDT,Sell,0.01,BTC,100000,0,0,BTC,0,0,-0.01,0,BTC
        """
        let acc = Account.defaults(for: .okx, projectID: ProjectID())
        let result = try OKXTradingHistoryCSVParser().parse(
            text: csv, fileName: "OKX Trading History.csv",
            projectID: acc.projectID, accountID: acc.id
        )
        let e = try XCTUnwrap(result.events.first { $0.type == .sell })
        print("PROBE C-2: quoteAmount=\(e.quoteAmount.map(Money.decimalString) ?? "nil") feeAmount=\(e.feeAmount.map(Money.decimalString) ?? "nil") feeAsset=\(e.feeAsset?.code ?? "nil")")
        XCTAssertEqual(e.quoteAmount, 1_000, "양도가액은 수수료 차감 전 총액이어야 한다 (총액 기준 통일)")
        XCTAssertEqual(e.feeAmount, 1, "견적자산으로 낸 수수료도 읽어야 한다")
        XCTAssertEqual(e.feeAsset?.code, "USDT")
    }

    // MARK: - C-3 원가법 정책이 계산에 강제되는가

    /// 문서는 「빗썸 = 이동평균」으로 잠겨 있다 (05-decisions §1.2).
    /// 계정에 저장된 값이 어떻든 정책이 이겨야 한다.
    func testProbe_C3_costMethodPolicyIsEnforced() throws {
        let pid = ProjectID()
        // 저장된 값이 FIFO 로 틀어진 빗썸 계정
        var bithumb = Account.defaults(for: .bithumb, projectID: pid)
        bithumb.costMethod = .fifo

        XCTAssertEqual(
            VASPMAElseFIFOResolver().method(for: bithumb), .movingAverage,
            "정책은 빗썸을 이동평균으로 본다"
        )
        let buy1 = LedgerEvent(projectID: pid, accountID: bithumb.id,
                               timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2),
                               type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                               quantity: 1, quoteAmountKRW: 40_000_000, sourceKind: "probe", rawRef: "s1")
        let buy2 = LedgerEvent(projectID: pid, accountID: bithumb.id,
                               timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 3),
                               type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                               quantity: 1, quoteAmountKRW: 80_000_000, sourceKind: "probe", rawRef: "s2")
        let sell = LedgerEvent(projectID: pid, accountID: bithumb.id,
                               timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 4),
                               type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                               quantity: -1, quoteAmountKRW: 70_000_000, sourceKind: "probe", rawRef: "s3")
        let r = try replay([buy1, buy2, sell], accounts: [bithumb])
        let cost = r.disposals.first?.costKRW ?? 0
        print("PROBE C-3: 사용된 취득원가=\(Money.decimalString(cost)) (이동평균 6천만 / FIFO 4천만)")
        XCTAssertEqual(cost, 60_000_000, "정책(이동평균)이 저장 값(FIFO)을 이겨야 한다")
    }

    // MARK: - V1 2027 과세 경로 — 손으로 계산한 값

    /// 종이 계산:
    ///   2026-06-01 빗썸 USDT 1,000개 취득 1,300,000원 (단가 1,300)
    ///   2027-01-01 0시 시가 1,500 → 의제단가 max(1300,1500)=1500 → 의제 총액 1,500,000
    ///   2027-03-02 전량 매도: 거래금액 6,000,000 / 정산금액 5,990,000 → 수수료 10,000
    ///   손익 = 6,000,000 − 1,500,000 − 10,000 = 4,490,000
    ///   과세표준 = 4,490,000 − 2,500,000 = 1,990,000
    ///   국세 = 398,000 · 지방세 = 39,800 · 합계 437,800
    func testProbe_V1_deemedThenSellIn2027() throws {
        let pid = ProjectID()
        let bithumb = maAccount(projectID: pid)
        let buy = LedgerEvent(
            projectID: pid, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1_000, quoteAmountKRW: 1_300_000, sourceKind: "probe", rawRef: "s1"
        )
        let sell = LedgerEvent(
            projectID: pid, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 2, hour: 10),
            type: .sell, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1_000, quoteAmountKRW: 6_000_000,
            feeAmount: 10_000, feeAsset: AssetSymbol("KRW"), sourceKind: "probe", rawRef: "s2"
        )
        let r = try replay([buy, sell], accounts: [bithumb], market: ["USDT": 1_500])
        let dem = try XCTUnwrap(r.deemedPositions.first)
        XCTAssertEqual(dem.bookUnitKRW, 1_300)
        XCTAssertEqual(dem.deemedUnitKRW, 1_500)
        XCTAssertEqual(dem.reason, "market")

        let d = try XCTUnwrap(r.disposals.first { $0.timestamp >= TaxTime.taxStartDate })
        XCTAssertEqual(d.proceedsKRW, 6_000_000, "양도가액은 거래금액 총액")
        XCTAssertEqual(d.costKRW, 1_500_000, "취득가액은 의제취득가")
        XCTAssertEqual(d.feesKRW, 10_000, "매도 수수료는 필요경비")
        XCTAssertEqual(d.pnlKRW, 4_490_000)

        let s = summarize(r, projectID: pid, year: 2027)
        XCTAssertEqual(s.totalProceedsKRW, 6_000_000)
        XCTAssertEqual(s.totalCostsKRW, 1_510_000)
        XCTAssertEqual(s.netIncomeKRW, 4_490_000)
        XCTAssertEqual(s.taxBaseKRW, 1_990_000)
        XCTAssertEqual(s.nationalTaxKRW, 398_000)
        XCTAssertEqual(s.localTaxKRW, 39_800)
        XCTAssertEqual(s.totalTaxKRW, 437_800)

        let report = verify(r, events: [buy, sell], summary: s)
        let crit = report.issues.filter { $0.severity == "critical" }
        print("PROBE V1: critical=\(crit.map { "\($0.id) \($0.message)" })")
        XCTAssertTrue(crit.isEmpty, "정상 시나리오에서 Critical 이 나면 안 된다")
    }

    /// 과세 시작 경계 — 1초 차이로 신고 대상이 갈려야 한다.
    func testProbe_V1_taxStartBoundary() throws {
        func tax(at t: Date) throws -> Decimal {
            let pid = ProjectID()
            let acc = maAccount(projectID: pid)
            let buy = LedgerEvent(projectID: pid, accountID: acc.id,
                                  timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
                                  type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
                                  quantity: 1_000, quoteAmountKRW: 1_000_000, sourceKind: "probe", rawRef: "s1")
            let sell = LedgerEvent(projectID: pid, accountID: acc.id, timestamp: t,
                                   type: .sell, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
                                   quantity: -1_000, quoteAmountKRW: 20_000_000, sourceKind: "probe", rawRef: "s2")
            let r = try replay([buy, sell], accounts: [acc], market: ["USDT": 1_000])
            return summarize(r, projectID: pid, year: 2027).totalTaxKRW
        }
        let justBefore = try tax(at: TaxTime.dateKST(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        let justAfter = try tax(at: TaxTime.dateKST(year: 2027, month: 1, day: 1, hour: 0, minute: 0, second: 0))
        print("PROBE 경계: 2026-12-31 23:59:59 세액=\(Money.decimalString(justBefore)) / 2027-01-01 00:00:00 세액=\(Money.decimalString(justAfter))")
        XCTAssertEqual(justBefore, 0, "과세 시작 전 처분은 2027년 세액에 들어가면 안 된다")
        XCTAssertGreaterThan(justAfter, 0, "과세 시작 직후 처분은 과세 대상이다")
    }

    /// TQ-01 문서 예시 그대로: 4천만·8천만에 각 1개, 시가 6천만.
    ///   평균 방식 의제 = 1.2억 / 건별 방식 = 1.4억 → 차이 2천만 → 세액 차이 440만
    func testProbe_V1_deemedBasisModesMatchDocExample() throws {
        func deemedTotal(_ mode: DeemedBasisMode) throws -> Decimal {
            let pid = ProjectID()
            let acc = Account.defaults(for: .binance, projectID: pid)  // FIFO
            var policies = PolicyBundle.v1Default
            policies.deemed = MaxBookMarketDeemedPolicy(mode: mode)
            let b1 = LedgerEvent(projectID: pid, accountID: acc.id,
                                 timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
                                 type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                                 quantity: 1, quoteAmountKRW: 40_000_000, sourceKind: "probe", rawRef: "s1")
            let b2 = LedgerEvent(projectID: pid, accountID: acc.id,
                                 timestamp: TaxTime.dateKST(year: 2026, month: 4, day: 1),
                                 type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                                 quantity: 1, quoteAmountKRW: 80_000_000, sourceKind: "probe", rawRef: "s2")
            let r = try replay([b1, b2], accounts: [acc], market: ["BTC": 60_000_000], policies: policies)
            return r.deemedPositions.reduce(Decimal(0)) { $0 + $1.totalDeemedKRW }
        }
        // 「건별」 방식은 폐지됐다 (`[영]` §88① · 작업문서 Q1). 거주자 평균 하나만 남는다 —
        // 4천만·8천만에 1개씩, 시가 6천만 → 평균 6천만, max(6천만,6천만) × 2 = 1.2억
        let avg = try deemedTotal(.positionAverage)
        print("PROBE TQ-01: 거주자 평균=\(Money.decimalString(avg))")
        XCTAssertEqual(avg, 120_000_000)
    }

    // MARK: - V3 화면·CSV·PDF 가 같은 숫자를 적는가

    func testProbe_V3_exportMatchesScreenNumbers() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        // 환율을 곱해 소수가 남는 금액을 만든다 (실제 해외 거래가 이렇게 된다)
        let day = TaxTime.dateKST(year: 2027, month: 5, day: 4, hour: 12)
        let buy = LedgerEvent(projectID: pid, accountID: acc.id,
                              timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 3, hour: 12),
                              type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
                              quantity: 1, quoteAmount: 1_000, sourceKind: "probe", rawRef: "s1")
        let deposit = LedgerEvent(projectID: pid, accountID: acc.id,
                                  timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 2, hour: 12),
                                  type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 5_000,
                                  sourceKind: "probe", rawRef: "s0")
        let sell = LedgerEvent(projectID: pid, accountID: acc.id, timestamp: day,
                               type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
                               quantity: -1, quoteAmount: 3_333, sourceKind: "probe", rawRef: "s2")
        let fx: [String: Decimal] = [
            "2027-05-02": Decimal(string: "1383.7")!,
            "2027-05-03": Decimal(string: "1383.7")!,
            "2027-05-04": Decimal(string: "1391.3")!
        ]
        let r = try replay([deposit, buy, sell], accounts: [acc], fx: fx)
        var s = summarize(r, projectID: pid, year: 2027)
        s.verification = VerificationReport(runID: UUID(), status: "passedWithWarnings", issues: [], calculatedAt: Date())

        let csv = try ReportCSVExporter.exportCSV(s)
        let csvIncome = csv.split(separator: "\n").first { $0.hasPrefix("tax,netIncomeKRW") } ?? ""
        let screenIncome = Fmt.krwString(s.netIncomeKRW)
        print("PROBE V3: 원값=\(Money.decimalString(s.netIncomeKRW))")
        print("PROBE V3: CSV  =\(csvIncome)")
        print("PROBE V3: 화면 =\(screenIncome)")

        // CSV 에 적힌 값은 화면·PDF 와 같은 원 단위여야 한다
        let csvValue = csvIncome.split(separator: ",").last.map(String.init) ?? ""
        XCTAssertEqual(
            Decimal(string: csvValue), Money.roundKRW(s.netIncomeKRW),
            "CSV 가 화면·PDF 와 다른 자릿수를 적으면 신고서에 옮길 때 값이 달라진다"
        )
    }

    // MARK: - N-2 코인 바꾸기(Convert)의 견적이 원화 환산이 안 되는 자산일 때

    /// 바이낸스 Transaction History 의 「Binance Convert」는 BTC→USDT 처럼
    /// 견적이 스테이블이 아닐 수 있다. 그때 낸 코인이 장부에서 빠지지 않으면
    /// 보유 수량이 실제보다 많아진다 (바이낸스는 잔고 열이 없어 V-BAL 로도 못 잡는다).
    func testProbe_N2_convertWithNonPeggedQuote() throws {
        let acc = Account.defaults(for: .binance, projectID: ProjectID())
        let pid = acc.projectID
        let seed = LedgerEvent(projectID: pid, accountID: acc.id,
                               timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
                               type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
                               sourceKind: "probe", rawRef: "s0")
        // BTC 0.5 를 내고 USDT 를 받았다 (Convert → .buy, quote = BTC)
        let convert = LedgerEvent(projectID: pid, accountID: acc.id,
                                  timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 2),
                                  type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("BTC"),
                                  quantity: 50_000, quoteAmount: Decimal(string: "0.5"),
                                  sourceKind: "probe", rawRef: "s1")
        let r = try replay([seed, convert], accounts: [acc], fx: ["2027-02-02": 1_400])
        let btc = r.holdings.rows.first { $0.asset.code == "BTC" }?.quantity ?? 0
        print("PROBE N-2: BTC 잔량=\(Money.decimalString(btc)) (실제로는 0.5 여야 한다) · issues=\(r.issues.map(\.id))")
        XCTAssertEqual(btc, Decimal(string: "0.5"), "낸 코인은 장부에서 빠져야 한다")
    }
}
