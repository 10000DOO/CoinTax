import Foundation
import SwiftData

@MainActor
final class FXService {
    private let modelContext: ModelContext
    private var cache: [String: Decimal] = [:]
    /// 기본 true — 자동 조회. 끄면 수동만.
    var autoFetchEnabled: Bool {
        get { FXPreferences.autoFetchEnabled }
        set { FXPreferences.autoFetchEnabled = newValue }
    }
    var remoteClient: any FXClient = CompositeFXClient()

    init(modelContext: ModelContext, remoteClient: (any FXClient)? = nil) {
        self.modelContext = modelContext
        if let remoteClient {
            self.remoteClient = remoteClient
        }
    }

    func loadCache(from project: ProjectEntity) {
        cache = [:]
        for r in project.fxRates where r.pair == "USD/KRW" {
            if let d = Decimal(string: r.rate) {
                cache[r.day] = d
            }
        }
    }

    func ratesMap(for project: ProjectEntity) -> [String: Decimal] {
        loadCache(from: project)
        return cache
    }

    func setRate(
        day: String,
        rate: Decimal,
        project: ProjectEntity,
        source: String = "manual",
        sourceDate: String? = nil
    ) throws {
        // 수동 입력이 있으면 이후 자동이 덮어쓰지 않도록 기존 manual 유지 옵션은 fill 쪽에서 처리
        let resolvedSourceDate = sourceDate ?? day
        if let existing = project.fxRates.first(where: { $0.day == day && $0.pair == "USD/KRW" }) {
            existing.rate = Money.decimalString(rate)
            existing.source = source
            existing.sourceDate = resolvedSourceDate
        } else {
            let e = FXRateEntity(
                day: day,
                rate: Money.decimalString(rate),
                source: source,
                sourceDate: resolvedSourceDate
            )
            e.project = project
            project.fxRates.append(e)
            modelContext.insert(e)
        }
        cache[day] = rate
        try modelContext.save()
    }

    /// 이벤트일에 고시가 없을 때 직전 고시율을 해석 (저장 없이 조회).
    func resolveRate(eventDay: String, project: ProjectEntity) -> FXResolvedRate? {
        let published = ratesMap(for: project)
        return FXHolidayPolicy.resolve(eventDay: eventDay, published: published)
    }

    /// 환율이 실제로 필요한 날짜 목록.
    ///
    /// - 과세 집계 대상이 아닌 처분(2027-01-01 이전)은 양도가액이 필요 없으므로 제외한다(리뷰 1-8).
    /// - 당일 고시가 없어도 **직전 고시일로 대체 가능하면 누락이 아니다** (`FXHolidayPolicy`).
    ///   대체 사실은 엔진이 계산 시 기록하므로, 여기서 합성 값을 미리 써 넣지 않는다(리뷰 1-4).
    func missingDays(for events: [LedgerEvent], project: ProjectEntity) -> [String] {
        let published = ratesMap(for: project)
        let tTax = TaxTime.taxStartDate
        var days = Set<String>()
        func needDay(_ e: LedgerEvent) {
            let day = TaxTime.dayKST(e.timestamp)
            if FXHolidayPolicy.resolve(eventDay: day, published: published) == nil {
                days.insert(day)
            }
        }

        for e in events where e.type != .ignored {
            // 과세 대상이 아닌 원화 마켓 처분은 양도가액을 계산하지 않으므로 환율이 필요 없다.
            // 다만 **코인↔코인 처분**은 받은 견적자산(USDT 등)의 취득원가가 그 시점 원화가액이므로,
            // 과세 시작 전 거래에도 환율이 필요하다 — 없으면 원가 0으로 시작해 세액이 부풀려진다.
            let needsAmount: Bool
            switch e.type {
            case .buy: needsAmount = e.quoteAmountKRW == nil
            case .sell: needsAmount = e.quoteAmountKRW == nil && (e.timestamp >= tTax || e.cryptoQuoteQuantity != nil)
            default: needsAmount = false
            }
            if needsAmount, (e.quoteAsset == nil) || (e.quoteAsset?.isUSDTish == true) {
                needDay(e)
            }

            // 수수료가 USD 연동 자산이면 그 환산에도 환율이 필요하다.
            // 원화 금액이 이미 있는 매수라도 수수료가 USDT 면 환율을 써야 하므로,
            // 위 조건만 보면 엔진이 요구하는 날짜를 놓친다.
            let feeNeedsFX: Bool
            switch e.type {
            case .buy: feeNeedsFX = true
            case .sell: feeNeedsFX = e.timestamp >= tTax
            default: feeNeedsFX = false
            }
            if feeNeedsFX,
               let fee = e.feeAmount, fee != 0,
               let fa = e.feeAsset, fa.isUSDTish, fa != e.baseAsset {
                needDay(e)
            }
        }
        return days.sorted()
    }

