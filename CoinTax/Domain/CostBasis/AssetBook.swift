import Foundation

/// 처분 결과. `shortfallQty > 0` 이면 보유가 부족해 그만큼 처분하지 못했다는 뜻.
struct DisposeOutcome: Equatable, Sendable {
    var costKRW: Decimal
    var shortfallQty: Decimal
}

protocol AssetBook: AnyObject {
    var quantity: Decimal { get }
    var totalCost: Decimal { get }
    var method: CostBasisMethod { get }
    /// FIFO 계정의 열린 lot 목록 (검증 V-COST-05용). 이동평균은 빈 배열.
    var openLots: [(qty: Decimal, unitCost: Decimal)] { get }
    func acquire(qty: Decimal, costKRW: Decimal)
    /// Returns cost disposed
    func dispose(qty: Decimal) throws -> Decimal
    /// 보유가 부족해도 던지지 않고 가능한 만큼만 처분한다.
    /// 세금 계산은 예외로 중단하지 않고 Critical 이슈로 보고해야 하므로(06-integrity fail-closed) 이 경로를 쓴다.
    func disposeClamped(qty: Decimal) -> DisposeOutcome
    func reset()
    /// 장부를 주어진 lot 구성으로 바꾼다 (의제취득가 재기동).
    /// 이동평균 장부는 lot 개념이 없으므로 합산해서 반영한다.
    func replaceLots(_ lots: [(qty: Decimal, unitCost: Decimal)])
    func snapshotUnitCost() -> Decimal
}

enum BookError: Error, LocalizedError {
    case negativeLot(requested: Decimal, available: Decimal)
    case invalidQty

    var errorDescription: String? {
        switch self {
        case .negativeLot(let r, let a):
            return "보유 수량보다 많은 처분 (요청 \(r), 보유 \(a))"
        case .invalidQty:
            return "수량이 유효하지 않습니다"
        }
    }
}

final class MovingAverageBook: AssetBook {
    let method: CostBasisMethod = .movingAverage
    private(set) var quantity: Decimal = 0
    private(set) var totalCost: Decimal = 0

    var openLots: [(qty: Decimal, unitCost: Decimal)] { [] }

    func acquire(qty: Decimal, costKRW: Decimal) {
        quantity += qty
        totalCost += costKRW
    }

    func disposeClamped(qty: Decimal) -> DisposeOutcome {
        guard qty > 0 else { return DisposeOutcome(costKRW: 0, shortfallQty: 0) }
        guard quantity > Money.qtyEpsilon else {
            return DisposeOutcome(costKRW: 0, shortfallQty: qty)
        }
        let take = min(qty, quantity)
        // 전량 처분이면 **잔여 원가를 그대로** 쓴다.
        //
        // 단가(총원가÷수량)를 구해 되곱하면 18자리 수량(wei 단위 ETH 등)에서 나눗셈이
        // 무한소수가 되어 정확히 돌아오지 않는다. 전량인데 원가가 1원이라도 남으면 세금이 틀린다.
        // 부분 처분은 곱셈을 먼저 해 오차를 줄인다 (총원가×take÷수량).
        let cost: Decimal = take == quantity ? totalCost : totalCost * take / quantity
        quantity -= take
        totalCost -= cost
        if Money.isApproxZero(quantity) {
            quantity = 0
            totalCost = 0
        }
        let short = qty - take
        return DisposeOutcome(costKRW: cost, shortfallQty: Money.isApproxZero(short) ? 0 : short)
    }

    func dispose(qty: Decimal) throws -> Decimal {
        guard qty > 0 else { throw BookError.invalidQty }
        if qty > quantity + Money.qtyEpsilon {
            throw BookError.negativeLot(requested: qty, available: quantity)
        }
        if Money.isApproxZero(quantity) {
            throw BookError.negativeLot(requested: qty, available: quantity)
        }
        let unit = totalCost / quantity
        let cost = unit * qty
        quantity -= qty
        totalCost -= cost
        if Money.isApproxZero(quantity) {
            quantity = 0
            totalCost = 0
        }
        return cost
    }

