import Foundation
import SwiftData

@MainActor
final class FXService {
    private let modelContext: ModelContext
    private var cache: [String: Decimal] = [:]
    /// 기본 false — 오프라인. 설정에서 옵트인.
    var remoteOptIn: Bool = false
    var remoteClient: any FXClient = RemoteFXClientStub()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
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

    /// 옵트인 원격 조회 후 로컬 캐시에 저장. 스텁은 빈 결과 → 수동 입력 유지.
    @discardableResult
    func fillMissingFromRemote(days: [String], project: ProjectEntity) async throws -> [String: Decimal] {
        guard remoteOptIn else { return [:] }
        let fetched = try await remoteClient.fetchUSD_KRW(days: days)
        for (day, rate) in fetched {
            try setRate(day: day, rate: rate, project: project, source: "remote")
        }
        return fetched
    }
}
