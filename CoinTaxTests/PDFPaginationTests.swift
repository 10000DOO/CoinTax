import XCTest
import PDFKit
@testable import CoinTax

/// 거래가 많아 **여러 장으로 넘어갈 때도** 필수 고지가 온전한가 (5차 감사 회차 26).
///
/// 4차 감사(D-4)에서 필수 고지가 **문장 중간에서 잘려** 있었다 —
/// 고정폭 글꼴에서 한글이 영문의 두 배 폭이라 종이를 넘었고, `NSString.draw(in:)` 은 넘은 부분을
/// 그냥 버린다. 그때 고친 것은 「한 줄 안에서의 줄바꿈」이고,
/// **거래가 많아 장이 여러 개로 나뉘는 경우**는 빈 자료로만 확인돼 있었다.
final class PDFPaginationTests: XCTestCase {

    private func text(of data: Data) -> String {
        guard let doc = PDFDocument(data: data) else { return "" }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined()
    }

    /// PDF 는 줄바꿈·들여쓰기로 쪼개지므로 공백을 지우고 비교한다
    private func contains(_ haystack: String, _ needle: String) -> Bool {
        func squeeze(_ s: String) -> String {
            String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        }
        return squeeze(haystack).contains(squeeze(needle))
    }

    private func bigSummary(disposals: Int, issues: [VerificationIssue]) -> TaxYearSummary {
        let pid = ProjectID()
        let rows = (0..<disposals).map { i in
            DisposalRecord(
                id: UUID(), eventID: EventID(),
                timestamp: TaxTime.dateKST(year: 2027, month: 1 + (i % 12), day: 1 + (i % 27), hour: 10),
                accountID: AccountID(), asset: AssetSymbol("BTC"), quantity: 1,
                proceedsKRW: 60_000_000, costKRW: 50_000_000, feesKRW: 0,
                pnlKRW: 10_000_000, method: .fifo, taxYear: 2027
            )
        }
        let deemed = (0..<40).map { i in
            DeemedPosition(
                accountID: AccountID(), asset: AssetSymbol("A\(i)"), quantity: 1,
                bookUnitKRW: 1_000, marketUnitKRW: 2_000, deemedUnitKRW: 2_000, reason: "market"
            )
        }
        var s = TaxAggregator.aggregate(
            projectID: pid, disposals: rows, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: deemed, policies: .v1Default
        )
        s.fxSources = (0..<30).map { "2027-01-\(String(format: "%02d", 1 + $0 % 28)): 1400 (당일 고시)" }
        s.verification = VerificationReport(runID: UUID(), status: "passedWithWarnings",
                                            issues: issues, calculatedAt: Date())
        return s
    }

    /// 여러 장으로 나뉘어도 고지 4종·주의 4종·세무확인 19건이 **온전히** 남아야 한다
    func testNoticesSurviveAcrossManyPages() throws {
        let s = bigSummary(disposals: 300, issues: [])
        let data = try ReportPDFExporter.exportPDF(s)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(doc.pageCount, 3, "여러 장으로 나뉘어야 이 검사가 의미 있다 (\(doc.pageCount)장)")

        let body = text(of: data)
        var missing: [String] = []
        for d in TaxCopy.all where !contains(body, d) { missing.append("고지 «\(d.prefix(16))…»") }
        for n in TaxCopy.notices where !contains(body, n) { missing.append("주의 «\(n.prefix(16))…»") }
        for q in TaxOpenQuestions.all where !contains(body, q.title) { missing.append("세무확인 \(q.id)") }
        XCTAssertTrue(missing.isEmpty, "여러 장으로 넘어가며 빠진 항목: \(missing.joined(separator: ", "))")
    }

    /// 공백이 없는 긴 한글 문장(검증 메시지)도 **글자를 잃지 않고** 줄바꿈되어야 한다
    func testLongUnbrokenKoreanMessageIsNotTruncated() throws {
        let long = String(repeating: "보유수량보다많은매도입니다더이전기간원본을함께가져오세요", count: 4)
        let issue = VerificationIssue(id: "V-QTY-02", severity: "critical", message: long, context: nil)
        let s = bigSummary(disposals: 10, issues: [issue])
        let body = text(of: try ReportPDFExporter.exportPDF(s))
        XCTAssertTrue(
            contains(body, long),
            "공백 없는 긴 문장이 잘렸다 — 넘친 부분을 그냥 버리는 문제(4차 감사 D-4)와 같은 모양"
        )
    }

    /// 마지막 장의 쪽 번호가 실제 장수와 맞아야 한다 (잘못 세면 「뒤가 더 있나」 오해한다)
    func testPageFooterCountMatches() throws {
        let s = bigSummary(disposals: 200, issues: [])
        let data = try ReportPDFExporter.exportPDF(s)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let body = text(of: data)
        XCTAssertTrue(contains(body, "— \(doc.pageCount) / \(doc.pageCount) —"),
                      "마지막 쪽 번호가 실제 장수(\(doc.pageCount))와 다르다")
    }
}
