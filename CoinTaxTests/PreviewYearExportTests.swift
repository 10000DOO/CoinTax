import XCTest
@testable import CoinTax

/// 과세 시작 **전** 연도(예상 계산)의 내보내기가 화면과 같은 것을 담는가 (5차 감사 회차 25).
///
/// 리포트 화면은 예상 연도에서 의제취득가 표를 **일부러 감춘다** —
/// 「의제취득가는 2027 이후 처분에만 쓰인다. 예상 연도에서는 볼 이유가 없다」(ReportView).
/// 그런데 CSV·PDF 는 연도를 보지 않고 그대로 실었다.
/// 4차 감사(D-7·D4-2)가 세운 원칙이 있다 — **사용자는 화면이 아니라 파일을 보고 신고서를 쓴다.**
/// 화면이 감춘 것을 파일이 실으면 그 원칙이 반대로 깨진다.
final class PreviewYearExportTests: XCTestCase {

    private func summary(taxYear: Int) -> TaxYearSummary {
        let pid = ProjectID()
        let disposal = DisposalRecord(
            id: UUID(), eventID: EventID(),
            timestamp: TaxTime.dateKST(year: taxYear, month: 6, day: 1),
            accountID: AccountID(), asset: AssetSymbol("BTC"), quantity: 1,
            proceedsKRW: 60_000_000, costKRW: 50_000_000, feesKRW: 0,
            pnlKRW: 10_000_000, method: .fifo, taxYear: taxYear
        )
        let deemed = DeemedPosition(
            accountID: AccountID(), asset: AssetSymbol("BTC"), quantity: 2,
            bookUnitKRW: 50_000_000, marketUnitKRW: 60_000_000,
            deemedUnitKRW: 60_000_000, reason: "market"
        )
        var s = TaxAggregator.aggregate(
            projectID: pid, disposals: [disposal], taxYear: taxYear,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: [deemed], policies: .v1Default
        )
        s.verification = VerificationReport(runID: UUID(), status: "passed", issues: [], calculatedAt: Date())
        return s
    }

    /// 과세연도(2027 이후)에는 파일에 의제취득가가 있어야 한다 — 신고서 취득가액 칸의 근거다
    func testTaxYearExportKeepsDeemedSection() throws {
        let csv = try ReportCSVExporter.exportCSV(summary(taxYear: 2027))
        XCTAssertTrue(csv.contains("\ndeemed,"), "과세연도인데 의제취득가가 파일에서 빠졌다")
        XCTAssertTrue(csv.contains("totalDeemedCostKRW"))

        let pdf = try ReportPDFExporter.exportPDF(summary(taxYear: 2027))
        XCTAssertFalse(pdf.isEmpty)
    }

    /// 내보낸 CSV 를 **다시 읽을 수 있는가** — 쉼표·따옴표가 섞여도 열이 밀리지 않아야 한다.
    ///
    /// 이 파일은 사용자가 표 도구로 열어 신고서에 옮겨 적는 결과물이다.
    /// 열이 하나라도 밀리면 엉뚱한 칸의 숫자를 베낀다.
    func testCSVSurvivesReparsingWithTrickyText() throws {
        var s = summary(taxYear: 2027)
        s.verification = VerificationReport(
            runID: UUID(), status: "passedWithWarnings",
            issues: [
                .init(id: "V-QTY-02", severity: "warning",
                      message: "보유보다 많은 매도입니다, 더 이전 기간 원본을 가져오세요",
                      context: "BTC, 2027-06-01 \"row12\""),
                .init(id: "V-FX-02", severity: "warning",
                      message: "참고 시세가 쓰였습니다 (\"공식 기준환율\" 아님)", context: nil)
            ],
            calculatedAt: Date()
        )
        let csv = try ReportCSVExporter.exportCSV(s)
        let rows = CSVUtil.parseLines(csv)
        XCTAssertGreaterThan(rows.count, 10)
        XCTAssertEqual(rows.first, ["section", "key", "value1", "value2", "value3"])
        // 고정 5열이 무너지면 표 도구가 깨진다
        let wrongWidth = rows.enumerated().filter { $0.element.count != 5 }
        XCTAssertTrue(wrongWidth.isEmpty,
                      "열 수가 5가 아닌 행: " + wrongWidth.map { "\($0.offset)행=\($0.element.count)열" }.joined(separator: ", "))
        // 쉼표·따옴표가 든 값이 원래 모양으로 돌아오는가
        let flat = rows.flatMap { $0 }
        XCTAssertTrue(flat.contains("보유보다 많은 매도입니다, 더 이전 기간 원본을 가져오세요"))
        XCTAssertTrue(flat.contains("BTC, 2027-06-01 \"row12\""))
        XCTAssertTrue(flat.contains("참고 시세가 쓰였습니다 (\"공식 기준환율\" 아님)"))
    }

    /// **예상 연도**에는 화면이 감추는 것을 파일도 감춰야 한다
    func testPreviewYearExportOmitsDeemedSection() throws {
        let s = summary(taxYear: 2026)
        XCTAssertLessThan(s.taxYear, TaxTime.taxStartYear, "예상 연도여야 이 검사가 의미 있다")

        let csv = try ReportCSVExporter.exportCSV(s)
        XCTAssertTrue(csv.contains("estimateOnly"), "예상 연도 표시가 있어야 한다")
        XCTAssertFalse(
            csv.contains("\ndeemed,"),
            "화면은 감추는 의제취득가를 파일이 실었다 — 신고서에 옮겨 적을 값으로 오해한다"
        )
        XCTAssertFalse(csv.contains("totalDeemedCostKRW"))
        XCTAssertFalse(csv.contains("deemedDetail"))
    }
}
