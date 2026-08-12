import Foundation

/// 화면·export 표시용 숫자 포맷.
///
/// 계산은 `Decimal` 그대로 하고 **표시할 때만** 여기를 거친다.
/// `Money.decimalString` 은 자릿수 구분이 없어(`14302246`) 사람이 읽기 어렵다.
enum Fmt {
    private static let krw: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.maximumFractionDigits = 0
        f.roundingMode = .halfUp
        return f
    }()

    private static let qty: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        return f
    }()

    /// `₩14,302,246` — 원 단위로 반올림한다 (엔진의 반올림 정책과 같은 half-up)
    static func krwString(_ value: Decimal) -> String {
        let rounded = Money.roundKRW(value)
        let n = NSDecimalNumber(decimal: rounded)
        return "₩" + (krw.string(from: n) ?? Money.decimalString(rounded))
    }

    /// 부호를 항상 붙인다 (손익 표시용) — `+₩1,200` / `-₩900`
    static func krwSigned(_ value: Decimal) -> String {
        let rounded = Money.roundKRW(value)
        if rounded == 0 { return "₩0" }
        let sign = rounded > 0 ? "+" : "-"
        return sign + krwString(Money.abs(rounded))
    }

    /// 큰 금액을 한눈에 — `1.4억` / `320만` / `₩12,000`
    static func krwCompact(_ value: Decimal) -> String {
        let v = Money.abs(Money.roundKRW(value))
        let sign = value < 0 ? "-" : ""
        let d = NSDecimalNumber(decimal: v).doubleValue
        if d >= 100_000_000 { return String(format: "%@%.2f억", sign, d / 100_000_000) }
        if d >= 10_000 { return String(format: "%@%.0f만", sign, d / 10_000) }
        return krwString(value)
    }

    /// 코인 수량 — 소수 8자리까지, 뒤의 0은 떼고
    static func qtyString(_ value: Decimal) -> String {
        let n = NSDecimalNumber(decimal: value)
        return qty.string(from: n) ?? Money.decimalString(value)
    }

    /// 단가 — 1원 미만이면 소수를 보여준다 (TRX 같은 저가 코인)
    static func unitPriceString(_ value: Decimal) -> String {
        if value != 0, Money.abs(value) < 1 {
            return "₩" + (qty.string(from: NSDecimalNumber(decimal: value)) ?? "0")
        }
        return krwString(value)
    }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }

    static func dateTime(_ d: Date) -> String {
        d.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
