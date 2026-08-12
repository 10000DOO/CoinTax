import XCTest
import SwiftData
@testable import CoinTax

/// 「잘못 보내 소멸」 지정 — 개인지갑도 아니고 상대 거래소도 없는 출금.
///
/// 세액은 바뀌지 않는다(취득원가 소멸은 미연결 출금과 동일). 바뀌는 것은
/// 「아직 확인 안 한 건」과 구분된다는 점이다 — 그래서 문구와 남은 할 일 수를 검증한다.
final class LostWithdrawalTests: XCTestCase {

    @MainActor
    private func project() throws -> (ModelContext, ProjectEntity) {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let p = try ProjectService(modelContext: ctx).createProject(name: "lost")
        return (ctx, p)
    }

    @MainActor
    func testMarkAndUnmark() throws {
        let (ctx, p) = try project()
        let acc = try XCTUnwrap(p.accounts.first { $0.exchangeCode == "binance" })
        let out = LedgerEventEntity(accountID: acc.id, fingerprint: "f1",
                                    timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
                                    type: EventType.withdrawal.rawValue, baseAsset: "BTC",
                                    quantity: "-0.5", sourceKind: "t")
        out.project = p
        p.events.append(out)
        ctx.insert(out)
        try ctx.save()

        let svc = MatchingService(modelContext: ctx)
        XCTAssertFalse(out.lostForever)
        try svc.markLost(withdrawal: out, project: p)
        XCTAssertTrue(out.lostForever)
        try svc.markLost(withdrawal: out, project: p, lost: false)
        XCTAssertFalse(out.lostForever)
    }

    @MainActor
    func testDepositCannotBeMarked() throws {
        let (ctx, p) = try project()
        let acc = try XCTUnwrap(p.accounts.first { $0.exchangeCode == "binance" })
        let dep = LedgerEventEntity(accountID: acc.id, fingerprint: "f2",
                                    timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
                                    type: EventType.deposit.rawValue, baseAsset: "BTC",
                                    quantity: "0.5", sourceKind: "t")
        dep.project = p
        p.events.append(dep)
        ctx.insert(dep)
        try ctx.save()
        XCTAssertThrowsError(try MatchingService(modelContext: ctx).markLost(withdrawal: dep, project: p))
    }

    /// 이미 연결된 출금은 소멸로 지정할 수 없다 — 원가가 두 곳으로 갈라진다.
    @MainActor
    func testLinkedWithdrawalCannotBeMarked() throws {
        let (ctx, p) = try project()
        let acc = try XCTUnwrap(p.accounts.first { $0.exchangeCode == "binance" })
        let out = LedgerEventEntity(accountID: acc.id, fingerprint: "f3",
                                    timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
                                    type: EventType.withdrawal.rawValue, baseAsset: "BTC",
                                    quantity: "-0.5", sourceKind: "t")
        out.project = p
        p.events.append(out)
        ctx.insert(out)
        let link = TransferLinkEntity(fromEventID: out.id, toEventID: UUID(),
                                      status: LinkStatus.confirmed.rawValue,
                                      withdrawnQty: "0.5", receivedQty: "0.5")
        link.project = p
        p.links.append(link)
        ctx.insert(link)
        try ctx.save()
        XCTAssertThrowsError(try MatchingService(modelContext: ctx).markLost(withdrawal: out, project: p))
    }

    /// 세액은 그대로, 문구만 달라진다.
    func testTaxUnchangedButMessageDiffers() throws {
        let projectID = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: projectID)
        let buy = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 1, day: 5),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: "t", rawRef: "r1"
        )
        var send = LedgerEvent(
            projectID: projectID, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 2, day: 5),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"),
            quantity: -1, sourceKind: "t", rawRef: "r2"
        )
        func replay(_ events: [LedgerEvent]) throws -> ReplayResult {
            let engine = CostBasisEngine(
                policies: .v1Default, accountsByID: [acc.id: acc],
                fxRates: [:], marketPrices: [:]
            )
            return try engine.replay(events: events, links: [])
        }
        let before = try replay([buy, send])
        send.lostForever = true
        let after = try replay([buy, send])

        // 원가 소멸 금액이 같다 = 세액이 같다
        XCTAssertEqual(before.abandonedTotal, after.abandonedTotal)
        XCTAssertEqual(before.abandonedTotal, 50_000_000)

        let msgBefore = try XCTUnwrap(before.issues.first { $0.id == "V-QTY-04" }).message
        let msgAfter = try XCTUnwrap(after.issues.first { $0.id == "V-QTY-04" }).message
        XCTAssertTrue(msgBefore.contains("연결"), msgBefore)
        XCTAssertTrue(msgAfter.contains("잘못 보내 소멸"), msgAfter)
    }
}
