import Foundation

protocol RoundingPolicy: Sendable {
    var id: String { get }
    func roundKRW(_ value: Decimal) -> Decimal
}

struct PlainKRWRoundingPolicy: RoundingPolicy {
    let id = "plain_krw_1"
    func roundKRW(_ value: Decimal) -> Decimal {
        Money.roundKRW(value)
    }
}
