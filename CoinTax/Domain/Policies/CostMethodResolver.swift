import Foundation

protocol CostMethodResolver: Sendable {
    var id: String { get }
    func method(for account: Account) -> CostBasisMethod
}

/// `[영]` 소득세법 시행령 §88① — 계정을 가리지 않고 **거주자별 총평균법**.
///
/// 2025-02-28 개정으로 「가상자산주소별 이동평균법/선입선출법」이 폐지되고 이것으로 바뀌었다
/// (백서 6.1·6.2). 계정마다 방법이 갈리지 않으므로 계정을 보지 않는다.
struct TotalAverageResolver: CostMethodResolver {
    let id = "resident_total_average"

    func method(for account: Account) -> CostBasisMethod { .totalAverage }
}

/// 폐지된 옛 규정. 과거 스냅샷 재현·비교용으로만 남긴다.
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
