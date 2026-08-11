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

    func missingDays(for events: [LedgerEvent], project: ProjectEntity) -> [String] {
        let rates = ratesMap(for: project)
        var days = Set<String>()
        for e in events {
            let needs = e.quoteAmountKRW == nil && (e.type == .buy || e.type == .sell)
            if needs && (e.quoteAsset?.isUSDTish == true || e.quoteAsset == nil) {
                let day = TaxTime.dayKST(e.timestamp)
                if rates[day] == nil {
                    days.insert(day)
                }
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

    /// 계산 직전: 누락일 자동 채움 + 휴일 미고시는 직전 고시로 해석 가능하면 합성 저장.
    @discardableResult
    func ensureRatesForCalculation(events: [LedgerEvent], project: ProjectEntity) async throws -> [String] {
        var missing = missingDays(for: events, project: project)
        if !missing.isEmpty, autoFetchEnabled {
            // 원격 조회 시 시작 전 버퍼를 위해 인접 영업일도 요청
            let expanded = expandLookback(days: missing, back: FXHolidayPolicy.maxLookbackDays)
            _ = try await fillMissingFromRemote(days: expanded, project: project)
            missing = missingDays(for: events, project: project)
        }
        // 여전히 당일 키가 없어도 직전 고시가 있으면 previousBusinessDay 로 기록
        let published = ratesMap(for: project)
        for day in missing {
            if let resolved = FXHolidayPolicy.resolve(eventDay: day, published: published),
               resolved.usedPreviousPublished {
                try setRate(
                    day: day,
                    rate: resolved.rate,
                    project: project,
                    source: "previousBusinessDay",
                    sourceDate: resolved.sourceDate
                )
            }
        }
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
