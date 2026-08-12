import XCTest
import SwiftData
@testable import CoinTax

/// 2026-08-12 로직 감사에서 고친 항목들의 회귀 테스트.
/// 상세: `docs/audit-2026-08-12-logic.md`
final class AuditFixTests: XCTestCase {
    private let projectID = ProjectID()

    private func fx(_ days: [Date]) -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        for d in days { out[TaxTime.dayKST(d)] = 1_400 }
        return out
    }

    // MARK: - A-01 과세 시작 전 매도의 수수료 자산도 장부에서 빠져야 한다

    /// 2026년(과세 전) 매도에 BNB 수수료가 붙으면, 그 BNB 는 실제로 지갑에서 나간다.
    /// 장부에 반영하지 않으면 2026-12-31 보유 수량이 부풀어 **의제취득가가 틀어진다**.
    func testPreTaxSellFeeAssetLeavesBook() throws {
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let bnbBuy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 1, day: 5),
            type: .buy, baseAsset: AssetSymbol("BNB"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 700_000, sourceKind: "t", rawRef: "r1"
        )
        let btcBuy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 2, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "r2"
        )
        // 과세 시작 전 매도 — 수수료는 BNB
        let btcSell = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: -1, quoteAmountKRW: 120_000_000,
            feeAmount: Decimal(string: "0.1")!, feeAsset: AssetSymbol("BNB"),
            sourceKind: "t", rawRef: "r3"
        )
        let events = [bnbBuy, btcBuy, btcSell]
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: [:], marketPrices: ["BNB": 800_000]
        )
        let replay = try engine.replay(events: events, links: [])

        let bnb = try XCTUnwrap(replay.deemedPositions.first { $0.asset.code == "BNB" })
        XCTAssertEqual(bnb.quantity, Decimal(string: "0.9")!, "매도 수수료 0.1 BNB 가 빠져야 한다")

        // 검증기의 독립 재계산과도 일치해야 한다 (엔진만 고치면 거짓 Critical 이 난다)
        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: events, summaryRerun: summary
        ))
        XCTAssertFalse(report.issues.contains { $0.id == "V-QTY-01" })
        XCTAssertFalse(report.issues.contains { $0.id == "V-DEM-01" })
    }

    // MARK: - A-02 견적자산(USDT) 수수료도 장부에서 빠져야 한다

    func testQuoteAssetFeeLeavesBookAndUsesBookCost() throws {
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let t0 = TaxTime.dateKST(year: 2027, month: 1, day: 5)
        let t1 = TaxTime.dateKST(year: 2027, month: 2, day: 1)
        let t2 = TaxTime.dateKST(year: 2027, month: 3, day: 1)
        // USDT 1000개를 개당 1,400원에 취득
        let usdtIn = LedgerEvent(
            projectID: projectID, accountID: acc.id, timestamp: t0,
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1_000, quoteAmountKRW: 1_400_000, sourceKind: "t", rawRef: "r1"
        )
        // USDT 500 으로 BTC 매수 + 수수료 USDT 1
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id, timestamp: t1,
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: Decimal(string: "0.01")!, quoteAmount: 500,
            feeAmount: 1, feeAsset: AssetSymbol("USDT"), sourceKind: "t", rawRef: "r2"
        )
        // BTC 매도 (원화 마켓이 아니라 USDT 마켓) + 수수료 USDT 1
        let sell = LedgerEvent(
            projectID: projectID, accountID: acc.id, timestamp: t2,
            type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
            quantity: Decimal(string: "-0.01")!, quoteAmount: 600,
            feeAmount: 1, feeAsset: AssetSymbol("USDT"), sourceKind: "t", rawRef: "r3"
        )
        let events = [usdtIn, buy, sell]
        let engine = CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: fx([t0, t1, t2]), marketPrices: [:]
        )
        let replay = try engine.replay(events: events, links: [])

        let usdt = try XCTUnwrap(replay.holdings.rows.first { $0.asset.code == "USDT" })
        // 1000 − 500(매수 대금) − 1(매수 수수료) + 600(매도 수령) − 1(매도 수수료)
        XCTAssertEqual(usdt.quantity, 1_098, "수수료로 낸 USDT 가 보유에 남으면 안 된다")

        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: events, summaryRerun: summary
        ))
        XCTAssertFalse(
            report.issues.contains { $0.id == "V-QTY-01" },
            report.issues.filter { $0.id == "V-QTY-01" }.map(\.message).joined(separator: "\n")
        )
        // 부대비용은 그 USDT 의 **장부 원가**(1개 × 1,400원)
        let btcSell = try XCTUnwrap(replay.disposals.first { $0.asset.code == "BTC" })
        XCTAssertEqual(btcSell.feesKRW, 1_400)
    }

    // MARK: - A-03 전송 도착은 「입금 시각」에 잡힌다 (연말 경계)

    /// 2026-12-31 출금 → 2027-01-02 입금.
    /// 도착분을 출금 시각에 입고하면 아직 오지도 않은 자산에 의제취득가가 붙는다.
    func testTransferArrivesAtDepositTimeNotWithdrawalTime() throws {
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)
        let binance = Account.defaults(for: .binance, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 100, quoteAmountKRW: 140_000, sourceKind: "t", rawRef: "r1"
        )
        let out = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 12, day: 31, hour: 23, minute: 50),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -100,
            sourceKind: "t", rawRef: "r2"
        )
        let into = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2, hour: 9),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 100,
            sourceKind: "t", rawRef: "r3"
        )
        let link = TransferLink(
            id: LinkID(), projectID: projectID,
            fromEventID: out.id, toEventID: into.id,
            status: .confirmed,
            withdrawnQty: Money.abs(out.quantity), receivedQty: Money.abs(into.quantity),
            score: 1, note: nil
        )
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: [bithumb.id: bithumb, binance.id: binance],
            fxRates: [:], marketPrices: ["USDT": 1_500]
        )
        let replay = try engine.replay(events: [buy, out, into], links: [link])

        // 2026-12-31 24시 스냅샷에는 두 계정 어디에도 USDT 가 없어야 한다 (이동 중)
        XCTAssertTrue(replay.deemedPositions.isEmpty, "아직 도착하지 않은 전송에 의제취득가가 붙었다: \(replay.deemedPositions)")
        XCTAssertTrue(replay.issues.contains { $0.id == "V-DEM-05" }, "이동 중 전송은 사용자에게 알려야 한다")

        // 그래도 원가는 도착 계정으로 이전된다
        let arrived = try XCTUnwrap(replay.holdings.rows.first { $0.accountID == binance.id })
        XCTAssertEqual(arrived.quantity, 100)
        XCTAssertEqual(arrived.totalCostKRW, 140_000)
    }

    /// 거래소 시계 차이로 **입금이 출금보다 먼저** 기록된 전송에서도 원가가 사라지면 안 된다.
    func testTransferWithDepositRecordedBeforeWithdrawalStillCarriesCost() throws {
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)
        let binance = Account.defaults(for: .binance, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 100, quoteAmountKRW: 140_000, sourceKind: "t", rawRef: "r1"
        )
        let into = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 2, hour: 10, minute: 0),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 100,
            sourceKind: "t", rawRef: "r2"
        )
        let out = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 2, hour: 10, minute: 1),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -100,
            sourceKind: "t", rawRef: "r3"
        )
        let link = TransferLink(
            id: LinkID(), projectID: projectID,
            fromEventID: out.id, toEventID: into.id,
            status: .confirmed,
            withdrawnQty: Money.abs(out.quantity), receivedQty: Money.abs(into.quantity),
            score: 1, note: nil
        )
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: [bithumb.id: bithumb, binance.id: binance],
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: [buy, into, out], links: [link])
        let arrived = try XCTUnwrap(replay.holdings.rows.first { $0.accountID == binance.id })
        XCTAssertEqual(arrived.quantity, 100)
        XCTAssertEqual(arrived.totalCostKRW, 140_000)
        XCTAssertFalse(replay.issues.contains { $0.id == "V-QTY-03" })
    }

    // MARK: - A-04 네트워크 수수료가 큰 소액 전송은 export 를 잠그면 안 된다

    /// 10 USDT 를 보내 9 USDT 를 받는 전송(손실 10%)은 정상이다.
    /// 매칭 화면은 후보로 제시하는데 검증기가 Critical 로 막으면 신고자료를 만들 수 없다.
    func testHighFeeTransferIsWarningNotCritical() throws {
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)
        let binance = Account.defaults(for: .binance, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 1),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 10, quoteAmountKRW: 14_000, sourceKind: "t", rawRef: "r1"
        )
        let out = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 2),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -10,
            sourceKind: "t", rawRef: "r2"
        )
        let into = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 2, hour: 1),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 9,
            sourceKind: "t", rawRef: "r3"
        )
        let link = TransferLink(
            id: LinkID(), projectID: projectID,
            fromEventID: out.id, toEventID: into.id,
            status: .confirmed,
            withdrawnQty: Money.abs(out.quantity), receivedQty: Money.abs(into.quantity),
            score: 1, note: nil
        )
        let events = [buy, out, into]
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: [bithumb.id: bithumb, binance.id: binance],
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: events, links: [link])
        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: replay.extraDeductibleByYear[2027] ?? 0,
            abandonedTransferCostKRW: replay.abandonedByYear[2027] ?? 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: events, summaryRerun: summary, links: [link]
        ))
        let qty03 = report.issues.filter { $0.id == "V-QTY-03" }
        XCTAssertEqual(qty03.count, 1)
        XCTAssertEqual(qty03.first?.severity, "warning", "정상적인 소액 전송이 Critical 이면 export 가 잠긴다")
        XCTAssertTrue(report.isExportAllowed)
    }

    /// 받은 양이 보낸 양보다 많으면 여전히 Critical 이다 (잘못 연결한 것)
    func testDepositLargerThanWithdrawalStaysCritical() throws {
        let bithumb = Account.defaults(for: .bithumb, projectID: projectID)
        let binance = Account.defaults(for: .binance, projectID: projectID)
        let out = LedgerEvent(
            projectID: projectID, accountID: bithumb.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 2),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -10,
            sourceKind: "t", rawRef: "r1"
        )
        let into = LedgerEvent(
            projectID: projectID, accountID: binance.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 2, hour: 1),
            type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 20,
            sourceKind: "t", rawRef: "r2"
        )
        let link = TransferLink(
            id: LinkID(), projectID: projectID,
            fromEventID: out.id, toEventID: into.id,
            status: .confirmed,
            withdrawnQty: Money.abs(out.quantity), receivedQty: Money.abs(into.quantity),
            score: 1, note: nil
        )
        let events = [out, into]
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: [bithumb.id: bithumb, binance.id: binance],
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: events, links: [link])
        let summary = TaxAggregator.aggregate(
            projectID: projectID, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: events, summaryRerun: summary, links: [link]
        ))
        XCTAssertTrue(report.issues.contains { $0.id == "V-QTY-03" && $0.severity == "critical" })
    }
}

