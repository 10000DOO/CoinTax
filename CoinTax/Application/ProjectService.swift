import Foundation
import SwiftData

@MainActor
final class ProjectService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchProjects() throws -> [ProjectEntity] {
        let desc = FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(desc)
    }

    @discardableResult
    func createProject(name: String, defaultTaxYear: Int = 2027) throws -> ProjectEntity {
        let project = ProjectEntity(name: name, defaultTaxYear: defaultTaxYear)
        modelContext.insert(project)

        let defaults: [(ExchangeCode, String, String, String)] = [
            (.bithumb, VenueKind.domestic.rawValue, "빗썸", CostBasisMethod.movingAverage.rawValue),
            (.binance, VenueKind.overseas.rawValue, "바이낸스", CostBasisMethod.fifo.rawValue),
            (.okx, VenueKind.overseas.rawValue, "OKX", CostBasisMethod.fifo.rawValue)
        ]
        for d in defaults {
            let acc = AccountEntity(
                exchangeCode: d.0.rawValue,
                venueKind: d.1,
                displayName: d.2,
                costMethod: d.3
            )
            acc.project = project
            project.accounts.append(acc)
            modelContext.insert(acc)
        }
        try modelContext.save()
        return project
    }

    func ensureDefaultProject() throws -> ProjectEntity {
        let existing = try fetchProjects()
        if let first = existing.first { return first }
        return try createProject(name: "내 프로젝트")
    }

    /// 거래소 계정을 찾고, 없으면 만든다.
    ///
    /// 자동 배정은 계정이 있어야 성립한다. 기본 프로젝트에는 3개가 미리 있지만
    /// 사용자가 지웠거나 예전 프로젝트라면 없을 수 있다 — 그때 조용히 실패하면
    /// 파일이 엉뚱한 계정으로 들어간다.
    @discardableResult
    func ensureAccount(_ code: ExchangeCode, in project: ProjectEntity) throws -> AccountEntity {
        if let existing = project.accounts.first(where: { $0.exchangeCode == code.rawValue }) {
            return existing
        }
        let defaults = Account.defaults(for: code, projectID: ProjectID(project.id))
        let acc = AccountEntity(
            exchangeCode: defaults.exchangeCode.rawValue,
            venueKind: defaults.venueKind.rawValue,
            displayName: defaults.displayName,
            costMethod: defaults.costMethod.rawValue
        )
        acc.project = project
        project.accounts.append(acc)
        modelContext.insert(acc)
        try modelContext.save()
        return acc
    }

    func domainAccounts(for project: ProjectEntity) -> [Account] {
        let pid = ProjectID(project.id)
        return project.accounts.map { EntityMappers.account($0, projectID: pid) }
    }

    func domainEvents(for project: ProjectEntity) -> [LedgerEvent] {
        let pid = ProjectID(project.id)
        return project.events.map { EntityMappers.event($0, projectID: pid) }
    }

    func domainLinks(for project: ProjectEntity) -> [TransferLink] {
        let pid = ProjectID(project.id)
        return project.links.map { EntityMappers.link($0, projectID: pid) }
    }
}
