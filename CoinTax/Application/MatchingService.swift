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
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let events = ProjectService(modelContext: modelContext).domainEvents(for: project)
        let links = ProjectService(modelContext: modelContext).domainLinks(for: project)
        let engine = TransferMatchingEngine(accountsByID: byID)
        return engine.suggest(events: events, existing: links)
    }

    func confirm(candidate: TransferMatchCandidate, project: ProjectEntity) throws {
        // 같은 출금·입금이 이미 확정에 쓰였으면 거부한다 (원가 이중 이전 방지 — 리뷰 1-6)
        let confirmed = project.links.filter { $0.status == LinkStatus.confirmed.rawValue }
        if confirmed.contains(where: { $0.fromEventID == candidate.fromEventID.raw }) {
            throw CoinTaxError.parserReject("이 출금은 이미 다른 입금에 연결되어 있습니다")
        }
        if confirmed.contains(where: { $0.toEventID == candidate.toEventID.raw }) {
            throw CoinTaxError.parserReject("이 입금은 이미 다른 출금에 연결되어 있습니다")
        }
        // 같은 쌍을 거부해 둔 기록이 있으면 확정으로 승격
        if let rejected = project.links.first(where: {
            $0.fromEventID == candidate.fromEventID.raw
                && $0.toEventID == candidate.toEventID.raw
                && $0.status == LinkStatus.rejected.rawValue
        }) {
            rejected.status = LinkStatus.confirmed.rawValue
            try modelContext.save()
            return
        }
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

    /// F-MT-02 수동 매칭 — 자동 후보가 못 잡은 전송을 사용자가 직접 연결한다.
    func linkManually(withdrawal: LedgerEventEntity, deposit: LedgerEventEntity, project: ProjectEntity) throws {
        guard withdrawal.type == EventType.withdrawal.rawValue else {
            throw CoinTaxError.parserReject("출금 거래를 선택하세요")
        }
        guard deposit.type == EventType.deposit.rawValue else {
            throw CoinTaxError.parserReject("입금 거래를 선택하세요")
        }
        guard withdrawal.baseAsset.uppercased() == deposit.baseAsset.uppercased() else {
            throw CoinTaxError.parserReject("자산이 다릅니다 (\(withdrawal.baseAsset) ↔ \(deposit.baseAsset))")
        }
        guard withdrawal.accountID != deposit.accountID else {
            throw CoinTaxError.parserReject("같은 계정 안의 이동은 전송 매칭 대상이 아닙니다")
        }
        let wQty = Money.abs(Decimal(string: withdrawal.quantity) ?? 0)
        let dQty = Money.abs(Decimal(string: deposit.quantity) ?? 0)
        guard wQty > 0, dQty > 0 else {
            throw CoinTaxError.parserReject("수량이 0인 거래는 연결할 수 없습니다")
        }
        guard dQty <= wQty * Decimal(string: "1.0001")! else {
            throw CoinTaxError.parserReject("입금 수량이 출금 수량보다 큽니다")
        }
        let candidate = TransferMatchCandidate(
            fromEventID: EventID(withdrawal.id),
            toEventID: EventID(deposit.id),
            withdrawnQty: wQty,
            receivedQty: dQty,
            score: 1.0,
            note: "수동 연결"
        )
        try confirm(candidate: candidate, project: project)
    }

    /// F-MT-02 매칭 해제
    func unlink(_ link: TransferLinkEntity, project: ProjectEntity) throws {
        project.links.removeAll { $0 === link }
        modelContext.delete(link)
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
