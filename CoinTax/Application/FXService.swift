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

    func setRate(day: String, rate: Decimal, project: ProjectEntity, source: String = "manual") throws {
        // 수동 입력이 있으면 이후 자동이 덮어쓰지 않도록 기존 manual 유지 옵션은 fill 쪽에서 처리
        if let existing = project.fxRates.first(where: { $0.day == day && $0.pair == "USD/KRW" }) {
            existing.rate = Money.decimalString(rate)
            existing.source = source
        } else {
            let e = FXRateEntity(day: day, rate: Money.decimalString(rate), source: source)
            e.project = project
            project.fxRates.append(e)
            modelContext.insert(e)
        }
        cache[day] = rate
        try modelContext.save()
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

    /// 계산 직전: 누락일 자동 채움.
    @discardableResult
    func ensureRatesForCalculation(events: [LedgerEvent], project: ProjectEntity) async throws -> [String] {
        let missing = missingDays(for: events, project: project)
        guard !missing.isEmpty else { return [] }
        if autoFetchEnabled {
            _ = try await fillMissingFromRemote(days: missing, project: project)
        }
        return missingDays(for: events, project: project)
    }
}
