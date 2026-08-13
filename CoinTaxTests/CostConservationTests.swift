import XCTest
@testable import CoinTax

/// **원가 보존 법칙** — 장부에 들어온 돈과 나간 돈이 맞는가 (5차 감사).
///
/// 기존 무작위 시나리오 테스트(`PropertyTests`·`PropertyWideTests`)는 **수량**을 생성기의
/// 의도와 대조한다. 그런데 **금액**은 엔진이 낸 값끼리만 비교한다 —
/// 「건별 손익 합 = 소득금액」은 둘 다 같은 `pnlKRW` 에서 나오므로 정의상 맞는다.
/// 그래서 원가가 새거나 두 번 잡히는 결함은 이 그물에 걸리지 않는다.
///
/// 여기서는 엔진 밖에서 세운 등식을 건다:
///
/// ```text
/// 들어온 돈  = Σ 매수 대금(원화) + Σ 원화 매수수수료 + Σ 의제 증액
/// 나간 돈    = Σ 처분 취득원가 + Σ 장부에서 나온 수수료 + Σ 소멸 원가 + 남은 장부원가
/// 두 값은 같아야 한다.
/// ```
///
/// 한쪽이라도 어긋나면 **필요경비가 실제보다 크거나 작다** = 세금이 틀린다.
final class CostConservationTests: XCTestCase {

    // MARK: - 재현 가능한 난수

    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private struct Scenario {
        var accounts: [Account]
        var events: [LedgerEvent]
        var links: [TransferLink]
        var market: [String: Decimal]
    }

    private static let assets = ["BTC", "ETH", "USDT", "TRX"]

