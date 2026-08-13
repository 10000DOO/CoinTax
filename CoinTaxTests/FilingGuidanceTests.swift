import XCTest
@testable import CoinTax

/// 계산이 끝난 뒤 「무엇을 해야 하는가」가 사용자에게 닿는가.
///
/// 숫자가 맞아도 어디에 어떻게 내는지 모르면 신고를 못 끝낸다.
/// 특히 **세금 0원과 「신고 안 해도 됨」은 다른 말**이다 — 손실이거나 250만 원 이하인
/// 이용자가 대부분인데, 여기서 침묵하면 신고를 통째로 건너뛴다.
final class FilingGuidanceTests: XCTestCase {

    /// `[법]` 소득세법 §73①8 — 분리과세기타소득만 있는 자의 신고 면제에서
    /// 「원천징수되지 아니하는 소득」을 괄호로 빼 두었고, 가상자산소득이 거기 해당한다.
    func testZeroTaxStillRequiresFiling() {
        let g = TaxCopy.filingRequiredEvenIfZero
        XCTAssertTrue(g.contains("0원이어도 신고 대상"))
        XCTAssertTrue(g.contains("제73조제1항제8호"), "근거 조문을 적어야 사용자가 확인할 수 있다")
        XCTAssertTrue(TaxCopy.filingGuide.contains(g))
    }

    /// `[법]` 지방세법 §95① 은 종합소득·퇴직소득만 규정한다 — 가상자산소득은 합산되지 않아
    /// 신고 경로가 명문으로 이어져 있지 않다 (백서 U-20). 실무는 홈택스 → 위택스다.
    func testLocalTaxIsFiledSeparately() {
        let g = TaxCopy.localTaxSeparateFiling
        XCTAssertTrue(g.contains("위택스"))
        XCTAssertTrue(g.contains("따로"))
        XCTAssertTrue(g.contains("22%를 한 번에 내는 것이 아닙니다"), "합쳐 낸다고 오해하면 지방세를 빠뜨린다")
    }

    /// `[법]` §70① — 다음 해 5월 1일~31일
    func testFilingWindowIsStated() {
        XCTAssertTrue(TaxCopy.filingWindow.contains("5월 1일부터 31일"))
        XCTAssertTrue(TaxCopy.filingWindow.contains("2028년 5월"), "첫 신고 시점을 못박는다")
    }

    /// `[법]` §21①27 은 "양도하거나 **대여**" 라고 한다. 대여 소득의 계산 규정이 없어
    /// 앱이 못 잡고 있다는 사실을 알려야 한다 (백서 U-06).
    func testLendingExclusionIsDisclosed() {
        let g = TaxCopy.lendingNotIncluded
        XCTAssertTrue(g.contains("Earn") && g.contains("렌딩"))
        XCTAssertTrue(g.contains("들어가 있지 않습니다"))
        XCTAssertTrue(TaxCopy.notices.contains(g), "필수 고지에도 실려야 한다")
    }

    /// 시행일·공제·세율을 「가정」이라고 부르면 근거를 실제보다 약하게 표시한다 — 법률 조문이다.
    func testScheduleCopyCitesStatuteNotGuidance() {
        let g = TaxCopy.scheduleMayChange
        XCTAssertTrue(g.contains("법률에 정해진 값"))
        XCTAssertTrue(g.contains("제64조의3제2항"))
        XCTAssertFalse(g.contains("공개 안내에 따른 가정"), "행정 안내가 근거인 것처럼 적으면 안 된다")
    }

    /// 원가법 고지가 폐지된 옛 규정을 안내하면 안 된다 (`[영]` §88①)
    func testCostMethodCopyMatchesTheLaw() {
        XCTAssertTrue(TaxCopy.costMethods.contains("총평균법"))
        XCTAssertFalse(TaxCopy.costMethods.contains("이동평균법"))
        XCTAssertFalse(TaxCopy.costMethods.contains("선입선출법"))
    }

    /// 「세무 확인」 항목이 코드가 실제로 하는 일과 같은 말을 하는가 (지시서 사각지대 ⑧)
    func testOpenQuestionsMatchWhatTheCodeDoes() throws {
        let byID = Dictionary(TaxOpenQuestions.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tq17 = try XCTUnwrap(byID["TQ-17"])
        XCTAssertEqual(tq17.kind, .confirmed, "이미 확정·적용된 규정을 「바뀔 가능성」으로 두면 안 된다")
        XCTAssertTrue(tq17.currentAssumption.contains("총평균법"))
        XCTAssertFalse(tq17.currentAssumption.contains("이동평균법"))

        let tq01 = try XCTUnwrap(byID["TQ-01"])
        XCTAssertFalse(tq01.currentAssumption.contains("설정에서"), "없어진 설정을 안내하면 안 된다")

        let tq03 = try XCTUnwrap(byID["TQ-03"])
        XCTAssertEqual(tq03.kind, .confirmed)
        XCTAssertTrue(tq03.currentAssumption.contains("버림"))
    }
}
