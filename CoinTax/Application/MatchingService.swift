import Foundation
import SwiftData

@MainActor
final class MatchingService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func suggest(for project: ProjectEntity) -> [TransferMatchCandidate] {
        let accounts = ProjectService(modelContext: modelContext).domainAccounts(for: project)
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let events = ProjectService(modelContext: modelContext).domainEvents(for: project)
        let links = ProjectService(modelContext: modelContext).domainLinks(for: project)
        let engine = TransferMatchingEngine(accountsByID: byID)
        return engine.suggest(events: events, existing: links)
    }

    func confirm(candidate: TransferMatchCandidate, project: ProjectEntity) throws {
        let link = TransferLinkEntity(
            fromEventID: candidate.fromEventID.raw,
            toEventID: candidate.toEventID.raw,
            status: LinkStatus.confirmed.rawValue,
            withdrawnQty: Money.decimalString(candidate.withdrawnQty),
            receivedQty: Money.decimalString(candidate.receivedQty)
        )
        link.score = candidate.score
        link.note = candidate.note
        link.project = project
        project.links.append(link)
        modelContext.insert(link)
        try modelContext.save()
    }

    func reject(candidate: TransferMatchCandidate, project: ProjectEntity) throws {
        let link = TransferLinkEntity(
            fromEventID: candidate.fromEventID.raw,
            toEventID: candidate.toEventID.raw,
            status: LinkStatus.rejected.rawValue,
            withdrawnQty: Money.decimalString(candidate.withdrawnQty),
            receivedQty: Money.decimalString(candidate.receivedQty)
        )
        link.score = candidate.score
        link.project = project
        project.links.append(link)
        modelContext.insert(link)
        try modelContext.save()
    }
}
