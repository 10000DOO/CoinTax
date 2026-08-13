import XCTest
import SwiftData
@testable import CoinTax

/// 시작 체크리스트가 **「완료」라고 말하는 조건**이 실제 남은 일과 맞는가 (5차 감사 회차 23).
///
/// 「전송 연결」 단계는 상대 없는 **출금**만 센다. 그런데 상대 없는 **입금**도 남은 일이다 —
/// 개인지갑에서 되가져온 입금을 연결하지 않으면 **취득가 0원**이 되어 판 금액 전부가 이익으로 잡힌다.
/// 앱에는 「개인지갑에서」 버튼이 있어 고칠 수 있는데, 체크리스트가 「완료」라고 하면 아무도 안 고친다.
@MainActor
final class SetupChecklistTests: XCTestCase {

    private func makeEnv() throws -> (AppEnvironment, ProjectEntity) {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let env = AppEnvironment(container: container)
        let project = try ProjectService(modelContext: env.modelContext).createProject(name: "checklist")
        env.currentProject = project
        return (env, project)
    }

    private func insert(_ event: LedgerEvent, _ project: ProjectEntity, _ ctx: ModelContext) {
        let entity = EntityMappers.makeEntity(from: event)
        entity.project = project
        project.events.append(entity)
        ctx.insert(entity)
    }

