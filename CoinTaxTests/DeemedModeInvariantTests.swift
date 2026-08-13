import XCTest
@testable import CoinTax

/// 의제취득가 **두 방식의 관계**가 앱이 화면에 적어 둔 설명과 늘 맞는가 (5차 감사).
///
/// 앱은 사용자에게 이렇게 말한다 (`DeemedBasisMode.detail`):
/// - 보유 평균 방식: 「취득가가 더 **작게** 잡혀 세금이 다소 커지는 쪽입니다」
/// - 매입 건별 방식: 「취득가가 더 **크게** 잡혀 세금이 줄어들 수 있습니다」
///
/// 이건 수학적으로 항상 성립한다 — 건별로 `max(단가, 시가)` 를 취해 더한 값은
/// 평균에 `max` 를 한 번 취한 값보다 작아질 수 없다.
/// 코드가 그 관계를 깨면 **사용자에게 한 설명이 거짓말이 된다** (게다가 어느 쪽이 맞는지는
/// 확정 해석이 없어 TQ-01 로 남아 있으므로, 두 값 자체가 판단 근거다).
final class DeemedModeInvariantTests: XCTestCase {

    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private static let assets = ["BTC", "ETH", "TRX"]

    /// 과세 시작 전 매입 여러 건 + 2027 처분 (선입선출 계정이라야 두 방식이 갈린다)
    private func scenario(seed: UInt64) -> (events: [LedgerEvent], accounts: [AccountID: Account], market: [String: Decimal]) {
        var rng = RNG(state: seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493)
        let pid = ProjectID()
        let binance = Account.defaults(for: .binance, projectID: pid)
        var events: [LedgerEvent] = []
        var held: [String: Decimal] = [:]
        var i = 0

        func stamp() -> String { i += 1; return String(format: "r%05d", i) }

        // 2026: 자산마다 매입 2~4건 (단가가 서로 다르게)
        for asset in Self.assets {
            let lots = 2 + Int(rng.next() % 3)
            for l in 0..<lots {
                let qty = Decimal(1 + Int(rng.next() % 40)) / 10
                let unit = Decimal(1_000 + Int(rng.next() % 9_000)) * 1_000
                events.append(LedgerEvent(
                    projectID: pid, accountID: binance.id,
                    timestamp: TaxTime.dateKST(year: 2026, month: 1 + l, day: 5 + l, hour: 10),
                    type: .buy, baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("KRW"),
                    quantity: qty, quoteAmountKRW: qty * unit,
                    sourceKind: "deemed", rawRef: stamp()
                ))
                held[asset, default: 0] += qty
            }
        }
        // 2027: 보유분의 일부를 판다
        for asset in Self.assets {
            let have = held[asset] ?? 0
            guard have > 0 else { continue }
            let qty = have * Decimal(30 + Int(rng.next() % 60)) / 100
            events.append(LedgerEvent(
                projectID: pid, accountID: binance.id,
                timestamp: TaxTime.dateKST(year: 2027, month: 4, day: 1, hour: 10),
                type: .sell, baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("KRW"),
                quantity: -qty, quoteAmountKRW: qty * Decimal(1_000 + Int(rng.next() % 12_000)) * 1_000,
                sourceKind: "deemed", rawRef: stamp()
            ))
        }
        // 시가: 자산마다 다르게 (어떤 자산은 장부보다 높고 어떤 자산은 낮게)
        var market: [String: Decimal] = [:]
        for (n, asset) in Self.assets.enumerated() where (seed + UInt64(n)) % 4 != 0 {
            market[asset] = Decimal(1_000 + Int(rng.next() % 9_000)) * 1_000
        }
        return (events, [binance.id: binance], market)
    }

    private func summarize(_ s: (events: [LedgerEvent], accounts: [AccountID: Account], market: [String: Decimal]),
                           mode: DeemedBasisMode) throws -> (deemedTotal: Decimal, tax: Decimal, income: Decimal) {
        var policies = PolicyBundle.v1Default
        policies.deemed = MaxBookMarketDeemedPolicy(mode: mode)
        let r = try CostBasisEngine(policies: policies, accountsByID: s.accounts,
                                    fxRates: [:], marketPrices: s.market)
            .replay(events: s.events, links: [])
        let summary = TaxAggregator.aggregate(
            projectID: ProjectID(), disposals: r.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: r.deemedPositions, policies: policies
        )
        return (summary.totalDeemedCostKRW, summary.totalTaxKRW, summary.netIncomeKRW)
    }

