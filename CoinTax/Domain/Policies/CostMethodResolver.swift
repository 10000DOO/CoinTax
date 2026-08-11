import Foundation

protocol CostMethodResolver: Sendable {
    var id: String { get }
    func method(for account: Account) -> CostBasisMethod
}

struct VASPMAElseFIFOResolver: CostMethodResolver {
    let id = "vasp_ma_else_fifo"

    func method(for account: Account) -> CostBasisMethod {
        switch account.exchangeCode {
        case .bithumb: return .movingAverage
        case .binance, .okx, .generic: return .fifo
        }
    }
}
