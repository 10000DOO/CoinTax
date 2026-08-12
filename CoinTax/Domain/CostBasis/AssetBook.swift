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
        let unit = totalCost / quantity
        let cost = unit * take
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
    private struct Lot {
        var qty: Decimal
        var unitCost: Decimal
    }
    private var lots: [Lot] = []

    var quantity: Decimal { lots.reduce(0) { $0 + $1.qty } }
    var totalCost: Decimal { lots.reduce(0) { $0 + $1.qty * $1.unitCost } }
    var openLots: [(qty: Decimal, unitCost: Decimal)] { lots.map { ($0.qty, $0.unitCost) } }

    func acquire(qty: Decimal, costKRW: Decimal) {
        guard qty > 0 else { return }
        let unit = costKRW / qty
        lots.append(Lot(qty: qty, unitCost: unit))
    }

    func disposeClamped(qty: Decimal) -> DisposeOutcome {
        guard qty > 0 else { return DisposeOutcome(costKRW: 0, shortfallQty: 0) }
        var remain = qty
        var cost: Decimal = 0
        while remain > Money.qtyEpsilon, !lots.isEmpty {
            let take = min(lots[0].qty, remain)
            cost += take * lots[0].unitCost
            lots[0].qty -= take
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
            cost += take * lots[0].unitCost
            lots[0].qty -= take
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
        lots = newLots.filter { $0.qty > 0 }.map { Lot(qty: $0.qty, unitCost: $0.unitCost) }
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
