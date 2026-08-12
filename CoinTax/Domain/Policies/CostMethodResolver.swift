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
        // 개인지갑은 신고수리 사업자가 아니다 → 선입선출법 (05-decisions §1.2)
        case .binance, .okx, .generic, .wallet: return .fifo
        }
    }
}
