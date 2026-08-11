import Foundation

enum Money {
    static let qtyEpsilon = Decimal(string: "0.0000000001")!

    static func roundKRW(_ value: Decimal) -> Decimal {
        var v = value
        var result = Decimal()
        NSDecimalRound(&result, &v, 0, .plain)
        return result
    }

    static func abs(_ d: Decimal) -> Decimal {
        d < 0 ? -d : d
    }

    static func clamp(_ value: Decimal, _ lo: Decimal, _ hi: Decimal) -> Decimal {
        min(max(value, lo), hi)
    }

    static func isApproxZero(_ d: Decimal, eps: Decimal = qtyEpsilon) -> Bool {
        abs(d) <= eps
    }

    static func parseDecimal(_ s: String) -> Decimal? {
        let cleaned = s
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned)
    }

    static func decimalString(_ d: Decimal) -> String {
        var copy = d
        return NSDecimalNumber(decimal: copy).stringValue
    }
}

extension Decimal {
    var moneyString: String { Money.decimalString(self) }
}