    func testPerLotNeverGivesLessTotalDeemedCost() throws {
        var sawDifference = 0, taxFlipped = 0
        for seed in UInt64(1)...80 {
            let s = scenario(seed: seed)
            let avg = try summarize(s, mode: .positionAverage)
            let lot = try summarize(s, mode: .perLot)
            XCTAssertGreaterThanOrEqual(
                lot.deemedTotal, avg.deemedTotal - 1,
                "seed \(seed): 건별 방식의 **총** 의제취득가가 평균 방식보다 작다"
            )
            if lot.deemedTotal != avg.deemedTotal { sawDifference += 1 }
            if lot.tax > avg.tax { taxFlipped += 1 }
        }
        XCTAssertGreaterThan(sawDifference, 20, "두 방식이 갈리는 시나리오가 거의 없다")

        // **세액 방향은 뒤집힐 수 있다** — 이건 버그가 아니라 선입선출 + 부분 처분의 성질이다.
        //
        // 평균 방식은 lot 을 하나로 합쳐 **먼저 나가는 싼 매입 건에도 평균 단가**를 붙인다.
        // 건별 방식은 싼 lot 이 싼 채로 남아 그해 취득가가 오히려 작아질 수 있다.
        // 앱 문구가 「평균 방식 = 세금이 큰 쪽」이라고 단정하고 있었는데 사실이 아니었다 (회차 17에서 수정).
        // 나중에 누군가 문구에 맞추려고 엔진을 「고치지」 않도록 여기 고정한다.
        XCTAssertGreaterThan(
            taxFlipped, 0,
            "세액 방향이 한 번도 안 뒤집혔다 — 엔진이 바뀌었거나 생성기가 좁아졌다. 문구도 함께 확인하라"
        )
    }

    /// 리포트의 「다른 방식으로 계산하면」 숫자를 **검산하는 검사가 실제로 도는가** (V-DEM-06).
    ///
    /// 이 숫자는 두 번째 엔진 실행에서 나오고 사용자가 방식을 고르는 근거가 된다.
    /// 지금까지 아무도 검산하지 않았다 (5차 감사 회차 21).
    func testAlternativeDeemedDirectionIsChecked() throws {
        let s = scenario(seed: 3)
        let policies = PolicyBundle.v1Default   // 채택 = 평균
        let r = try CostBasisEngine(policies: policies, accountsByID: s.accounts,
                                    fxRates: [:], marketPrices: s.market)
            .replay(events: s.events, links: [])
        XCTAssertFalse(r.deemedPositions.isEmpty, "의제 대상이 있어야 이 경로를 본다")

        var summary = TaxAggregator.aggregate(
            projectID: ProjectID(), disposals: r.disposals, taxYear: 2027,
            extraDeductible: 0, abandonedTransferCostKRW: 0,
            deemed: r.deemedPositions, policies: policies
        )
        summary.deemedBasisMode = DeemedBasisMode.positionAverage.rawValue

        func issues(_ sum: TaxYearSummary) -> [String] {
            Verifier.verify(VerifierInput(summary: sum, replay: r, policies: policies,
                                          events: s.events, summaryRerun: sum, links: []))
                .issues.filter { $0.id == "V-DEM-06" }.map(\.severity)
        }

        // 올바른 방향: 건별(비교) ≥ 평균(채택)
        summary.deemedAlternative = DeemedAlternative(
            basisMode: DeemedBasisMode.perLot.rawValue, basisLabel: "건별",
            totalDeemedCostKRW: summary.totalDeemedCostKRW + 1_000_000,
            netIncomeKRW: 0, totalTaxKRW: 0
        )
        XCTAssertTrue(issues(summary).isEmpty, "정상 방향인데 잡았다")

        // 뒤집힌 방향: 건별이 평균보다 작다 → 두 실행 중 하나가 잘못 돌았다는 뜻
        summary.deemedAlternative = DeemedAlternative(
            basisMode: DeemedBasisMode.perLot.rawValue, basisLabel: "건별",
            totalDeemedCostKRW: summary.totalDeemedCostKRW - 1_000_000,
            netIncomeKRW: 0, totalTaxKRW: 0
        )
        XCTAssertTrue(issues(summary).contains("critical"), "방향이 뒤집혔는데 잡지 못했다")

    }

    /// 시가가 아예 없으면 두 방식이 같아야 한다 (재기동 자체가 없다)
    func testWithoutMarketPricesBothModesAgree() throws {
        for seed in UInt64(1)...20 {
            var s = scenario(seed: seed)
            s.market = [:]
            let avg = try summarize(s, mode: .positionAverage)
            let lot = try summarize(s, mode: .perLot)
            XCTAssertEqual(avg.tax, lot.tax, "seed \(seed): 시가가 없는데 방식에 따라 세금이 달라졌다")
            XCTAssertEqual(avg.deemedTotal, 0)
            XCTAssertEqual(lot.deemedTotal, 0)
        }
    }
}