    /// 자동 조회(기본). 수동 저장분은 덮어쓰지 않음.
    @discardableResult
    func fillMissingFromRemote(days: [String], project: ProjectEntity, force: Bool = false) async throws -> [String: Decimal] {
        if !autoFetchEnabled && !force { return [:] }
        let target = days.filter { day in
            guard let existing = project.fxRates.first(where: { $0.day == day && $0.pair == "USD/KRW" }) else {
                return true
            }
            // manual 은 보존
            return existing.source != "manual"
        }
        guard !target.isEmpty else { return [:] }

        let fetched = try await remoteClient.fetchUSD_KRW(days: target)
        let sourceLabel: String = {
            if remoteClient is CompositeFXClient {
                return FXKeychain.loadECOSKey() != nil ? "remote-ecos-or-public" : "remote-public"
            }
            if remoteClient is ECOSFXClient { return "remote-ecos" }
            if remoteClient is PublicUSDKRWClient { return "remote-public" }
            return "remote"
        }()
        for (day, rate) in fetched {
            try setRate(day: day, rate: rate, project: project, source: sourceLabel)
        }
        return fetched
    }

    /// 계산 직전: 누락일 자동 채움. 남은 누락일 목록을 돌려준다.
    ///
    /// 휴일·미고시일에 대해 **합성 행을 저장하지 않는다.** 저장하면 그 날 고시가 있었던 것처럼 보여
    /// 감사 추적이 끊긴다(리뷰 1-4). 대체는 계산 시점에 `FXHolidayPolicy`가 수행하고
    /// 실제 고시일을 `ReplayResult.fxResolutions`에 남긴다.
    @discardableResult
    func ensureRatesForCalculation(events: [LedgerEvent], project: ProjectEntity) async throws -> [String] {
        let missing = missingDays(for: events, project: project)
        guard !missing.isEmpty, autoFetchEnabled else { return missing }
        // 미고시일 대체 후보를 확보하기 위해 앞쪽 며칠을 함께 요청
        let expanded = expandLookback(days: missing, back: FXHolidayPolicy.maxLookbackDays)
        _ = try await fillMissingFromRemote(days: expanded, project: project)
        return missingDays(for: events, project: project)
    }

    /// 환율 CSV: day,rate 또는 date,USD/KRW,rate 또는 date,currency,rate
    func importRatesCSV(text: String, project: ProjectEntity) throws -> Int {
        let rows = CSVUtil.parseLines(text)
        guard let header = rows.first else { return 0 }
        let lower = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func idx(_ names: [String]) -> Int? {
            for n in names {
                if let i = lower.firstIndex(of: n) { return i }
            }
            return nil
        }
        let dayI = idx(["day", "date", "날짜", "yyyy-mm-dd"]) ?? 0
        let rateI = idx(["rate", "환율", "usd/krw", "value"]) ?? (header.count > 1 ? header.count - 1 : 1)
        var n = 0
        for row in rows.dropFirst() {
            guard dayI < row.count, rateI < row.count else { continue }
            let day = row[dayI].trimmingCharacters(in: .whitespaces)
            guard day.count >= 8, let rate = Money.parseDecimal(row[rateI]), rate > 0 else { continue }
            try setRate(day: day, rate: rate, project: project, source: "csv", sourceDate: day)
            n += 1
        }
        return n
    }

    private func expandLookback(days: [String], back: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TaxTime.seoul
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TaxTime.seoul
        f.dateFormat = "yyyy-MM-dd"
        var set = Set(days)
        for day in days {
            guard var d = f.date(from: day) else { continue }
            for _ in 0..<back {
                d = cal.date(byAdding: .day, value: -1, to: d) ?? d
                set.insert(f.string(from: d))
            }
        }
        return set.sorted()
    }
}
