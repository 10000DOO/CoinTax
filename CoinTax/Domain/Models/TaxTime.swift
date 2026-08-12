import Foundation

enum TaxTime {
    static let seoul: TimeZone = TimeZone(identifier: "Asia/Seoul")!

    static let taxStartYear = 2027

    /// 아직 과세 시작 전인가.
    ///
    /// 2027-01-01 0시 시가는 **그 시점이 지나야 존재한다.** 그전까지 「시가 없음」을 막힘으로
    /// 두면 어떤 사용자도 신고자료를 만들 수 없다 — 그때까지는 경고로만 알린다.
    static func isBeforeTaxStart(_ now: Date = Date()) -> Bool { now < taxStartDate }

    /// 2027-01-01 00:00:00 KST
    static var taxStartDate: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seoul
        return cal.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 0, minute: 0, second: 0))!
    }

    /// timestamp < taxStartDate 이면 2026-12-31 종료(의제 기준) 이전
    static var deemedCutoffExclusive: Date { taxStartDate }

    static func calendarYearKST(_ date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seoul
        return cal.component(.year, from: date)
    }

    /// yyyy-MM-dd in KST
    static func dayKST(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seoul
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func dateUTC(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func dateKST(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seoul
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}
