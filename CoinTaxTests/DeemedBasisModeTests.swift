import XCTest
@testable import CoinTax

/// 의제취득가 비교 단위 — `[영]` 소득세법 시행령 §88① 이후.
///
/// 예전에는 「보유 전체 평균」과 「매입 건별」 두 방식을 모두 지원하고 리포트에 두 값을
/// 나란히 보여줬다(TQ-01). 2025-02-28 개정으로 취득가액 계산이 **거주자별 총평균법**이
/// 되면서 **매입 건(lot) 개념 자체가 사라졌고**, 비교 대상은 자산별 단가 하나뿐이라
/// 고를 여지가 없어졌다 (작업문서 Q1 결정).
///
/// 그래서 여기서는 「선택지가 하나뿐인가」와 「그 하나가 §37⑤ 대로 동작하는가」를 본다.
final class DeemedBasisModeTests: XCTestCase {

    /// 고를 수 있는 방식이 하나뿐이어야 한다 — 화면에 의미 없는 선택지를 남기면 안 된다
    func testOnlyOneModeExists() {
        XCTAssertEqual(DeemedBasisMode.allCases, [.positionAverage])
        XCTAssertEqual(DeemedPreferences.basisMode, .positionAverage)
        // 저장된 옛 값이 있어도 무시한다
        UserDefaults.standard.set("perLot", forKey: "deemed.basisMode")
        XCTAssertEqual(DeemedPreferences.basisMode, .positionAverage, "폐지된 방식이 되살아나면 안 된다")
        UserDefaults.standard.removeObject(forKey: "deemed.basisMode")
    }

    /// 같은 코인을 **다른 계정에 다른 값으로** 사도 의제 단가는 하나다 (§88① "거주자별로").
    ///
    /// 4천만·8천만에 1개씩 사고 시가가 6천만이면
    /// - 거주자 평균 취득단가 = 6천만
    /// - 의제 단가 = max(6천만, 6천만) = 6천만 → 총 1.2억
    ///
    /// 예전 「매입 건별」은 max(4천,6천) + max(8천,6천) = 1.4억이었다. 계산할 lot 이 없어졌다.
    func testDeemedUsesOneResidentUnit() throws {
        let pid = ProjectID()
        let a1 = Account.defaults(for: .binance, projectID: pid)
        let a2 = Account.defaults(for: .okx, projectID: pid)
        func buy(_ acc: Account, _ krw: Decimal, _ ref: String) -> LedgerEvent {
            LedgerEvent(
                projectID: pid, accountID: acc.id,
                timestamp: TaxTime.dateKST(year: 2026, month: 5, day: 1),
                type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                quantity: 1, quoteAmountKRW: krw, sourceKind: "t", rawRef: ref
            )
        }
        let r = try CostBasisEngine(
            policies: .v1Default,
            accountsByID: [a1.id: a1, a2.id: a2],
            fxRates: [:], marketPrices: ["BTC": 60_000_000]
        ).replay(events: [buy(a1, 40_000_000, "a"), buy(a2, 80_000_000, "b")], links: [])

        let total = r.deemedPositions.reduce(Decimal(0)) { $0 + $1.totalDeemedKRW }
        XCTAssertEqual(total, 120_000_000, "거주자 평균 6천만 × 2개")
        // 계정이 둘이어도 단가는 하나다
        XCTAssertEqual(Set(r.deemedPositions.map(\.deemedUnitKRW)), [60_000_000])
        XCTAssertTrue(r.deemedPositions.allSatisfy { $0.lotCount == 1 }, "매입 건 개념이 없다")
    }

    /// 시가가 평균보다 높으면 시가를 쓴다 (`[법]` §37⑤ — 큰 금액)
    func testTakesMarketWhenHigher() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .bithumb, projectID: pid)
        let buy = LedgerEvent(
            projectID: pid, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2026, month: 5, day: 1),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 40_000_000, sourceKind: "t", rawRef: "a"
        )
        let r = try CostBasisEngine(
            policies: .v1Default, accountsByID: [acc.id: acc],
            fxRates: [:], marketPrices: ["BTC": 90_000_000]
        ).replay(events: [buy], links: [])
        let dem = try XCTUnwrap(r.deemedPositions.first)
        XCTAssertEqual(dem.deemedUnitKRW, 90_000_000)
        XCTAssertEqual(dem.reason, "market")
    }
}