    /// 원화 마켓만 쓴다 — 환율이 끼면 「들어온 돈」을 엔진 밖에서 다시 계산할 수 없다.
    /// (환율 경로는 `OracleTaxPathTests` 가 손계산으로 따로 본다)
    private func makeScenario(seed: UInt64) -> Scenario {
        var rng = RNG(state: seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407)
        let pid = ProjectID()
        let accounts = [
            Account.defaults(for: .bithumb, projectID: pid),   // 이동평균
            Account.defaults(for: .binance, projectID: pid),   // 선입선출
            Account.defaults(for: .okx, projectID: pid),
            Account.defaults(for: .wallet, projectID: pid)
        ]
        var events: [LedgerEvent] = []
        var links: [TransferLink] = []
        var held: [String: Decimal] = [:]   // "acc|asset" -> 수량

        func key(_ a: Account, _ s: String) -> String { "\(a.id.raw.uuidString)|\(s)" }
        func stamp(_ i: Int) -> String { String(format: "r%05d", i) }

        let count = 18 + Int(rng.next() % 22)
        var day = 0
        for i in 0..<count {
            day += 1 + Int(rng.next() % 40)
            let year = 2026 + (day / 360)
            guard year <= 2029 else { break }
            let month = 1 + (day % 360) / 30
            let dom = 1 + (day % 28)
            let ts = TaxTime.dateKST(year: year, month: month, day: min(month == 2 ? 28 : 28, dom), hour: Int(rng.next() % 24))
            let acc = accounts[Int(rng.next() % UInt64(accounts.count))]
            let asset = Self.assets[Int(rng.next() % UInt64(Self.assets.count))]
            let k = key(acc, asset)
            let roll = rng.next() % 100

            // 수수료 종류: 없음 / 원화 / 기초자산 / 제3자산
            func feeSpec() -> (Decimal, AssetSymbol)? {
                switch rng.next() % 4 {
                case 0: return nil
                case 1: return (Decimal(100 + Int(rng.next() % 900)), AssetSymbol("KRW"))
                case 2: return (Decimal(string: "0.0001")!, AssetSymbol(asset))
                default:
                    let other = Self.assets[Int(rng.next() % UInt64(Self.assets.count))]
                    // 제3자산 수수료는 그 자산 장부가 있어야 의미가 있다
                    guard other != asset, (held[key(acc, other)] ?? 0) > Decimal(string: "0.001")! else { return nil }
                    return (Decimal(string: "0.0005")!, AssetSymbol(other))
                }
            }

            if roll < 42 || (held[k] ?? 0) <= 0 {
                // 매수 (원화 마켓)
                let qty = Decimal(1 + Int(rng.next() % 500)) / 100
                let krw = Decimal(10_000 + Int(rng.next() % 5_000_000))
                let fee = feeSpec()
                var e = LedgerEvent(
                    projectID: pid, accountID: acc.id, timestamp: ts, type: .buy,
                    baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("KRW"),
                    quantity: qty, quoteAmountKRW: krw,
                    feeAmount: fee?.0, feeAsset: fee?.1,
                    sourceKind: "conserve", rawRef: stamp(i)
                )
                e.fingerprint = "c\(i)"
                events.append(e)
                var net = qty
                if let fee, fee.1 == AssetSymbol(asset) { net = max(0, qty - fee.0) }
                held[k, default: 0] += net
                if let fee, !fee.1.isKRW, fee.1 != AssetSymbol(asset) {
                    held[key(acc, fee.1.code), default: 0] -= fee.0
                }
            } else if roll < 72 {
                // 매도 (보유 범위 안에서만 — 재고 부족은 다른 테스트가 본다)
                let have = held[k] ?? 0
                let qty = have * Decimal(10 + Int(rng.next() % 80)) / 100
                guard qty > 0 else { continue }
                let fee = feeSpec()
                var e = LedgerEvent(
                    projectID: pid, accountID: acc.id, timestamp: ts, type: .sell,
                    baseAsset: AssetSymbol(asset), quoteAsset: AssetSymbol("KRW"),
                    quantity: -qty, quoteAmountKRW: Decimal(10_000 + Int(rng.next() % 8_000_000)),
                    feeAmount: fee?.0, feeAsset: fee?.1,
                    sourceKind: "conserve", rawRef: stamp(i)
                )
                e.fingerprint = "c\(i)"
                events.append(e)
                held[k] = have - qty
                if let fee, fee.1 == AssetSymbol(asset) { held[k]! -= fee.0 }
                if let fee, !fee.1.isKRW, fee.1 != AssetSymbol(asset) {
                    held[key(acc, fee.1.code), default: 0] -= fee.0
                }
            } else if roll < 90 {
                // 전송 — 절반은 연결(원가 이전), 절반은 미연결(원가 소멸)
                let have = held[k] ?? 0
                let qty = have * Decimal(20 + Int(rng.next() % 60)) / 100
                guard qty > Decimal(string: "0.0001")! else { continue }
                // 출금 수수료: 없음 / 보내는 코인 / 원화
                let wFee: (Decimal, AssetSymbol?)? = {
                    switch rng.next() % 3 {
                    case 0: return nil
                    case 1: return (qty / 1000, AssetSymbol(asset))
                    default: return (Decimal(1_000), AssetSymbol("KRW"))
                    }
                }()
                var w = LedgerEvent(
                    projectID: pid, accountID: acc.id, timestamp: ts, type: .withdrawal,
                    baseAsset: AssetSymbol(asset), quantity: -qty,
                    feeAmount: wFee?.0, feeAsset: wFee?.1,
                    sourceKind: "conserve", rawRef: stamp(i)
                )
                w.fingerprint = "c\(i)w"
                events.append(w)
                held[k] = have - qty
                if let wFee, wFee.1 == AssetSymbol(asset) { held[k]! -= wFee.0 }

                if rng.next() % 2 == 0 {
                    var dest = accounts[Int(rng.next() % UInt64(accounts.count))]
                    if dest.id == acc.id { dest = accounts[(accounts.firstIndex { $0.id == acc.id }! + 1) % accounts.count] }
                    let arrived = qty * Decimal(95 + Int(rng.next() % 6)) / 100
                    var d = LedgerEvent(
                        projectID: pid, accountID: dest.id,
                        timestamp: ts.addingTimeInterval(3600), type: .deposit,
                        baseAsset: AssetSymbol(asset), quantity: arrived,
                        sourceKind: "conserve", rawRef: stamp(i) + "d"
                    )
                    d.fingerprint = "c\(i)d"
                    events.append(d)
                    held[key(dest, asset), default: 0] += arrived
                    links.append(TransferLink(
                        id: LinkID(), projectID: pid, fromEventID: w.id, toEventID: d.id,
                        status: .confirmed, withdrawnQty: qty, receivedQty: arrived
                    ))
                }
            } else {
                // 보상 (취득가 0원)
                var e = LedgerEvent(
                    projectID: pid, accountID: acc.id, timestamp: ts, type: .income,
                    baseAsset: AssetSymbol(asset),
                    quantity: Decimal(1 + Int(rng.next() % 50)) / 1000,
                    sourceKind: "conserve", rawRef: stamp(i)
                )
                e.fingerprint = "c\(i)"
                events.append(e)
                held[k, default: 0] += Money.abs(e.quantity)
            }
        }

        // 시가: 자산마다 넣거나 뺀다 (의제 증액 경로를 절반쯤 태운다)
        var market: [String: Decimal] = [:]
        for (i, a) in Self.assets.enumerated() where (seed + UInt64(i)) % 3 != 0 {
            market[a] = Decimal(1_000 * (1 + Int(rng.next() % 900)))
        }
        return Scenario(accounts: accounts, events: events, links: links, market: market)
    }

    // MARK: - 법칙

