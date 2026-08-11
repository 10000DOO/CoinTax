import Foundation

/// 거래일(KST)에 적용할 USD/KRW 환율 해석 결과.
struct FXResolvedRate: Equatable, Sendable {
    /// 이벤트 달력일 (KST yyyy-MM-dd)
    var eventDay: String
    /// 적용 환율
    var rate: Decimal
    /// 실제 고시·인용일 (휴일 대체 시 직전 고시일)
    var sourceDate: String
    /// 당일 고시가 없어 직전 고시일을 썼는지
    var usedPreviousPublished: Bool
    /// 저장 소스 태그 힌트
    var sourceTag: String
}

/// 휴일·주말 등 **기준환율 미고시일** 적용 정책 (잠금).
///
/// ## 근거 (공개 세무 해석)
/// - 국세청 질의회신 **서삼46015-11986 (2002.11.19)**  
///   「공급시기가 … **공휴일인 경우에는 그 전날의 기준환율 또는 재정환율**에 의하여 계산」
/// - 가상자산 USDT 등 외화연동 기축: 소득세법 시행령·국세청 안내상  
///   「외국환거래법에 따른 **기준환율 또는 재정환율**」로 환산  
///   → 전용 휴일 조항이 없으면 **일반 외화 환산의 휴일 취급**을 준용.
/// - 주 5일제 이후 토·일도 통상 미고시 → **당일 고시값이 없으면 직전 고시일**로 통일.
///
/// ## 잠금 규칙
/// 1. 이벤트일 `D`(KST)에 고시 rate가 있으면 → rate(D), sourceDate=D  
/// 2. 없으면 → D보다 **이전** 달력일 중 가장 최근 고시일 `P`의 rate,  
///    sourceDate=P, usedPreviousPublished=true, sourceTag=`previousBusinessDay`  
/// 3. lookback 내 고시 전무 → 해석 실패 (수동 입력/조회 필요)
///
/// 법인통칙 일부의 「공휴일이면 다음날」 기장 규칙은 **부가·소득 환산 질의회신과 불일치**하여 채택하지 않음.
enum FXHolidayPolicy {
    static let id = "previous_published_rate_v1"
    /// 설·추석 연휴 등을 커버
    static let maxLookbackDays = 14

    /// `published`: 실제 고시·캐시된 일자 → 환율 (미고시일은 키 없음)
    static func resolve(eventDay: String, published: [String: Decimal]) -> FXResolvedRate? {
        if let r = published[eventDay] {
            return FXResolvedRate(
                eventDay: eventDay,
                rate: r,
                sourceDate: eventDay,
                usedPreviousPublished: false,
                sourceTag: "sameDay"
            )
        }
        guard let start = parseDay(eventDay) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TaxTime.seoul
        var d = start
        for _ in 0..<maxLookbackDays {
            guard let prev = cal.date(byAdding: .day, value: -1, to: d) else { break }
            d = prev
            let key = formatDay(d)
            if let r = published[key] {
                return FXResolvedRate(
                    eventDay: eventDay,
                    rate: r,
                    sourceDate: key,
                    usedPreviousPublished: true,
                    sourceTag: "previousBusinessDay"
                )
            }
        }
        return nil
    }

    /// 여러 이벤트일에 대해 일괄 해석.
    static func resolveAll(eventDays: [String], published: [String: Decimal]) -> [String: FXResolvedRate] {
        var out: [String: FXResolvedRate] = [:]
        for day in Set(eventDays) {
            if let r = resolve(eventDay: day, published: published) {
                out[day] = r
            }
        }
        return out
    }

    private static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TaxTime.seoul
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private static func formatDay(_ d: Date) -> String {
        TaxTime.dayKST(d)
    }
}
