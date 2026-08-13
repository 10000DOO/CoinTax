import Foundation

/// 거주자별 총평균법 원가 풀 — `[영]` 소득세법 시행령 §88① · §92②4.
///
/// > §88① 가상자산을 양도함으로써 발생하는 소득에 대한 기타소득금액을 산출하는 경우에는
/// > **거주자별로 제92조제2항제4호의 총평균법**을 적용하여 계산한다.
///
/// 계정별 장부(`AssetBook`)와 두 가지가 다르다.
///
/// 1. **계산 단위가 사람 하나다.** 거래소·지갑을 가리지 않고 같은 종류 코인을 한 풀로 묶는다.
///    그래서 계정 하나가 빠지면 그 계정만이 아니라 **전체 단가가 틀어진다**.
/// 2. **단가가 과세기간이 끝나야 정해진다.** §92②4 는 「기초 재고 취득가액 + 당기 취득가액」을
///    「총수량」으로 나눈 평균단가로 **과세기간 종료일 현재의 재고를 평가**하는 방법이다.
///    12월에 한 번 더 사면 1월에 판 거래의 원가까지 바뀐다.
///
/// 그래서 재생 중에는 수량·금액만 모으고(`acquire`/`dispose`/`abandon`),
/// `settle(years:)` 에서 연도별 단가를 확정한 뒤 되돌아가 원가를 채운다.
final class ResidentCostPool {
    /// 한 자산의 한 과세기간 흐름
    struct YearFlow: Equatable {
        var acquiredQty: Decimal = 0
        var acquiredCost: Decimal = 0
        /// 과세 대상 처분 (필요경비로 회수된다)
        var disposedQty: Decimal = 0
        /// 전송 소실·환산불가 등 **원가가 회수되지 않는** 출고.
        /// §92②4 의 기말평가(평균단가 × 기말수량)를 그대로 따르면 이 몫의 원가는
        /// 어디에도 남지 않는다 — 그게 현행 폐기 정책(`abandon_lost_cost`)과 같은 결과다.
        var abandonedQty: Decimal = 0
    }

    struct Position: Equatable {
        var qty: Decimal
        var cost: Decimal
        static let zero = Position(qty: 0, cost: 0)
    }

    /// assetCode → year → flow
    private var flows: [String: [Int: YearFlow]] = [:]
    /// 의제취득가 재기동처럼 **기초를 직접 지정**한 경우 (assetCode → year → 기초)
    private var forcedOpenings: [String: [Int: Position]] = [:]
    /// 코인으로 낸 수수료처럼 **다른 자산의 단가에서 나오는** 취득원가 (assetCode → year → 금액).
    /// BNB 로 BTC 수수료를 내고 BTC 로 BNB 수수료를 내면 두 단가가 서로를 참조한다 —
    /// `settle` 을 몇 번 돌려 수렴시키기 위해 흐름과 분리해 둔다.
    private var derivedAcquisitionCosts: [String: [Int: Decimal]] = [:]
    private(set) var unitCosts: [String: [Int: Decimal]] = [:]
    private(set) var closings: [String: [Int: Position]] = [:]
    /// 가진 것보다 많이 내보낸 해의 **원가 배분 비율**. 없는 원가를 공제할 수는 없다.
    private var outflowScales: [String: [Int: Decimal]] = [:]
    /// 그 해 「기초 + 당기취득」 총량·총원가. 원가를 나눠 줄 때 **나눗셈을 마지막에** 하려고 들고 있는다
    private var yearTotals: [String: [Int: Position]] = [:]
    /// 정산 중 발견한 문제 (수량이 모자라 기말이 음수가 되는 경우 등)
    private(set) var settleWarnings: [(asset: String, year: Int, shortQty: Decimal)] = []

    // MARK: - 재생 중 수집

    func acquire(asset: String, year: Int, qty: Decimal, costKRW: Decimal) {
        guard qty > 0 else { return }
        flows[asset, default: [:]][year, default: YearFlow()].acquiredQty += qty
        flows[asset, default: [:]][year, default: YearFlow()].acquiredCost += costKRW
    }

    func dispose(asset: String, year: Int, qty: Decimal) {
        guard qty > 0 else { return }
        flows[asset, default: [:]][year, default: YearFlow()].disposedQty += qty
    }

    func abandon(asset: String, year: Int, qty: Decimal) {
        guard qty > 0 else { return }
        flows[asset, default: [:]][year, default: YearFlow()].abandonedQty += qty
    }

    /// 의제취득가 재기동 — 그 해 기초를 직접 못박는다 (`[법]` §37⑤).
    func setOpening(asset: String, year: Int, qty: Decimal, costKRW: Decimal) {
        forcedOpenings[asset, default: [:]][year] = Position(qty: qty, cost: costKRW)
    }

    /// 다른 자산의 단가에서 나오는 취득원가를 **덮어쓴다** (누적이 아니다 — 수렴 반복 중 갱신되므로).
    func setDerivedAcquisitionCost(asset: String, year: Int, costKRW: Decimal) {
        derivedAcquisitionCosts[asset, default: [:]][year] = costKRW
    }

    // MARK: - 정산

    /// 이 풀이 다루는 자산 코드 (결정적 순서)
    var assetCodes: [String] {
        Set(flows.keys).union(forcedOpenings.keys).sorted()
    }

    /// 흐름이 기록된 연도 범위. 비어 있으면 nil.
    var yearRange: ClosedRange<Int>? {
        let years = flows.values.flatMap { $0.keys } + forcedOpenings.values.flatMap { $0.keys }
        guard let lo = years.min(), let hi = years.max() else { return nil }
        return lo...hi
    }


