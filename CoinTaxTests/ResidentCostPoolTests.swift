import XCTest
@testable import CoinTax

/// 거주자별 총평균법 원가 풀 — 손계산으로 고정한다.
/// 근거: `[영]` 소득세법 시행령 §88① · §92②4 (백서 6.1 · 4.4 예시 B)
final class ResidentCostPoolTests: XCTestCase {

    /// 백서 4.4 예시 B 를 그대로 옮긴 것
    func testWhitepaperExampleB() {
        let pool = ResidentCostPool()
        // 기초(2027-01-01) BTC 1개, 의제취득가액 1억
        pool.setOpening(asset: "BTC", year: 2027, qty: 1, costKRW: 100_000_000)
        pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 120_000_000)
        pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 80_000_000)
        pool.dispose(asset: "BTC", year: 2027, qty: 2)
        pool.settle(years: [2027])

        // (100,000,000 + 120,000,000 + 80,000,000) ÷ 3 = 100,000,000
        XCTAssertEqual(pool.unitCost(asset: "BTC", year: 2027), 100_000_000)
        // 2개 처분의 필요경비 = 2억
        XCTAssertEqual(pool.costOfDisposal(asset: "BTC", year: 2027, qty: 2), 200_000_000)
        // 기말 1개 · 1억
        XCTAssertEqual(pool.closing(asset: "BTC", year: 2027), .init(qty: 1, cost: 100_000_000))
    }

    /// **판 순서는 세액에 영향을 주지 않는다** — 총평균법의 성질 (백서 4.4)
    func testDisposalOrderDoesNotMatter() {
        func income(disposeFirst: Bool) -> Decimal {
            let pool = ResidentCostPool()
            if disposeFirst {
                pool.acquire(asset: "ETH", year: 2027, qty: 2, costKRW: 2_000_000)
                pool.dispose(asset: "ETH", year: 2027, qty: 1)
                pool.acquire(asset: "ETH", year: 2027, qty: 2, costKRW: 6_000_000)
            } else {
                pool.acquire(asset: "ETH", year: 2027, qty: 2, costKRW: 6_000_000)
                pool.dispose(asset: "ETH", year: 2027, qty: 1)
                pool.acquire(asset: "ETH", year: 2027, qty: 2, costKRW: 2_000_000)
            }
            pool.settle(years: [2027])
            return pool.costOfDisposal(asset: "ETH", year: 2027, qty: 1)!
        }
        // (2,000,000 + 6,000,000) ÷ 4 = 2,000,000
        XCTAssertEqual(income(disposeFirst: true), 2_000_000)
        XCTAssertEqual(income(disposeFirst: false), 2_000_000)
    }

    /// **연말에 더 사면 1월에 판 거래의 원가가 바뀐다** — 이동평균·선입선출과 근본적으로 다른 성질
    func testLateYearPurchaseChangesEarlierDisposalCost() {
        func cost(withDecemberBuy: Bool) -> Decimal {
            let pool = ResidentCostPool()
            pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 50_000_000)  // 1월 매수
            pool.dispose(asset: "BTC", year: 2027, qty: 1)                        // 2월 매도
            if withDecemberBuy {
                pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 150_000_000) // 12월 매수
            }
            pool.settle(years: [2027])
            return pool.costOfDisposal(asset: "BTC", year: 2027, qty: 1)!
        }
        XCTAssertEqual(cost(withDecemberBuy: false), 50_000_000)
        // 12월에 1.5억에 한 개 더 사면 단가가 (0.5억+1.5억)÷2 = 1억이 되어
        // **2월에 이미 판 거래의 필요경비가 소급해서 두 배가 된다**
        XCTAssertEqual(cost(withDecemberBuy: true), 100_000_000)
    }

    /// 기말이 다음 해 기초로 넘어간다 (§92②4 「과세기간 종료일 현재의 재고자산의 가액」)
    func testClosingCarriesToNextYearOpening() {
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2027, qty: 4, costKRW: 400_000_000) // 단가 1억
        pool.dispose(asset: "BTC", year: 2027, qty: 1)
        pool.acquire(asset: "BTC", year: 2028, qty: 1, costKRW: 200_000_000)
        pool.dispose(asset: "BTC", year: 2028, qty: 2)
        pool.settle(years: [2027, 2028])

        XCTAssertEqual(pool.unitCost(asset: "BTC", year: 2027), 100_000_000)
        XCTAssertEqual(pool.closing(asset: "BTC", year: 2027), .init(qty: 3, cost: 300_000_000))
        // 2028: 기초 3개·3억 + 당기 1개·2억 = 4개·5억 → 단가 1.25억
        XCTAssertEqual(pool.unitCost(asset: "BTC", year: 2028), 125_000_000)
        XCTAssertEqual(pool.costOfDisposal(asset: "BTC", year: 2028, qty: 2), 250_000_000)
        XCTAssertEqual(pool.closing(asset: "BTC", year: 2028), .init(qty: 2, cost: 250_000_000))
    }

    /// 거래소를 가리지 않고 **한 풀**이다 — 계정별 장부와 갈리는 지점 (§88① "거주자별로")
    func testAccountsAreNotSeparated() {
        let pool = ResidentCostPool()
        // 빗썸에서 1개를 1억에, 바이낸스에서 1개를 3억에 샀다고 하자
        pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 100_000_000)
        pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 300_000_000)
        pool.dispose(asset: "BTC", year: 2027, qty: 1)
        pool.settle(years: [2027])
        // 어느 거래소에서 팔았든 단가는 2억이다
        XCTAssertEqual(pool.costOfDisposal(asset: "BTC", year: 2027, qty: 1), 200_000_000)
    }

    /// 소실 수량의 원가는 회수되지 않는다 (폐기 — 백서 U-10 · Q2 결정)
    func testAbandonedQuantityLosesItsCost() {
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2027, qty: 10, costKRW: 1_000_000_000) // 단가 1억
        pool.abandon(asset: "BTC", year: 2027, qty: 1)   // 전송 수수료로 1개 소실
        pool.dispose(asset: "BTC", year: 2027, qty: 5)
        pool.settle(years: [2027])

        XCTAssertEqual(pool.unitCost(asset: "BTC", year: 2027), 100_000_000, "소실은 단가를 바꾸지 않는다")
        XCTAssertEqual(pool.costOfDisposal(asset: "BTC", year: 2027, qty: 5), 500_000_000)
        // 기말 4개 · 4억. 소실분 1억은 어디에도 남지 않는다 = 폐기
        XCTAssertEqual(pool.closing(asset: "BTC", year: 2027), .init(qty: 4, cost: 400_000_000))
    }

    /// 정산 전에는 원가를 **모른다**고 답해야 한다 — 0 을 돌려주면 전액이 이익이 된다
    func testUnsettledReturnsNilNotZero() {
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 100_000_000)
        pool.dispose(asset: "BTC", year: 2027, qty: 1)
        XCTAssertNil(pool.costOfDisposal(asset: "BTC", year: 2027, qty: 1))
        XCTAssertNil(pool.unitCost(asset: "BTC", year: 2027))
    }

    /// 자료가 빠져 판 수량이 산 수량을 넘으면 기말을 0 으로 막고 기록을 남긴다
    func testShortfallIsClampedAndRecorded() {
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 100_000_000)
        pool.dispose(asset: "BTC", year: 2027, qty: 3)
        pool.settle(years: [2027])

        XCTAssertEqual(pool.closing(asset: "BTC", year: 2027)?.qty, 0)
        XCTAssertEqual(pool.closing(asset: "BTC", year: 2027)?.cost, 0)
        XCTAssertEqual(pool.settleWarnings.count, 1)
        XCTAssertEqual(pool.settleWarnings.first?.shortQty, 2)
    }

    /// 의제취득가 재기동은 그 해 기초를 **덮어쓴다** (`[법]` §37⑤)
    func testForcedOpeningOverridesCarry() {
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2026, qty: 1, costKRW: 50_000_000)
        pool.settle(years: [2026])
        XCTAssertEqual(pool.closing(asset: "BTC", year: 2026), .init(qty: 1, cost: 50_000_000))

        // 2027-01-01 0시 시가가 1억이면 max(1억, 5천만) = 1억으로 재기동
        pool.setOpening(asset: "BTC", year: 2027, qty: 1, costKRW: 100_000_000)
        pool.dispose(asset: "BTC", year: 2027, qty: 1)
        pool.settle(years: [2027])
        XCTAssertEqual(pool.costOfDisposal(asset: "BTC", year: 2027, qty: 1), 100_000_000)
    }

    /// 거래가 없는 해를 건너뛰면 이월이 끊긴다 — 연속으로 넘겨야 한다
    func testGapYearMustBeSettledToCarry() {
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2027, qty: 2, costKRW: 200_000_000)
        pool.dispose(asset: "BTC", year: 2029, qty: 1)
        pool.settle(years: [2027, 2028, 2029])
        XCTAssertEqual(pool.unitCost(asset: "BTC", year: 2029), 100_000_000, "빈 해를 지나도 기초가 이어져야 한다")
        XCTAssertEqual(pool.costOfDisposal(asset: "BTC", year: 2029, qty: 1), 100_000_000)
    }

    /// 자산별로 완전히 분리된다
    func testAssetsAreIndependent() {
        let pool = ResidentCostPool()
        pool.acquire(asset: "BTC", year: 2027, qty: 1, costKRW: 100_000_000)
        pool.acquire(asset: "ETH", year: 2027, qty: 10, costKRW: 50_000_000)
        pool.settle(years: [2027])
        XCTAssertEqual(pool.unitCost(asset: "BTC", year: 2027), 100_000_000)
        XCTAssertEqual(pool.unitCost(asset: "ETH", year: 2027), 5_000_000)
    }
}
