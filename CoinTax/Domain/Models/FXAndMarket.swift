import Foundation

struct FXRate: Codable, Sendable, Hashable {
    var day: String
    var pair: String
    var rate: Decimal
    var source: String
    var sourceDate: String?
}

struct MarketPrice: Codable, Sendable, Hashable {
    var asOf: String
    var asset: AssetSymbol
    var priceKRW: Decimal
    var source: String
}
