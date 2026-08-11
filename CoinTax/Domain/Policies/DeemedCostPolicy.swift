import Foundation

protocol DeemedCostPolicy: Sendable {
    var id: String { get }
    func deemedUnit(bookUnit: Decimal, marketUnit: Decimal?) -> Decimal?
}

struct MaxBookMarketDeemedPolicy: DeemedCostPolicy {
    let id = "max_book_market_2026-12-31"

    func deemedUnit(bookUnit: Decimal, marketUnit: Decimal?) -> Decimal? {
        guard let market = marketUnit else { return nil }
        return max(bookUnit, market)
    }
}
