import XCTest
import SwiftData
@testable import CoinTax

/// 계산에 들어가는 값을 바꾸면 **「다시 계산해야 함」이 켜지는가** (5차 감사).
///
/// 이 표시가 안 켜지면 `ReportView.canExport` 가 계속 열려 있어,
/// 사용자는 **지금 자료로 계산한 값이라고 믿고** 신고자료를 내려받는다.
/// 실제로 의제 시가 삭제 버튼에서 이 호출이 빠져 있었다 —
/// 시가를 지우면 다시 계산했을 때 의제취득가가 실제 취득가로 내려가 **세액이 달라진다.**
@MainActor
final class StaleCalculationTests: XCTestCase {

    private func makeEnv() throws -> (AppEnvironment, ProjectEntity) {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let env = AppEnvironment(container: container)
        let project = try ProjectService(modelContext: env.modelContext).createProject(name: "stale")
        env.currentProject = project
        return (env, project)
    }

    /// 계산이 한 번 끝난 상태를 만든다 (내용은 비어 있어도 「끝났다」는 사실이 중요하다)
    private func makeFinishedCalculation(_ project: ProjectEntity) throws -> CalculationResult {
        let engine = CostBasisEngine(policies: .v1Default, accountsByID: [:], fxRates: [:], marketPrices: [:])
        let replay = try engine.replay(events: [], links: [])
        let summary = TaxAggregator.aggregate(
            projectID: ProjectID(project.id), disposals: [], taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: [], policies: .v1Default
        )
        let verification = VerificationReport(runID: UUID(), status: "passed", issues: [], calculatedAt: Date())
        return CalculationResult(summary: summary, replay: replay, verification: verification)
    }

    func testDeletingMarketPriceMarksCalculationStale() throws {
        let (env, project) = try makeEnv()

        let price = MarketPriceEntity(asOf: SetupProgress.deemedAsOf, asset: "BTC", priceKRW: "80000000", source: "manual")
        price.project = project
        project.marketPrices.append(price)
        env.modelContext.insert(price)
        try env.modelContext.save()

        env.lastCalculation = try makeFinishedCalculation(project)
        env.calculationStale = false

        try env.deleteCalculationInput(price)

        XCTAssertTrue(env.calculationStale, "시가를 지웠는데 「다시 계산해야 함」이 안 켜졌다 — 낡은 세액으로 신고자료가 나간다")
        XCTAssertTrue(project.marketPrices.isEmpty || !project.marketPrices.contains { $0.asset == "BTC" })
    }

    /// 리포트 화면은 **고른 연도의 계산일 때만** 그 숫자를 보여줘야 한다.
    ///
    /// 연도 칸만 바꾸고 다시 계산하지 않으면 제목은 새 연도인데 숫자는 옛 연도였다.
    /// 「2028년 귀속 · 예상 납부 세액 165만」처럼 **다른 해 세액을 그 해 것으로** 읽게 된다.
    func testCalculationKnowsWhichYearItCovers() throws {
        // `env` 를 버리면 저장소 컨테이너가 함께 해제되어 `project` 가 죽는다 — 끝까지 들고 있는다.
        let (env, project) = try makeEnv()
        let calc = try makeFinishedCalculation(project)   // 2027년으로 계산했다
        env.lastCalculation = calc

        XCTAssertTrue(calc.covers(taxYear: 2027))
        XCTAssertFalse(calc.covers(taxYear: 2028), "다른 해인데 같은 해로 봤다 — 화면·내보내기가 열린다")
        XCTAssertFalse(calc.covers(taxYear: 2026))
        XCTAssertEqual(env.lastCalculation?.summary.taxYear, 2027)
    }

    /// 계산을 아직 한 번도 안 했으면 켤 것이 없다 (오탐 방지 — 기존 `invalidateCalculation` 규칙)
    func testNoCalculationYetStaysFalse() throws {
        let (env, project) = try makeEnv()
        let price = MarketPriceEntity(asOf: SetupProgress.deemedAsOf, asset: "ETH", priceKRW: "3000000", source: "manual")
        price.project = project
        project.marketPrices.append(price)
        env.modelContext.insert(price)
        try env.modelContext.save()

        try env.deleteCalculationInput(price)
        XCTAssertFalse(env.calculationStale)
    }
}