    /// `years` 를 **오름차순으로** 정산한다. 앞 해의 기말이 다음 해 기초가 되므로
    /// 중간 연도를 건너뛰면 안 된다 (거래가 없는 해도 포함해서 넘긴다).
    ///
    /// 엔진은 이걸 두 번 부른다 — 의제취득가 재기동 전(2026 까지)과 그 후(2027 부터).
    /// §37⑤ 의 max 비교에 「2026 말 총평균단가」가 필요하기 때문이다.
    /// 같은 연도를 다시 정산해도 안전하다 — 그 해 값을 덮어쓰고, 기초는 매번 직전 해 기말에서
    /// 다시 읽는다. 수수료 원가 수렴 때문에 여러 번 부른다.
    func settle(years: [Int]) {
        let target = Set(years)
        settleWarnings.removeAll { target.contains($0.year) }
        for asset in assetCodes {
            for year in years.sorted() {
                let opening = openingPosition(asset: asset, year: year)
                let flow = flows[asset]?[year] ?? YearFlow()

                let totalQty = opening.qty + flow.acquiredQty
                let totalCost = opening.cost + flow.acquiredCost
                    + (derivedAcquisitionCosts[asset]?[year] ?? 0)
                // §92②4 — 「기초 + 당기취득」의 총액을 총수량으로 나눈 평균단가
                let unit: Decimal = Money.isApproxZero(totalQty) ? 0 : totalCost / totalQty
                unitCosts[asset, default: [:]][year] = unit
                yearTotals[asset, default: [:]][year] = Position(qty: totalQty, cost: totalCost)

                // 나간 수량이 가진 것보다 많으면(자료 누락) **가진 원가만큼만** 배분한다.
                // 자르지 않으면 처분 원가 합이 취득 원가 합을 넘어 원가가 새어 나간다.
                let demand = flow.disposedQty + flow.abandonedQty
                outflowScales[asset, default: [:]][year] =
                    (demand > totalQty && demand > 0) ? totalQty / demand : 1

                var endQty = totalQty - demand
                if endQty < 0 {
                    // 자료가 빠져 판 수량이 산 수량을 넘었다. 계정별 검증(V-QTY-02)이 이미
                    // 잡지만, 풀은 **계정을 합치므로** 한 계정의 누락이 여기서야 드러나기도 한다.
                    settleWarnings.append((asset: asset, year: year, shortQty: -endQty))
                    endQty = 0
                }
                if Money.isApproxZero(endQty) { endQty = 0 }
                // 기말 재고 가액 = 평균단가 × 기말 수량 (§92②4).
                // 전량 소진이면 원가도 0 — 나눗셈 잔재가 남지 않는다.
                closings[asset, default: [:]][year] = Position(qty: endQty, cost: endQty * unit)
            }
        }
    }

    /// 그 해 기초 — 직접 지정된 값이 있으면 그것, 없으면 **직전 해 기말**.
    private func openingPosition(asset: String, year: Int) -> Position {
        if let forced = forcedOpenings[asset]?[year] { return forced }
        return closings[asset]?[year - 1] ?? .zero
    }

    // MARK: - 조회

    /// 그 해 총평균단가. 정산 전이면 nil.
    func unitCost(asset: String, year: Int) -> Decimal? {
        unitCosts[asset]?[year]
    }

    /// 그 해 기말 보유. 정산 전이면 nil.
    func closing(asset: String, year: Int) -> Position? {
        closings[asset]?[year]
    }

    /// 처분 수량에 대응하는 필요경비(취득가액). 정산되지 않았으면 nil —
    /// **0 을 돌려주면 안 된다.** 원가 0 은 전액이 이익이라는 뜻이라 세액이 크게 부풀려진다.
    ///
    /// 단가를 먼저 만들어 되곱하지 않는다. 18자리 수량(wei 단위 ETH 등)에서는
    /// 총원가 ÷ 수량이 무한소수가 되어 되곱해도 원래 값으로 돌아오지 않는다 —
    /// 전량을 팔았는데 소득이 1원 어긋난다. **곱셈을 먼저 하고 나눗셈을 마지막에** 한다.
    func costOfDisposal(asset: String, year: Int, qty: Decimal) -> Decimal? {
        guard unitCost(asset: asset, year: year) != nil else { return nil }
        guard let total = yearTotals[asset]?[year], !Money.isApproxZero(total.qty) else { return 0 }
        let scale = outflowScales[asset]?[year] ?? 1
        // 그 해 가진 것을 통째로 내보내는 처분이면 **나눗셈 없이** 남은 원가를 그대로 준다
        if scale == 1, Money.isApproxZero(qty - total.qty) { return total.cost }
        return total.cost * qty * scale / total.qty
    }

    /// 그 해 소실분의 원가 합계 (회수되지 않는 몫). 정산 전이면 0.
    func abandonedCost(asset: String, year: Int) -> Decimal {
        guard let qty = flows[asset]?[year]?.abandonedQty else { return 0 }
        return costOfDisposal(asset: asset, year: year, qty: qty) ?? 0
    }

    /// 연도별 소실 원가 합계 (모든 자산)
    func abandonedCostByYear() -> [Int: Decimal] {
        // **순서를 고정한다.** 소수 자릿수가 긴 값(단가 × 수량)을 더할 때 순서가 달라지면
        // 마지막 자리가 흔들려 같은 입력에서 다른 세액이 나온다 (검증기 V-RE-01).
        var out: [Int: Decimal] = [:]
        for asset in flows.keys.sorted() {
            guard let byYear = flows[asset] else { continue }
            for year in byYear.keys.sorted() {
                guard let flow = byYear[year], flow.abandonedQty > 0 else { continue }
                out[year, default: 0] += abandonedCost(asset: asset, year: year)
            }
        }
        return out
    }
}