    func reset() {
        quantity = 0
        totalCost = 0
    }

    func replaceLots(_ lots: [(qty: Decimal, unitCost: Decimal)]) {
        quantity = lots.reduce(0) { $0 + $1.qty }
        totalCost = lots.reduce(0) { $0 + $1.qty * $1.unitCost }
    }

    func snapshotUnitCost() -> Decimal {
        Money.isApproxZero(quantity) ? 0 : totalCost / quantity
    }
}

final class FIFOBook: AssetBook {
    let method: CostBasisMethod = .fifo
    /// lot 은 **단가가 아니라 남은 원가**를 들고 있는다.
    ///
    /// 단가로 들고 있으면 취득 때 한 번 나누고 처분 때 되곱하면서, 18자리 수량에서
    /// 원가가 정확히 돌아오지 않는다 (전량 처분인데 잔액이 남는다).
    /// 원가를 그대로 보관하면 전량 처분에 나눗셈이 아예 없다.
    private struct Lot {
        var qty: Decimal
        var cost: Decimal
        var unitCost: Decimal { qty == 0 ? 0 : cost / qty }
    }
    private var lots: [Lot] = []

    var quantity: Decimal { lots.reduce(0) { $0 + $1.qty } }
    var totalCost: Decimal { lots.reduce(0) { $0 + $1.cost } }
    var openLots: [(qty: Decimal, unitCost: Decimal)] { lots.map { ($0.qty, $0.unitCost) } }

    func acquire(qty: Decimal, costKRW: Decimal) {
        guard qty > 0 else { return }
        lots.append(Lot(qty: qty, cost: costKRW))
    }

    /// lot 에서 `take` 만큼 덜어낸 원가. lot 을 비우면 남은 원가를 통째로 준다 (나눗셈 없음).
    private func takeCost(from index: Int, take: Decimal) -> Decimal {
        let lot = lots[index]
        if take >= lot.qty { return lot.cost }
        return lot.cost * take / lot.qty
    }

    func disposeClamped(qty: Decimal) -> DisposeOutcome {
        guard qty > 0 else { return DisposeOutcome(costKRW: 0, shortfallQty: 0) }
        var remain = qty
        var cost: Decimal = 0
        while remain > Money.qtyEpsilon, !lots.isEmpty {
            let take = min(lots[0].qty, remain)
            let taken = takeCost(from: 0, take: take)
            cost += taken
            lots[0].qty -= take
            lots[0].cost -= taken
            remain -= take
            if Money.isApproxZero(lots[0].qty) {
                lots.removeFirst()
            }
        }
        return DisposeOutcome(costKRW: cost, shortfallQty: Money.isApproxZero(remain) ? 0 : remain)
    }

    func dispose(qty: Decimal) throws -> Decimal {
        guard qty > 0 else { throw BookError.invalidQty }
        if qty > quantity + Money.qtyEpsilon {
            throw BookError.negativeLot(requested: qty, available: quantity)
        }
        var remain = qty
        var cost: Decimal = 0
        while remain > Money.qtyEpsilon {
            guard !lots.isEmpty else {
                throw BookError.negativeLot(requested: qty, available: quantity)
            }
            let take = min(lots[0].qty, remain)
            let taken = takeCost(from: 0, take: take)
            cost += taken
            lots[0].qty -= take
            lots[0].cost -= taken
            remain -= take
            if Money.isApproxZero(lots[0].qty) {
                lots.removeFirst()
            }
        }
        return cost
    }

    func reset() {
        lots.removeAll()
    }

    func replaceLots(_ newLots: [(qty: Decimal, unitCost: Decimal)]) {
        lots = newLots.filter { $0.qty > 0 }.map { Lot(qty: $0.qty, cost: $0.qty * $0.unitCost) }
    }

    func snapshotUnitCost() -> Decimal {
        let q = quantity
        return Money.isApproxZero(q) ? 0 : totalCost / q
    }
}

enum AssetBookFactory {
    static func make(_ method: CostBasisMethod) -> AssetBook {
        switch method {
        case .movingAverage: return MovingAverageBook()
        case .fifo: return FIFOBook()
        }
    }
}
