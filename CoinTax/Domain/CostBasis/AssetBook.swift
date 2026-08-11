import Foundation

protocol AssetBook: AnyObject {
    var quantity: Decimal { get }
    var totalCost: Decimal { get }
    var method: CostBasisMethod { get }
    func acquire(qty: Decimal, costKRW: Decimal)
    /// Returns cost disposed
    func dispose(qty: Decimal) throws -> Decimal
    func reset()
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

    func acquire(qty: Decimal, costKRW: Decimal) {
        quantity += qty
        totalCost += costKRW
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

    func acquire(qty: Decimal, costKRW: Decimal) {
        guard qty > 0 else { return }
        let unit = costKRW / qty
        lots.append(Lot(qty: qty, unitCost: unit))
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
