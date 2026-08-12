import Foundation

enum Money {
    static let qtyEpsilon = Decimal(string: "0.0000000001")!

    /// 거래소 반올림에서 생기는 **먼지 수량**의 절대 상한.
    ///
    /// 거래소는 수량을 보통 소수 8자리로 끊는다. 내부 이동·부분 체결이 수십 건 이어지면
    /// 마지막 자리에서 1e-8 수준의 차이가 남는다. 이건 이력 누락이 아니라 반올림이다.
    /// 이 차이를 「보유보다 많은 처분」 Critical 로 올리면 정상 데이터에서 export 가 잠긴다.
    static let dustQtyEpsilon = Decimal(string: "0.00000001")!

    /// `shortfall` 이 `requested` 대비 반올림 오차 수준인가.
    ///
    /// 절대 기준(1e-8)과 상대 기준(요청 수량의 100만분의 1) 중 큰 쪽을 쓴다.
    /// 자산마다 가격 단위가 크게 달라 절대 기준만으로는 판단할 수 없다.
    static func isDustShortfall(_ shortfall: Decimal, of requested: Decimal) -> Bool {
        guard shortfall > 0 else { return true }
        let relative = abs(requested) * Decimal(string: "0.000001")!
        return shortfall <= max(dustQtyEpsilon, relative)
    }

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
        NSDecimalNumber(decimal: d).stringValue
    }
}

extension Decimal {
    var moneyString: String { Money.decimalString(self) }
}
