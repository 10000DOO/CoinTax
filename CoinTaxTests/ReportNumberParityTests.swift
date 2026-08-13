import XCTest
import PDFKit
@testable import CoinTax

/// **화면·CSV·PDF 가 같은 숫자를 적는가** + 저장·복원에서 값이 깨지지 않는가.
///
/// 사용자는 화면이 아니라 **파일을 보고 신고서에 옮겨 적는다.** 그래서 셋이 다르면
/// 계산이 맞아도 신고 금액이 틀린다. 3차 감사에서 총액이 어긋난 것을 고쳤고(D-7),
/// 4차 감사에서 **단가** 칸이 남아 있던 것을 고쳤다 (D4-2).
final class ReportNumberParityTests: XCTestCase {

    private func makeSummary(deemed: [DeemedPosition], disposals: [DisposalRecord] = []) -> TaxYearSummary {
        var s = TaxYearSummary(
            projectID: ProjectID(), taxYear: 2027, status: .verified,
            policyBundleID: PolicyBundle.v1Default.id,
            totalProceedsKRW: 0, totalCostsKRW: 0, netIncomeKRW: 0,
            basicDeductionKRW: 2_500_000, taxBaseKRW: 0,
            nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
            abandonedTransferCostKRW: 0, disposals: disposals, deemed: deemed,
            disclaimers: TaxCopy.all, calculatedAt: Date(), verification: nil
        )
        s.verification = VerificationReport(runID: UUID(), status: "passed", issues: [], calculatedAt: Date())
        return s
    }

    private func pdfText(_ data: Data) -> String {
        guard let doc = PDFDocument(data: data) else { return "" }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    /// 한 개에 1원이 안 되는 코인(SHIB·PEPE 등)의 **의제취득단가**.
    /// 원 단위로 반올림하면 0이 되고, 그 파일을 보고 신고서를 쓰면 취득가액이 0원이 된다.
    func testSubWonUnitPriceSurvivesExport() throws {
        let unit = Decimal(string: "0.031")!
        let qty = Decimal(string: "10000000")!
        let deemed = DeemedPosition(
            accountID: AccountID(), asset: AssetSymbol("SHIB"), quantity: qty,
            bookUnitKRW: Decimal(string: "0.02")!, marketUnitKRW: unit,
            deemedUnitKRW: unit, reason: "market"
        )
        let summary = makeSummary(deemed: [deemed])

        // 화면은 원래부터 소수를 보여준다 — 파일이 화면을 따라가야 한다
        XCTAssertEqual(Fmt.unitPriceString(unit), "₩0.031")

        let csv = try ReportCSVExporter.exportCSV(summary)
        let deemedLine = csv.split(separator: "\n").first { $0.hasPrefix("deemed,SHIB") }
        XCTAssertNotNil(deemedLine)
        XCTAssertTrue(deemedLine!.contains("0.031"), "CSV 의제 단가가 뭉개졌다 — \(deemedLine!)")

        // 검산할 수 있도록 장부·시가·그 자산의 취득가 총액도 함께 나가야 한다
        let detail = csv.split(separator: "\n").first { $0.hasPrefix("deemedDetail,SHIB") }
        XCTAssertNotNil(detail, "CSV 에 의제 상세 행이 없다")
        XCTAssertTrue(detail!.contains("0.02") && detail!.contains("0.031") && detail!.contains("310000"),
                      "CSV 의제 상세가 장부·시가·총액을 담지 않았다 — \(detail!)")
        XCTAssertTrue(csv.contains("totalDeemedCostKRW"), "CSV 에 채택 방식 의제취득가 총액이 없다")

        let text = pdfText(try ReportPDFExporter.exportPDF(summary))
        XCTAssertFalse(text.contains("채택=0 "), "PDF 의제 단가가 0으로 찍혔다")
        XCTAssertTrue(text.contains("0.031"), "PDF 의제 단가가 뭉개졌다")
        XCTAssertTrue(text.contains("합계(채택 방식 의제취득가)"), "PDF 에 의제취득가 합계가 없다")
    }

    /// 1원 이상인 값은 화면·CSV·PDF 모두 **원 단위**로 같아야 한다 (감사 D-7 회귀 방지).
    func testKRWTotalsAgreeAcrossScreenAndFiles() throws {
        let messy = Decimal(string: "4637202.9")!
        let d = DisposalRecord(
            id: UUID(), eventID: EventID(), timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 3),
            accountID: AccountID(), asset: AssetSymbol("BTC"), quantity: 1,
            proceedsKRW: messy, costKRW: 0, feesKRW: 0, pnlKRW: messy,
            method: .fifo, taxYear: 2027
        )
        var summary = makeSummary(deemed: [], disposals: [d])
        summary.totalProceedsKRW = messy
        summary.netIncomeKRW = messy

        XCTAssertEqual(Fmt.krwString(messy), "₩4,637,203")
        let csv = try ReportCSVExporter.exportCSV(summary)
        XCTAssertTrue(csv.contains("tax,totalProceedsKRW,4637203"), "CSV 총액이 화면과 다르다")
        XCTAssertFalse(csv.contains("4637202.9"), "CSV 에 반올림 전 값이 남아 있다")
        let text = pdfText(try ReportPDFExporter.exportPDF(summary))
        XCTAssertTrue(text.contains("4637203"), "PDF 총액이 화면과 다르다")
    }

