import Foundation

protocol FXAssumptionPolicy: Sendable {
    var id: String { get }
    /// USDT treated as 1 USD
    var usdtEqualsUSD: Bool { get }
}

struct USDTEqualsUSDAssumption: FXAssumptionPolicy {
    let id = "usdt_eq_usd"
    let usdtEqualsUSD = true
}
