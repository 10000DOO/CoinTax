import XCTest
@testable import CoinTax

/// 재고 부족이 **얼마나** 났는지까지 보고 면제하는가 (5차 감사).
///
/// 거래소는 수량을 소수 8자리에서 끊는다. 부분 체결이 이어지면 마지막 자리에 1e-8 수준의
/// 부족이 남는데, 이건 이력 누락이 아니라 반올림이라 앱도 「정상」으로 본다(`Money.dustQtyEpsilon`).
///
/// 문제는 그 **정상적인 먼지 하나가** 그 자산의 수량 대조(V-QTY-01)를 통째로 꺼 버렸다는 것이다.
/// V-QTY-01 은 「엔진이 센 보유량 ≠ 규칙이 센 보유량」을 잡는 마지막 그물이고,
/// 바이낸스는 거래소 잔고 열이 없어 V-BAL 도 없다. 그물이 둘 다 없으면 아무도 못 잡는다.
final class ShortfallExemptionTests: XCTestCase {

    /// 먼지 수준 부족이 난 자산 + 그 뒤에 남은 잔량이 있는 시나리오
    private func makeReplay() throws -> (events: [LedgerEvent], accounts: [AccountID: Account], replay: ReplayResult, key: String) {
        let pid = ProjectID()
        let binance = Account.defaults(for: .binance, projectID: pid)

        func trade(_ month: Int, _ type: EventType, _ qty: Decimal, _ krw: Decimal, _ ref: String) -> LedgerEvent {
            LedgerEvent(
                projectID: pid, accountID: binance.id,
                timestamp: TaxTime.dateKST(year: 2027, month: month, day: 1, hour: 10),
                type: type, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: type == .sell ? -qty : qty, quoteAmountKRW: krw,
                sourceKind: "shortfall", rawRef: ref
            )
        }
        let events = [
            trade(1, .buy, 10, 500_000_000, "r1"),
            // 거래소 반올림 수준으로 아주 조금 더 판다 (1e-8 미만 = 「먼지」)
            trade(2, .sell, Decimal(string: "10.000000005")!, 520_000_000, "r2"),
            trade(3, .buy, 5, 260_000_000, "r3")
        ]
        let byID = [binance.id: binance]
        let replay = try CostBasisEngine(policies: .v1Default, accountsByID: byID, fxRates: [:], marketPrices: [:])
            .replay(events: events, links: [])
        return (events, byID, replay, "\(binance.id.raw.uuidString)|BTC")
    }

    private func verify(_ events: [LedgerEvent], _ replay: ReplayResult) -> VerificationReport {
        let summary = TaxAggregator.aggregate(
            projectID: ProjectID(), disposals: replay.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: replay.deemedPositions, policies: .v1Default
        )
        return Verifier.verify(VerifierInput(
            summary: summary, replay: replay, policies: .v1Default,
            events: events, summaryRerun: summary, links: []
        ))
    }

    /// 의제 스냅샷 수량 검사(V-DEM-01)도 같은 구멍이 있었다.
    ///
    /// 2027-01-01 0시 보유량은 **의제취득가의 곱하는 쪽**이다. 여기가 틀리면
    /// 취득가 총액이 그만큼 통째로 틀어진다.
    func testDeemedSnapshotMismatchIsCaughtOnAnAssetThatHadDust() throws {
        let pid = ProjectID()
        let binance = Account.defaults(for: .binance, projectID: pid)
        func trade(_ month: Int, _ type: EventType, _ qty: Decimal, _ krw: Decimal, _ ref: String) -> LedgerEvent {
            LedgerEvent(
                projectID: pid, accountID: binance.id,
                timestamp: TaxTime.dateKST(year: 2026, month: month, day: 1, hour: 10),
                type: type, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: type == .sell ? -qty : qty, quoteAmountKRW: krw,
                sourceKind: "shortfall", rawRef: ref
            )
        }
        // 과세 시작 **전에** 먼지 부족이 나고, 그 뒤 잔량이 남는다
        let events = [
            trade(1, .buy, 10, 500_000_000, "r1"),
            trade(2, .sell, Decimal(string: "10.000000005")!, 520_000_000, "r2"),
            trade(3, .buy, 5, 260_000_000, "r3")
        ]
        let original = try CostBasisEngine(
            policies: .v1Default, accountsByID: [binance.id: binance],
            fxRates: [:], marketPrices: ["BTC": 60_000_000]
        ).replay(events: events, links: [])
        XCTAssertEqual(original.deemedPositions.count, 1, "의제 대상이 만들어져야 이 경로를 본다")

        // 먼지만 있는 정상 자료에서는 조용해야 한다
        XCTAssertFalse(verify(events, original).issues.contains { $0.id == "V-DEM-01" })

        // 엔진이 의제 스냅샷 수량을 1개 더 세고 있는 상황
        var replay = original
        replay.deemedPositions[0].quantity += 1
        XCTAssertTrue(
            verify(events, replay).issues.contains { $0.id == "V-DEM-01" && $0.severity == "critical" },
            "먼지 부족 때문에 의제 스냅샷 수량 차이를 못 잡았다"
        )
    }

    /// 먼지만 있는 정상 자료에서는 조용해야 한다 (오탐 방지)
    func testDustShortfallAloneDoesNotRaiseQuantityMismatch() throws {
        let (events, _, replay, _) = try makeReplay()
        XCTAssertFalse(replay.shortfallKeys.isEmpty, "먼지 부족이 안 났다 — 시나리오 설정 오류")
        let report = verify(events, replay)
        XCTAssertFalse(
            report.issues.contains { $0.id == "V-QTY-01" },
            "정상 반올림인데 수량 불일치로 잡았다: \(report.issues.map(\.message))"
        )
    }

    /// **먼지가 났다고 해서 그 자산의 진짜 불일치까지 봐주면 안 된다.**
    ///
    /// 엔진이 그 자산을 1 BTC 더 세고 있는 상황을 만들어 놓고 검증기가 잡는지 본다.
    func testRealMismatchIsStillCaughtOnAnAssetThatHadDust() throws {
        let (events, _, original, key) = try makeReplay()
        var replay = original

        // 엔진 결과만 손댄다 (규칙·이벤트는 그대로) = 「엔진이 1 BTC 더 세고 있다」
        let idx = try XCTUnwrap(replay.holdings.rows.firstIndex { $0.asset.code == "BTC" })
        replay.holdings.rows[idx].quantity += 1
        XCTAssertTrue(replay.shortfallKeys.contains(key))

        let report = verify(events, replay)
        XCTAssertTrue(
            report.issues.contains { $0.id == "V-QTY-01" && $0.severity == "critical" },
            """
            먼지 부족 때문에 그 자산이 통째로 면제되어 1 BTC 차이를 못 잡았다.
            나온 검사: \(report.issues.map(\.id))
            """
        )
    }
}
