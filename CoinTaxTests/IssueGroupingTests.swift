import XCTest
@testable import CoinTax

/// 검증 결과 묶기 — 예전에는 앞 12건만 찍고 「외 N건」으로 끝나 나머지를 볼 방법이 없었다.
/// 묶는 과정에서 **항목이 사라지지 않는 것**이 이 화면의 유일한 계약이다.
@MainActor
final class IssueGroupingTests: XCTestCase {

    private func issue(_ id: String, _ severity: String, _ message: String, _ context: String?) -> VerificationIssue {
        VerificationIssue(id: id, severity: severity, message: message, context: context)
    }

    func testGroupsSameCheckAndKeepsEveryContext() {
        let issues = (1...56).map { issue("V-COST-01", "warning", "취득가 0원", "ASSET\($0)") }
        let groups = ReportView.groupIssues(issues)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 56)
        XCTAssertEqual(groups[0].contexts.count, 56, "항목이 하나라도 빠지면 볼 방법이 없어진다")
        XCTAssertEqual(groups[0].contexts.first, "ASSET1")
        XCTAssertEqual(groups[0].contexts.last, "ASSET56")
    }

    /// 건수 합계가 원래 개수와 같아야 한다 — 묶다가 삼키면 「확인 76건」과 화면이 어긋난다.
    func testTotalCountIsPreserved() {
        let issues = [
            issue("V-COST-01", "warning", "취득가 0원", "A"),
            issue("V-COST-01", "warning", "취득가 0원", "B"),
            issue("V-DEM-04", "warning", "시가 없음", "BTC"),
            issue("V-QTY-03", "warning", "전송 손실", nil),
            issue("V-QTY-02", "critical", "부족", "X")
        ]
        let groups = ReportView.groupIssues(issues)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, issues.count)
    }

    /// 같은 검사라도 문구가 갈리면 따로 묶는다 (V-QTY-02 의 「반올림 수준」 vs 「부족」).
    /// 한 덩이로 뭉치면 정상 오차와 진짜 문제가 같은 줄에 섞인다.
    func testSameIDDifferentMessageStaysSeparate() {
        let issues = [
            issue("V-QTY-02", "warning", "출금 수량이 장부보다 많습니다 (거래소 반올림 수준)", "BTC 2025-10-25"),
            issue("V-QTY-02", "critical", "보유 수량보다 많은 출금입니다", "BTC 2026-05-07")
        ]
        let groups = ReportView.groupIssues(issues)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.severity)), ["warning", "critical"])
    }

    /// 처음 나온 순서를 지킨다 — 건수 순으로 흔들면 볼 때마다 자리가 바뀐다.
    func testFirstSeenOrderIsKept() {
        let issues = [
            issue("B", "warning", "두번째 검사", "1"),
            issue("A", "warning", "첫번째 검사", "1"),
            issue("A", "warning", "첫번째 검사", "2"),
            issue("A", "warning", "첫번째 검사", "3")
        ]
        let groups = ReportView.groupIssues(issues)
        XCTAssertEqual(groups.map(\.message), ["두번째 검사", "첫번째 검사"])
    }

    func testContextlessIssueStillCounts() {
        let groups = ReportView.groupIssues([issue("V-FX-01", "critical", "환율 누락", nil)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 1)
        XCTAssertTrue(groups[0].contexts.isEmpty)
    }
}