    /// 코인 **수량**과 **환율**은 반올림하면 안 된다 — 소수 자리가 의미를 갖는다.
    func testQuantityAndFXAreNotRounded() throws {
        let qty = Decimal(string: "0.12345678")!
        let d = DisposalRecord(
            id: UUID(), eventID: EventID(), timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 3),
            accountID: AccountID(), asset: AssetSymbol("BTC"), quantity: qty,
            proceedsKRW: 1_000_000, costKRW: 0, feesKRW: 0, pnlKRW: 1_000_000,
            method: .fifo, taxYear: 2027,
            fxRateUsed: Decimal(string: "1385.7")!, fxSourceDate: "2027-05-03"
        )
        let csv = try ReportCSVExporter.exportCSV(makeSummary(deemed: [], disposals: [d]))
        XCTAssertTrue(csv.contains("0.12345678"), "CSV 수량이 반올림됐다")
        XCTAssertTrue(csv.contains("1385.7"), "CSV 환율이 반올림됐다")
    }

    // MARK: - 저장·복원

    func testExtremeDecimalsSurviveEntityRoundTrip() throws {
        let samples: [Decimal] = [
            Decimal(string: "0.123456789012345678")!,
            Decimal(string: "12345678901234567890123456789")!,
            Decimal(string: "-0.00000000000000000001")!,
            Decimal(string: "0.000000000000000000000000000031")!,
            0
        ]
        for v in samples {
            var e = LedgerEvent(
                projectID: ProjectID(), accountID: AccountID(), timestamp: Date(),
                type: .buy, baseAsset: AssetSymbol("ETH"), quoteAsset: AssetSymbol("USDT"),
                quantity: v, price: v, quoteAmount: v, quoteAmountKRW: v,
                feeAmount: v, feeAsset: AssetSymbol("BNB"),
                sourceKind: "parity", balanceAfter: v, quoteBalanceAfter: v
            )
            e.fingerprint = "fp"
            let back = EntityMappers.event(EntityMappers.makeEntity(from: e), projectID: e.projectID)
            XCTAssertEqual(back.quantity, v, "수량 왕복 손실")
            XCTAssertEqual(back.price, v, "단가 왕복 손실")
            XCTAssertEqual(back.feeAmount, v, "수수료 왕복 손실")
            XCTAssertEqual(back.balanceAfter, v, "잔고 왕복 손실")
            XCTAssertEqual(back.quoteBalanceAfter, v, "견적 잔고 왕복 손실")
        }
    }

    func testSnapshotJSONRoundTrip() throws {
        let qty = Decimal(string: "0.123456789012345678")!
        let d = DisposalRecord(
            id: UUID(), eventID: EventID(), timestamp: Date(), accountID: AccountID(),
            asset: AssetSymbol("ETH"), quantity: qty,
            proceedsKRW: Decimal(string: "1234567.89")!,
            costKRW: Decimal(string: "1000000.01")!,
            feesKRW: Decimal(string: "0.031")!,
            pnlKRW: Decimal(string: "234567.849")!,
            method: .fifo, taxYear: 2027,
            fxRateUsed: Decimal(string: "1385.7")!, fxSourceDate: "2027-03-01", deemedApplied: true
        )
        let summary = makeSummary(
            deemed: [DeemedPosition(accountID: AccountID(), asset: AssetSymbol("SHIB"),
                                    quantity: 10_000_000, bookUnitKRW: Decimal(string: "0.02")!,
                                    marketUnitKRW: Decimal(string: "0.031")!,
                                    deemedUnitKRW: Decimal(string: "0.031")!, reason: "market")],
            disposals: [d]
        )
        let back = try JSONDecoder().decode(TaxYearSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(back.disposals.first?.quantity, qty)
        XCTAssertEqual(back.disposals.first?.pnlKRW, d.pnlKRW)
        XCTAssertEqual(back.disposals.first?.fxRateUsed, d.fxRateUsed)
        XCTAssertEqual(back.deemed.first?.deemedUnitKRW, Decimal(string: "0.031")!)
        XCTAssertEqual(back.totalDeemedCostKRW, summary.totalDeemedCostKRW)
    }

    // MARK: - 신고 안내·필요경비 의제가 파일에도 실리는가 (이번 회차 추가분)

    /// 사용자는 **파일을 보고 신고서를 쓴다.** 화면에만 있는 안내는 없는 것과 같다.
    func testFilingGuideAppearsInCSVAndPDF() throws {
        var s = makeSummary(deemed: [])
        s.verification = VerificationReport(runID: UUID(), status: "passed", issues: [], calculatedAt: Date())

        let csv = try ReportCSVExporter.exportCSV(s)
        for g in TaxCopy.filingGuide {
            XCTAssertTrue(csv.contains(g.prefix(20)), "CSV 에 신고 안내가 빠졌다: \(g.prefix(20))")
        }

        let pdf = try ReportPDFExporter.exportPDF(s)
        let text = (PDFDocument(data: pdf)?.string ?? "")
        XCTAssertTrue(text.contains("위택스"), "PDF 에 지방소득세 납부처가 빠졌다")
        XCTAssertTrue(text.contains("홈택스에 낼 국세"))
    }

    /// `[법]` §37⑥ 을 켰으면 **어느 자산에 적용했는지**가 파일에 남아야 한다 —
    /// 나중에 「이 숫자는 어떤 필요경비로 계산했나」에 답할 수 있어야 한다.
    func testProxyExpenseIsRecordedInExports() throws {
        var s = makeSummary(deemed: [])
        s.verification = VerificationReport(runID: UUID(), status: "passed", issues: [], calculatedAt: Date())
        s.proxyExpenseAssets = ["BTC"]
        s.proxyExpenseAlternative = DeemedAlternative(
            basisMode: "proxy_off", basisLabel: "의제 50%를 쓰지 않으면",
            totalDeemedCostKRW: 31_000_000, netIncomeKRW: 69_000_000, totalTaxKRW: 14_630_000
        )

        let csv = try ReportCSVExporter.exportCSV(s)
        XCTAssertTrue(csv.contains("proxyExpense50Assets"))
        XCTAssertTrue(csv.contains("proxyAlt"))

        let text = (PDFDocument(data: try ReportPDFExporter.exportPDF(s))?.string ?? "")
        XCTAssertTrue(text.contains("필요경비 의제 50%"))
        XCTAssertTrue(text.contains("BTC"))
        XCTAssertTrue(text.contains("수수료를 따로 빼지 않습니다"), "조문 후단(부대비용 불산입)이 파일에도 남아야 한다")
    }
}