// MARK: - A-09 개인지갑으로 보낸 코인은 산 값이 따라가야 한다

@MainActor
final class PersonalWalletTests: XCTestCase {
    private func makeProject() throws -> (ModelContext, ProjectEntity, ProjectService) {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let ps = ProjectService(modelContext: ctx)
        let project = try ps.createProject(name: "wallet")
        return (ctx, project, ps)
    }

    /// 거래소 → 개인지갑 → (2027년) 다시 거래소 → 매도.
    /// 지갑 처리를 하지 않으면 취득가 0원이 되어 판 금액 전부가 이익이 된다.
    func testWalletMovePreservesCostBasis() throws {
        let (ctx, project, ps) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let pid = ProjectID(project.id)

        // 2026년: 바이낸스에서 BTC 1개를 1억에 사고, 개인지갑으로 출금
        var buy = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "r1"
        )
        buy.fingerprint = "fp-buy"
        var out = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2026, month: 4, day: 1),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "t", rawRef: "r2"
        )
        out.fingerprint = "fp-out"
        for e in [buy, out] {
            let entity = EntityMappers.makeEntity(from: e)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
        }
        try ctx.save()

        let matching = MatchingService(modelContext: ctx)
        let withdrawal = try XCTUnwrap(project.events.first { $0.type == "withdrawal" })
        try matching.moveToWallet(withdrawal: withdrawal, project: project)

        // 개인지갑 계정이 생기고 선입선출법이 붙는다 (05-decisions §1.2)
        let wallet = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "wallet" })
        XCTAssertEqual(wallet.costMethod, CostBasisMethod.fifo.rawValue)
        XCTAssertEqual(wallet.venueKind, VenueKind.wallet.rawValue)

        let accounts = ps.domainAccounts(for: project)
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: [:], marketPrices: ["BTC": 150_000_000]
        )
        let replay = try engine.replay(events: ps.domainEvents(for: project), links: ps.domainLinks(for: project))

        // 지갑에 BTC 1개가 남아 있다 (보유 현황에서 사라지지 않는다)
        let held = try XCTUnwrap(replay.holdings.rows.first { $0.accountID?.raw == wallet.id })
        XCTAssertEqual(held.quantity, 1)
        XCTAssertEqual(replay.abandonedTotal, 0, "지갑으로 옮겼으면 원가가 소멸하면 안 된다")

        // 실제 취득가 1억이 지갑까지 따라왔고, 그 위에 의제취득가 max(1억, 시가 1.5억)가 적용된다
        let deemed = try XCTUnwrap(replay.deemedPositions.first { $0.accountID.raw == wallet.id })
        XCTAssertEqual(deemed.bookUnitKRW, 100_000_000, "산 값이 소멸하지 않고 지갑으로 이어져야 한다")
        XCTAssertEqual(deemed.deemedUnitKRW, 150_000_000)
        XCTAssertEqual(deemed.reason, "market")
        // 재기동 후 장부는 의제 금액 기준
        XCTAssertEqual(held.totalCostKRW, 150_000_000)

        // 전송 자체로는 처분이 잡히지 않는다
        XCTAssertTrue(replay.disposals.isEmpty)
    }

    /// 지갑 처리를 하지 않으면 원가가 소멸한다 — 위 테스트의 대조군
    func testWithoutWalletMoveCostIsAbandoned() throws {
        let (ctx, project, ps) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let pid = ProjectID(project.id)
        var buy = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "r1"
        )
        buy.fingerprint = "fp-buy"
        var out = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2026, month: 4, day: 1),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "t", rawRef: "r2"
        )
        out.fingerprint = "fp-out"
        for e in [buy, out] {
            let entity = EntityMappers.makeEntity(from: e)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
        }
        try ctx.save()

        let accounts = ps.domainAccounts(for: project)
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: [:], marketPrices: ["BTC": 150_000_000]
        )
        let replay = try engine.replay(events: ps.domainEvents(for: project), links: [])
        XCTAssertEqual(replay.abandonedTotal, 100_000_000, "미매칭 출금은 원가가 소멸한다")
        XCTAssertTrue(replay.holdings.rows.isEmpty, "보유 현황에서 사라진다")
    }

    /// 네트워크 수수료만큼 덜 도착한 경우 그 몫만 소멸한다
    func testWalletMoveWithNetworkFee() throws {
        let (ctx, project, ps) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let pid = ProjectID(project.id)
        var buy = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .buy, baseAsset: AssetSymbol("USDT"), quoteAsset: AssetSymbol("KRW"),
            quantity: 100, quoteAmountKRW: 140_000, sourceKind: "t", rawRef: "r1"
        )
        buy.fingerprint = "fp-buy"
        var out = LedgerEvent(
            projectID: pid, accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 4, day: 1),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -100,
            sourceKind: "t", rawRef: "r2"
        )
        out.fingerprint = "fp-out"
        for e in [buy, out] {
            let entity = EntityMappers.makeEntity(from: e)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
        }
        try ctx.save()

        let matching = MatchingService(modelContext: ctx)
        let withdrawal = try XCTUnwrap(project.events.first { $0.type == "withdrawal" })
        try matching.moveToWallet(withdrawal: withdrawal, project: project, receivedQty: 99)

        let accounts = ps.domainAccounts(for: project)
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: ps.domainEvents(for: project), links: ps.domainLinks(for: project))
        let wallet = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "wallet" })
        let held = try XCTUnwrap(replay.holdings.rows.first { $0.accountID?.raw == wallet.id })
        XCTAssertEqual(held.quantity, 99)
        XCTAssertEqual(held.totalCostKRW, Decimal(string: "138600")!, "140,000 × 99/100")
        XCTAssertEqual(replay.abandonedTotal, 1_400, "소실 1 USDT 분 원가만 소멸 (보수 정책)")
    }

    /// 연결을 풀면 자동으로 만든 지갑 입고 이벤트도 사라져야 한다.
    /// 남겨두면 「출처 없는 입금 = 취득가 0원」이 원장에 그대로 남는다.
    func testUnlinkRemovesGeneratedWalletDeposit() throws {
        let (ctx, project, _) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        var out = LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 4, day: 1),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "t", rawRef: "r1"
        )
        out.fingerprint = "fp-out"
        let entity = EntityMappers.makeEntity(from: out)
        entity.project = project
        project.events.append(entity)
        ctx.insert(entity)
        try ctx.save()

        let matching = MatchingService(modelContext: ctx)
        try matching.moveToWallet(withdrawal: entity, project: project)
        XCTAssertEqual(project.events.count, 2)
        XCTAssertEqual(project.links.count, 1)

        try matching.unlink(try XCTUnwrap(project.links.first), project: project)
        XCTAssertEqual(project.events.count, 1, "생성된 지갑 입고가 남으면 취득가 0원 입금이 된다")
        XCTAssertTrue(project.links.isEmpty)
    }

    /// 거래소 → 지갑 → 다시 거래소 → 매도. 산 값이 한 바퀴 돌아와야 한다.
    /// 되가져오기를 처리하지 않으면 그 입금이 취득가 0원이 되어 판 금액 전부가 이익이 된다.
    func testWalletRoundTripPreservesCostBasis() throws {
        let (ctx, project, ps) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let pid = ProjectID(project.id)

        func add(_ e: LedgerEvent, _ fp: String) {
            var ev = e
            ev.fingerprint = fp
            let entity = EntityMappers.makeEntity(from: ev)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
        }
        // 2027-02 매수 1억 → 2027-03 지갑으로 → 2027-05 거래소로 복귀 → 2027-06 1.5억에 매도
        add(LedgerEvent(projectID: pid, accountID: AccountID(binance.id),
                        timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
                        type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                        quantity: 1, quoteAmountKRW: 100_000_000, sourceKind: "t", rawRef: "r1"), "fp1")
        add(LedgerEvent(projectID: pid, accountID: AccountID(binance.id),
                        timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
                        type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
                        sourceKind: "t", rawRef: "r2"), "fp2")
        add(LedgerEvent(projectID: pid, accountID: AccountID(binance.id),
                        timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 1),
                        type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
                        sourceKind: "t", rawRef: "r3"), "fp3")
        add(LedgerEvent(projectID: pid, accountID: AccountID(binance.id),
                        timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
                        type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                        quantity: -1, quoteAmountKRW: 150_000_000, sourceKind: "t", rawRef: "r4"), "fp4")
        try ctx.save()

        let matching = MatchingService(modelContext: ctx)
        let out = try XCTUnwrap(project.events.first { $0.type == "withdrawal" })
        try matching.moveToWallet(withdrawal: out, project: project)
        let back = try XCTUnwrap(project.events.first { $0.type == "deposit" && $0.sourceKind == "t" })
        try matching.receiveFromWallet(deposit: back, project: project)

        let accounts = ps.domainAccounts(for: project)
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: [:], marketPrices: [:]
        )
        let replay = try engine.replay(events: ps.domainEvents(for: project), links: ps.domainLinks(for: project))

        let disposal = try XCTUnwrap(replay.disposals.first { $0.asset.code == "BTC" })
        XCTAssertEqual(disposal.costKRW, 100_000_000, "지갑을 거쳐 왔어도 산 값이 그대로여야 한다")
        XCTAssertEqual(disposal.pnlKRW, 50_000_000, "1.5억 − 1억")
        XCTAssertEqual(replay.abandonedTotal, 0)
        // 지갑도 거래소도 남은 게 없다
        XCTAssertTrue(replay.holdings.rows.isEmpty, "\(replay.holdings.rows)")

        // 검증기 전 항목 통과
        let summary = TaxAggregator.aggregate(
            projectID: pid, disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        let report = Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: ps.domainEvents(for: project), summaryRerun: summary,
            links: ps.domainLinks(for: project)
        ))
        XCTAssertFalse(
            report.issues.contains { $0.severity == "critical" },
            report.issues.filter { $0.severity == "critical" }.map { "\($0.id) \($0.message)" }.joined(separator: "\n")
        )
    }

    /// 지갑에 없는 코인을 「지갑에서 왔다」고 하면 없던 자산을 만들어 내는 셈이다 — 막아야 한다
    func testReceiveFromWalletRejectsWhenWalletIsEmpty() throws {
        let (ctx, project, _) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        var dep = LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 1),
            type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
            sourceKind: "t", rawRef: "r1"
        )
        dep.fingerprint = "fp1"
        let entity = EntityMappers.makeEntity(from: dep)
        entity.project = project
        project.events.append(entity)
        ctx.insert(entity)
        try ctx.save()

        let matching = MatchingService(modelContext: ctx)
        // 지갑 계정 자체가 없다
        XCTAssertThrowsError(try matching.receiveFromWallet(deposit: entity, project: project))

        // 지갑에 다른 코인만 있어도 안 된다
        var out = LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 4, day: 1),
            type: .withdrawal, baseAsset: AssetSymbol("USDT"), quantity: -100,
            sourceKind: "t", rawRef: "r2"
        )
        out.fingerprint = "fp2"
        let outEntity = EntityMappers.makeEntity(from: out)
        outEntity.project = project
        project.events.append(outEntity)
        ctx.insert(outEntity)
        try ctx.save()
        try matching.moveToWallet(withdrawal: outEntity, project: project)
        XCTAssertThrowsError(try matching.receiveFromWallet(deposit: entity, project: project))
    }

    /// 지갑으로 보내기 **전에** 들어온 입금을 지갑에서 왔다고 하면 안 된다 (시간 역행)
    func testReceiveFromWalletRespectsTimeOrder() throws {
        let (ctx, project, _) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        func add(_ e: LedgerEvent, _ fp: String) -> LedgerEventEntity {
            var ev = e
            ev.fingerprint = fp
            let entity = EntityMappers.makeEntity(from: ev)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
            return entity
        }
        // 지갑 출금은 6월인데, 입금은 3월이다
        let out = add(LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 6, day: 1),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "t", rawRef: "r1"), "fp1")
        let early = add(LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
            sourceKind: "t", rawRef: "r2"), "fp2")
        try ctx.save()

        let matching = MatchingService(modelContext: ctx)
        try matching.moveToWallet(withdrawal: out, project: project)
        XCTAssertThrowsError(
            try matching.receiveFromWallet(deposit: early, project: project),
            "지갑에 들어오기 전 시점의 입금이다"
        )
    }

    func testUnlinkRemovesGeneratedWalletWithdrawal() throws {
        let (ctx, project, _) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        func add(_ e: LedgerEvent, _ fp: String) -> LedgerEventEntity {
            var ev = e
            ev.fingerprint = fp
            let entity = EntityMappers.makeEntity(from: ev)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
            return entity
        }
        let out = add(LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "t", rawRef: "r1"), "fp1")
        let back = add(LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 5, day: 1),
            type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
            sourceKind: "t", rawRef: "r2"), "fp2")
        try ctx.save()

        let matching = MatchingService(modelContext: ctx)
        try matching.moveToWallet(withdrawal: out, project: project)
        try matching.receiveFromWallet(deposit: back, project: project)
        XCTAssertEqual(project.events.count, 4)

        // 되가져오기 연결을 풀면 지갑 출고 기록이 사라진다
        let backLink = try XCTUnwrap(project.links.first { $0.toEventID == back.id })
        try matching.unlink(backLink, project: project)
        XCTAssertEqual(project.events.count, 3)
        XCTAssertNil(project.events.first { $0.sourceKind == MatchingService.walletSourceKind && $0.type == "withdrawal" })
    }

    func testWalletMoveRejectsInvalidInput() throws {
        let (ctx, project, _) = try makeProject()
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        var dep = LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 4, day: 1),
            type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
            sourceKind: "t", rawRef: "r1"
        )
        dep.fingerprint = "fp-dep"
        let entity = EntityMappers.makeEntity(from: dep)
        entity.project = project
        project.events.append(entity)
        ctx.insert(entity)
        try ctx.save()

        let matching = MatchingService(modelContext: ctx)
        XCTAssertThrowsError(try matching.moveToWallet(withdrawal: entity, project: project), "입금은 지갑 이동 대상이 아니다")

        // 도착 수량이 출금 수량보다 크면 거부
        var out = LedgerEvent(
            projectID: ProjectID(project.id), accountID: AccountID(binance.id),
            timestamp: TaxTime.dateKST(year: 2027, month: 4, day: 2),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "t", rawRef: "r2"
        )
        out.fingerprint = "fp-out"
        let outEntity = EntityMappers.makeEntity(from: out)
        outEntity.project = project
        project.events.append(outEntity)
        ctx.insert(outEntity)
        try ctx.save()
        XCTAssertThrowsError(try matching.moveToWallet(withdrawal: outEntity, project: project, receivedQty: 2))

        // 한 번 처리한 출금은 다시 처리할 수 없다
        try matching.moveToWallet(withdrawal: outEntity, project: project)
        XCTAssertThrowsError(try matching.moveToWallet(withdrawal: outEntity, project: project))
    }
}