    /// 엔진 **밖에서** 계산한 「들어온 돈」과 「나간 돈」.
    private func conservationGap(_ s: Scenario, _ r: ReplayResult) -> (inflow: Decimal, outflow: Decimal) {
        let byID = Dictionary(s.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 들어온 돈: 원화 매수 대금 + 원화로 낸 매수 수수료 (그만큼 취득가에 가산된다)
        var inflow: Decimal = 0
        for e in s.events {
            switch e.type {
            case .buy:
                inflow += Money.abs(e.quoteAmountKRW ?? 0)
                if let fa = e.feeAsset, fa.isKRW, let amt = e.feeAmount { inflow += Money.abs(amt) }
            default:
                break
            }
        }
        // 의제 증액 — 2027-01-01 0시에 장부를 max(장부, 시가)로 다시 세운 만큼
        for d in r.deemedPositions {
            inflow += (d.deemedUnitKRW - d.bookUnitKRW) * d.quantity
        }

        // 나간 돈: 처분 취득원가 + **장부에서 나온** 수수료 + 소멸 원가 + 남은 장부원가
        var outflow: Decimal = 0
        for d in r.disposals {
            outflow += d.costKRW
            // 원화 수수료는 장부를 거치지 않는다 — 여기 더하면 두 번 세는 셈이다
            let feeFromBook = byID[d.eventID].map { e -> Bool in
                guard let fa = e.feeAsset else { return false }
                return !fa.isKRW
            } ?? false
            if feeFromBook { outflow += d.feesKRW }
        }
        outflow += r.abandonedTotal
        outflow += r.holdings.rows.reduce(Decimal(0)) { $0 + $1.totalCostKRW }
        return (inflow, outflow)
    }

    // MARK: - 검사

    func testCostIsConservedAcrossRandomScenarios() throws {
        var withDeemed = 0, withLinks = 0, totalEvents = 0
        var worstGap: Decimal = 0
        var totalInflow: Decimal = 0
        for seed in UInt64(1)...150 {
            let s = makeScenario(seed: seed)
            guard !s.events.isEmpty else { continue }
            totalEvents += s.events.count
            let engine = CostBasisEngine(
                policies: .v1Default,
                accountsByID: Dictionary(s.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                fxRates: [:], marketPrices: s.market
            )
            let r = try engine.replay(events: s.events, links: s.links)
            if !r.deemedPositions.isEmpty { withDeemed += 1 }
            if !s.links.isEmpty { withLinks += 1 }

            let (inflow, outflow) = conservationGap(s, r)
            totalInflow += inflow
            worstGap = max(worstGap, Money.abs(inflow - outflow))
            // 허용 오차: 나눗셈(부분 처분·의제 단가)이 끼는 자리마다 마지막 자리가 흔들린다.
            let tolerance = Decimal(max(10, r.disposals.count + r.deemedPositions.count))
            XCTAssertLessThanOrEqual(
                Money.abs(inflow - outflow), tolerance,
                """
                seed \(seed): 원가가 맞지 않는다 — 들어온 \(Money.decimalString(Money.roundKRW(inflow))) / \
                나간 \(Money.decimalString(Money.roundKRW(outflow))) \
                (차이 \(Money.decimalString(Money.roundKRW(inflow - outflow))))
                """
            )
        }
        // 생성기가 실제로 그 경우를 만들었는지 — 안 세면 「통과」가 공짜로 나온다
        XCTAssertGreaterThan(totalEvents, 2_000, "시나리오가 너무 작다")
        XCTAssertGreaterThan(withDeemed, 60, "의제 증액 경로가 거의 안 탔다")
        XCTAssertGreaterThan(withLinks, 60, "전송 연결 경로가 거의 안 탔다")
        // 허용 오차가 결함을 덮고 있지 않은지 — 실제 어긋남은 **1원 미만**이어야 한다.
        // (허용 오차만 보면 「40원까지는 새도 통과」인지 「사실상 0인지」를 구분할 수 없다)
        XCTAssertLessThan(worstGap, 1, "최대 어긋남 \(Money.decimalString(worstGap))원 — 허용 오차가 결함을 덮고 있다")
        XCTAssertGreaterThan(totalInflow, 1_000_000_000, "흘려보낸 금액이 너무 적어 0 = 0 을 확인한 셈이다")
    }

    /// 법칙이 **진짜로 잡는가** — 원가를 일부러 새게 만들면 실패해야 한다 (변이 테스트).
    func testConservationCatchesALeak() throws {
        let s = makeScenario(seed: 7)
        let engine = CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(s.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: [:], marketPrices: s.market
        )
        var r = try engine.replay(events: s.events, links: s.links)
        let clean = conservationGap(s, r)
        XCTAssertLessThanOrEqual(Money.abs(clean.inflow - clean.outflow), 10)

        // 처분 한 건의 취득원가를 깎는다 = 필요경비가 사라진 것과 같다
        guard let victim = r.disposals.firstIndex(where: { $0.costKRW > 1_000 }) else {
            return XCTFail("원가가 있는 처분이 없다 — 시나리오를 확인하라")
        }
        r.disposals[victim].costKRW -= 1_000
        let broken = conservationGap(s, r)
        XCTAssertGreaterThan(Money.abs(broken.inflow - broken.outflow), 100, "원가를 깎았는데 법칙이 못 잡았다")
    }
}