    /// 개인지갑에서 되가져온 입금이 **연결 가능한데도** 남아 있으면 「완료」가 아니어야 한다
    func testUnlinkedDepositThatWalletCanCoverBlocksTheStep() throws {
        let (env, project) = try makeEnv()
        let ctx = env.modelContext
        let pid = ProjectID(project.id)
        let bithumb = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })

        // 빗썸에서 사서 개인지갑으로 보낸다
        var buy = LedgerEvent(
            projectID: pid, accountID: AccountID(bithumb.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: "t", rawRef: "r1"
        )
        buy.fingerprint = "fp1"
        var out = LedgerEvent(
            projectID: pid, accountID: AccountID(bithumb.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 10),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "t", rawRef: "r2"
        )
        out.fingerprint = "fp2"
        // 그 뒤 바이낸스로 되가져온다 (상대 출금 기록이 없는 입금)
        var backIn = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 1, hour: 10),
            type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
            sourceKind: "t", rawRef: "r3"
        )
        backIn.fingerprint = "fp3"
        for e in [buy, out, backIn] { insert(e, project, ctx) }
        // 파일이 하나도 없으면 3단계가 「차례 아님」으로 남아 검사가 헛돈다
        let sf = SourceFileEntity(fileName: "x.csv", format: "csv", parserID: "t", sha256: "h")
        sf.project = project
        project.sourceFiles.append(sf)
        ctx.insert(sf)
        try ctx.save()

        // 출금은 개인지갑으로 지정해 둔다 → 상대 없는 «출금» 은 0건이 된다
        let withdrawal = try XCTUnwrap(project.events.first { $0.type == "withdrawal" })
        try env.matchingService.moveToWallet(withdrawal: withdrawal, project: project)

        // 이 시점: 상대 없는 출금 0건, 자동 제안 0건 — 옛 규칙이면 「완료」
        let progress = SetupProgress.evaluate(env: env)
        let step = try XCTUnwrap(progress.steps.first { $0.id == 3 })

        // 그런데 개인지갑이 그 코인을 갖고 있으므로 **연결할 수 있는 입금이 남아 있다**
        let wallet = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "wallet" })
        XCTAssertGreaterThan(
            env.matchingService.walletBalance(asset: "BTC", at: backIn.timestamp, project: project), 0,
            "개인지갑에 코인이 있어야 이 경로를 본다 (\(wallet.displayName))"
        )
        XCTAssertNotEqual(
            step.state, .done,
            """
            개인지갑에서 되가져온 입금을 연결하지 않으면 취득가 0원이 되어 세금이 커지는데,
            체크리스트가 「완료」라고 말한다 — 안내: \(step.detail)
            """
        )
    }

    /// 시가 단계가 **코인을 팔아서 받은 코인**도 세는가.
    ///
    /// 계산을 한 번도 안 돌린 상태에서는 「과세 시작 전에 기록이 있는 코인」으로 어림잡는데,
    /// 그때 **기초자산(baseAsset)만** 본다. 코인↔코인 매도로 받은 견적자산(USDT 등)은
    /// 기초자산으로 한 번도 안 나오므로 목록에서 빠진다 —
    /// 체크리스트는 「완료」인데 계산은 그 코인의 시가가 없어 막힌다.
    func testMarketPriceStepCountsQuoteAssetsReceivedFromSwaps() throws {
        let (env, project) = try makeEnv()
        let ctx = env.modelContext
        let pid = ProjectID(project.id)
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })

        // 2026: BTC 를 사고, 그 BTC 를 팔아 USDT 를 받는다 (USDT 는 기초자산으로 한 번도 안 나온다)
        var buy = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2026, month: 1, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: "t", rawRef: "r1"
        )
        buy.fingerprint = "fp1"
        var swap = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1, hour: 10),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: -1, quoteAmount: 40_000, sourceKind: "t", rawRef: "r2"
        )
        swap.fingerprint = "fp2"
        for e in [buy, swap] { insert(e, project, ctx) }
        let sf = SourceFileEntity(fileName: "x.csv", format: "csv", parserID: "t", sha256: "h")
        sf.project = project
        project.sourceFiles.append(sf)
        ctx.insert(sf)
        // BTC 시가는 넣어 둔다 → 남는 건 USDT 뿐
        let price = MarketPriceEntity(asOf: SetupProgress.deemedAsOf, asset: "BTC", priceKRW: "60000000", source: "manual")
        price.project = project
        project.marketPrices.append(price)
        ctx.insert(price)
        try ctx.save()

        // 엔진은 USDT 시가가 없다고 말한다 (실제로 2026-12-31 에 USDT 를 들고 있다)
        let accounts = env.projectService.domainAccounts(for: project)
        let replay = try CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: ["2026-06-01": 1_400], marketPrices: ["BTC": 60_000_000]
        ).replay(events: env.projectService.domainEvents(for: project), links: [])
        XCTAssertTrue(replay.missingMarketAssets.contains { $0.code == "USDT" },
                      "이 시나리오에서 USDT 시가가 실제로 필요해야 한다")

        let step = try XCTUnwrap(SetupProgress.evaluate(env: env).steps.first { $0.id == 5 })
        XCTAssertNotEqual(
            step.state, .done,
            """
            코인을 팔아 받은 USDT 의 시가가 없어 계산이 막히는데 체크리스트는 「완료」라고 한다.
            안내: \(step.detail)
            """
        )
    }

    /// 남은 일이 정말 없으면 「완료」여야 한다 (오탐 방지)
    func testNothingLeftIsDone() throws {
        let (env, project) = try makeEnv()
        let ctx = env.modelContext
        let pid = ProjectID(project.id)
        let bithumb = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })
        var buy = LedgerEvent(
            projectID: pid, accountID: AccountID(bithumb.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: "t", rawRef: "r1"
        )
        buy.fingerprint = "fp1"
        insert(buy, project, ctx)
        // 파일이 있어야 3단계까지 평가된다
        let sf = SourceFileEntity(fileName: "x.csv", format: "csv", parserID: "t", sha256: "h")
        sf.project = project
        project.sourceFiles.append(sf)
        ctx.insert(sf)
        try ctx.save()

        let step = try XCTUnwrap(SetupProgress.evaluate(env: env).steps.first { $0.id == 3 })
        XCTAssertEqual(step.state, .done, "연결할 것이 없는데 할 일로 남겼다: \(step.detail)")
    }
}