// MARK: - A-08 한국은행 인증키로 채운 환율이 「참고 시세」로 표시되면 안 된다

final class FXSourceTagTests: XCTestCase {
    /// ECOS 로 채운 날짜와 공개 시세로 채운 날짜를 **날짜 단위로** 구분해야 한다.
    /// 한 덩어리 태그를 쓰면 한국은행으로 정상 조회한 날짜까지 경고에 걸려
    /// 계산이 `검증 완료` 로 올라가지 못한다.
    struct SplitStub: FXClient {
        let ecosDays: Set<String>
        let publicDays: Set<String>
        func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
            try await fetchWithSources(days: days).rates
        }
        func fetchWithSources(days: [String]) async throws -> (rates: [String: Decimal], sources: [String: String]) {
            var rates: [String: Decimal] = [:]
            var sources: [String: String] = [:]
            for d in days where ecosDays.contains(d) {
                rates[d] = 1_400
                sources[d] = "remote-ecos"
            }
            for d in days where publicDays.contains(d) {
                rates[d] = 1_390
                sources[d] = "remote-public"
            }
            return (rates, sources)
        }
    }

    @MainActor
    func testPerDaySourceTagIsStored() async throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = ProjectEntity(name: "fx-src", defaultTaxYear: 2027)
        ctx.insert(project)
        let svc = FXService(
            modelContext: ctx,
            remoteClient: SplitStub(ecosDays: ["2027-03-02"], publicDays: ["2027-03-03"])
        )
        _ = try await svc.fillMissingFromRemote(days: ["2027-03-02", "2027-03-03"], project: project, force: true)

        let byDay = Dictionary(project.fxRates.map { ($0.day, $0.source) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byDay["2027-03-02"], "remote-ecos")
        XCTAssertEqual(byDay["2027-03-03"], "remote-public")
        XCTAssertTrue(svc.lastRemoteFilledECOS)

        // 「참고 시세 사용」 판정은 정확히 remote-public 인 날짜만 세야 한다
        let publicCount = project.fxRates.filter { $0.source == "remote-public" }.count
        XCTAssertEqual(publicCount, 1)
    }

    /// 기본 구현만 가진 클라이언트도 태그가 붙어야 한다 (nil·빈 문자열 금지)
    @MainActor
    func testDefaultSourceTagIsApplied() async throws {
        struct Simple: FXClient {
            func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
                Dictionary(uniqueKeysWithValues: days.map { ($0, Decimal(1_300)) })
            }
        }
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = ProjectEntity(name: "fx-default", defaultTaxYear: 2027)
        ctx.insert(project)
        let svc = FXService(modelContext: ctx, remoteClient: Simple())
        _ = try await svc.fillMissingFromRemote(days: ["2027-03-02"], project: project, force: true)
        XCTAssertEqual(project.fxRates.first?.source, "remote")
        XCTAssertFalse(svc.lastRemoteFilledECOS)
    }
}

