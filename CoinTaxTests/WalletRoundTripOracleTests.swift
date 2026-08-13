import XCTest
import SwiftData
@testable import CoinTax

/// 개인지갑을 **거쳐 갔다 돌아오는** 코인의 세액을 손계산과 대조한다 (5차 감사 회차 31).
///
/// 이 경로는 앱에서 가장 얽혀 있는 자리다 — 한 번에 네 가지가 겹친다.
///   ① 원가법 이원 (빗썸 이동평균 · 개인지갑/바이낸스 선입선출)
///   ② 전송으로 원가가 계정 사이를 넘어간다
///   ③ 2027-01-01 0시에 장부가 의제취득가로 재기동된다
///   ④ 그 뒤 다른 계정에서 팔린다
///
/// 무작위 시나리오 테스트가 이 조합을 「Critical 0건」으로 훑고 있었지만,
/// **숫자가 맞다**는 것은 아무도 손으로 확인한 적이 없다.
@MainActor
final class WalletRoundTripOracleTests: XCTestCase {

    /// 손계산
    /// ```text
    /// 2026-03-01 빗썸 BTC 1 매수 5,000만            → 빗썸 1개 @5,000만
    /// 2026-06-01 빗썸 → 개인지갑 1 BTC (수수료 0)    → 지갑 1개 @5,000만 · 빗썸 0
    /// 2026-09-01 빗썸 BTC 1 매수 7,000만            → 빗썸 1개 @7,000만
    /// 2027-01-01 0시 시가 8,000만 → 의제 재기동
    ///     빗썸 max(7,000만, 8,000만) = 8,000만
    ///     지갑 max(5,000만, 8,000만) = 8,000만       → 의제취득가 합계 1.6억
    /// 2027-03-01 개인지갑 → 바이낸스 1 BTC           → 바이낸스 1개 @8,000만
    /// 2027-05-01 바이낸스 매도 9,000만               → 소득 1,000만
    /// 2027-06-01 빗썸   매도 8,500만                → 소득   500만
    /// 합계 소득 1,500만 → 과세표준 1,250만
    /// 국세 250만 · 지방세 25만 · 합계 275만
    /// ```
    func testWalletRoundTripAcrossTaxStart() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let ps = ProjectService(modelContext: ctx)
        let project = try ps.createProject(name: "wallet-oracle")
        let pid = ProjectID(project.id)
        let bithumb = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })

        func add(_ event: LedgerEvent, _ fp: String) {
            var e = event
            e.fingerprint = fp
            let entity = EntityMappers.makeEntity(from: e)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
        }
        func krwTrade(_ acc: AccountEntity, _ y: Int, _ m: Int, _ type: EventType, _ qty: Decimal, _ krw: Decimal, _ ref: String) -> LedgerEvent {
            LedgerEvent(
                projectID: pid, accountID: AccountID(acc.id),
                timestamp: TaxTime.dateKST(year: y, month: m, day: 1, hour: 10),
                type: type, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: type == .sell ? -qty : qty, quoteAmountKRW: krw,
                sourceKind: "oracle", rawRef: ref
            )
        }

        add(krwTrade(bithumb, 2026, 3, .buy, 1, 50_000_000, "r1"), "fp1")
        add(LedgerEvent(
            projectID: pid, accountID: AccountID(bithumb.id),
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1, hour: 10),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "oracle", rawRef: "r2"
        ), "fp2")
        add(krwTrade(bithumb, 2026, 9, .buy, 1, 70_000_000, "r3"), "fp3")
        add(LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1, hour: 10),
            type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
            sourceKind: "oracle", rawRef: "r4"
        ), "fp4")
        add(krwTrade(binance, 2027, 5, .sell, 1, 90_000_000, "r5"), "fp5")
        add(krwTrade(bithumb, 2027, 6, .sell, 1, 85_000_000, "r6"), "fp6")
        try ctx.save()

        // 개인지갑으로 보냈다가 되가져온다 (앱의 버튼 두 개가 하는 일)
        let matching = MatchingService(modelContext: ctx)
        let out = try XCTUnwrap(project.events.first { $0.rawRef?.hasSuffix("r2") == true })
        try matching.moveToWallet(withdrawal: out, project: project)
        let back = try XCTUnwrap(project.events.first { $0.rawRef?.hasSuffix("r4") == true })
        try matching.receiveFromWallet(deposit: back, project: project)

        let accounts = ps.domainAccounts(for: project)
        let replay = try CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: [:], marketPrices: ["BTC": 80_000_000]
        ).replay(events: ps.domainEvents(for: project), links: ps.domainLinks(for: project))

        // 의제 재기동: 빗썸 1개 + 지갑 1개, 둘 다 단가 8,000만
        XCTAssertEqual(replay.deemedPositions.count, 2, "빗썸·개인지갑 두 자리가 재기동돼야 한다")
        for d in replay.deemedPositions {
            XCTAssertEqual(d.quantity, 1)
            XCTAssertEqual(d.deemedUnitKRW, 80_000_000, "max(장부, 시가) = 8,000만")
            XCTAssertEqual(d.reason, "market")
        }

        let summary = TaxAggregator.aggregate(
            projectID: pid, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: replay.extraDeductibleByYear[2027] ?? 0,
            abandonedTransferCostKRW: replay.abandonedByYear[2027] ?? 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        XCTAssertEqual(summary.totalDeemedCostKRW, 160_000_000, "의제취득가 합계")
        XCTAssertEqual(summary.disposals.count, 2, "2027 처분 두 건")
        XCTAssertEqual(summary.totalProceedsKRW, 175_000_000, "9,000만 + 8,500만")
        XCTAssertEqual(summary.totalCostsKRW, 160_000_000, "8,000만 × 2 — 전송으로 원가가 따라왔다")
        XCTAssertEqual(summary.netIncomeKRW, 15_000_000)
        XCTAssertEqual(summary.taxBaseKRW, 12_500_000)
        XCTAssertEqual(summary.nationalTaxKRW, 2_500_000)
        XCTAssertEqual(summary.localTaxKRW, 250_000)
        XCTAssertEqual(summary.totalTaxKRW, 2_750_000)
        XCTAssertEqual(replay.abandonedTotal, 0, "수수료 없는 전송이라 소멸한 원가가 없어야 한다")

        // 이 경로 전체가 검증기도 통과해야 의미가 있다
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: ps.domainEvents(for: project), summaryRerun: summary,
            links: ps.domainLinks(for: project)
        ))
        let criticals = report.issues.filter { $0.severity == "critical" }
        XCTAssertTrue(criticals.isEmpty, "정상 경로에서 Critical: " + criticals.map(\.id).joined(separator: ", "))
    }

    /// 개인지갑을 **거치지 않으면** 세금이 얼마나 더 나오는가 — 기능의 존재 이유를 숫자로 고정한다.
    ///
    /// 지정하지 않으면 그 출금의 취득원가가 소멸하고, 되가져온 입금은 취득가 0원이 된다.
    /// 위와 같은 자료에서 소득이 **5,000만 늘어** 세액이 1,100만 더 나온다.
    func testWithoutWalletTheTaxIsHigher() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let ps = ProjectService(modelContext: ctx)
        let project = try ps.createProject(name: "no-wallet")
        let pid = ProjectID(project.id)
        let bithumb = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })

        func add(_ e: LedgerEvent, _ fp: String) {
            var x = e; x.fingerprint = fp
            let entity = EntityMappers.makeEntity(from: x)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
        }
        func krwTrade(_ acc: AccountEntity, _ y: Int, _ m: Int, _ type: EventType, _ qty: Decimal, _ krw: Decimal, _ ref: String) -> LedgerEvent {
            LedgerEvent(
                projectID: pid, accountID: AccountID(acc.id),
                timestamp: TaxTime.dateKST(year: y, month: m, day: 1, hour: 10),
                type: type, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: type == .sell ? -qty : qty, quoteAmountKRW: krw,
                sourceKind: "oracle", rawRef: ref
            )
        }
        add(krwTrade(bithumb, 2026, 3, .buy, 1, 50_000_000, "r1"), "fp1")
        add(LedgerEvent(projectID: pid, accountID: AccountID(bithumb.id),
                        timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1, hour: 10),
                        type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
                        sourceKind: "oracle", rawRef: "r2"), "fp2")
        add(krwTrade(bithumb, 2026, 9, .buy, 1, 70_000_000, "r3"), "fp3")
        add(LedgerEvent(projectID: pid, accountID: AccountID(binance.id),
                        timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1, hour: 10),
                        type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
                        sourceKind: "oracle", rawRef: "r4"), "fp4")
        add(krwTrade(binance, 2027, 5, .sell, 1, 90_000_000, "r5"), "fp5")
        add(krwTrade(bithumb, 2027, 6, .sell, 1, 85_000_000, "r6"), "fp6")
        try ctx.save()

        let accounts = ps.domainAccounts(for: project)
        let replay = try CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: [:], marketPrices: ["BTC": 80_000_000]
        ).replay(events: ps.domainEvents(for: project), links: [])

        let summary = TaxAggregator.aggregate(
            projectID: pid, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: replay.abandonedByYear[2027] ?? 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        // 바이낸스 입금은 취득가 0원, 빗썸만 의제 8,000만 → 필요경비 8,000만
        XCTAssertEqual(summary.totalCostsKRW, 80_000_000)
        XCTAssertEqual(summary.netIncomeKRW, 95_000_000, "개인지갑을 안 쓰면 소득이 5,000만 늘어난다")
        XCTAssertEqual(summary.totalTaxKRW, 20_350_000)
        XCTAssertEqual(replay.abandonedTotal, 50_000_000, "빗썸에서 나간 1 BTC 의 취득원가가 소멸한다")
    }
}