// MARK: - A-05 여러 거래소 파일을 한 번에 넣어도 계정이 나뉘어야 한다

final class ImportRoutingTests: XCTestCase {
    private func synthetic(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/samples/synthetic/\(name)")
    }

    func testParserIDMapsToExchange() {
        XCTAssertEqual(ImportRouter.exchange(forParserID: "bithumb-certificate-pdf-v1"), .bithumb)
        XCTAssertEqual(ImportRouter.exchange(forParserID: "binance-spot-xlsx-v1"), .binance)
        XCTAssertEqual(ImportRouter.exchange(forParserID: "binance-deposit-xlsx-v1"), .binance)
        XCTAssertEqual(ImportRouter.exchange(forParserID: "binance-withdraw-xlsx-v1"), .binance)
        XCTAssertEqual(ImportRouter.exchange(forParserID: "okx-trading-history-csv-v1"), .okx)
        XCTAssertEqual(ImportRouter.exchange(forParserID: "okx-funding-history-csv-v1"), .okx)
        // 제네릭은 어느 거래소인지 알 수 없다 → 자동 배정 금지
        XCTAssertNil(ImportRouter.exchange(forParserID: "generic-tabular-v1"))
    }

    func testSyntheticFilesRouteToCorrectExchange() {
        let cases: [(String, ExchangeCode)] = [
            ("binance_spot_sample.csv", .binance),
            ("binance_deposit_sample.csv", .binance),
            ("binance_withdraw_sample.csv", .binance),
            ("okx_trading_history_sample.csv", .okx),
            ("okx_funding_history_sample.csv", .okx)
        ]
        for (name, expected) in cases {
            let route = ImportRouter.route(FormatProbe.probe(url: synthetic(name)))
            XCTAssertEqual(route.exchange, expected, name)
            XCTAssertTrue(route.isConfident, "\(name) 신뢰도 \(route.score)")
        }
    }

    /// 제네릭 표는 자동으로 어느 계정에도 들어가면 안 된다 — 사용자에게 물어야 한다
    func testGenericTableIsNotAutoRouted() {
        let route = ImportRouter.route(FormatProbe.probe(url: synthetic("generic_tabular_sample.csv")))
        XCTAssertFalse(route.isConfident)
        XCTAssertNil(route.exchange)
    }

    @MainActor
    func testMultipleExchangeFilesLandInSeparateAccounts() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let ps = ProjectService(modelContext: ctx)
        let project = try ps.createProject(name: "routing")
        let svc = ImportService(modelContext: ctx)

        let files = ["binance_spot_sample.csv", "okx_trading_history_sample.csv", "okx_funding_history_sample.csv"]
        for name in files {
            let resolved = try XCTUnwrap(svc.resolveAccount(url: synthetic(name), project: project), name)
            _ = try svc.importFile(url: synthetic(name), project: project, account: resolved.account)
        }

        let binanceID = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" }).id
        let okxID = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "okx" }).id
        XCTAssertFalse(project.events.filter { $0.accountID == binanceID }.isEmpty)
        XCTAssertFalse(project.events.filter { $0.accountID == okxID }.isEmpty)
        // 한 계정에 몰리면 원가법이 뒤바뀌고 거래소 간 전송이 매칭되지 않는다
        XCTAssertNotEqual(binanceID, okxID)
    }

    /// 계정이 지워진 프로젝트에서도 자동 배정이 성립해야 한다
    @MainActor
    func testMissingAccountIsCreatedOnDemand() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let ps = ProjectService(modelContext: ctx)
        let project = try ps.createProject(name: "empty")
        for acc in project.accounts { ctx.delete(acc) }
        project.accounts.removeAll()
        try ctx.save()

        let svc = ImportService(modelContext: ctx)
        let resolved = try XCTUnwrap(svc.resolveAccount(url: synthetic("binance_spot_sample.csv"), project: project))
        XCTAssertEqual(resolved.account.exchangeCode, "binance")
        XCTAssertEqual(resolved.account.costMethod, CostBasisMethod.fifo.rawValue)
    }
}
