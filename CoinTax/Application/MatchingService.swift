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

    // MARK: - 개인지갑으로 보낸 출금

    /// 개인지갑 입고로 만들어진 이벤트임을 나타내는 표식. 연결 해제 시 함께 지운다.
    static let walletSourceKind = "manual-wallet-v1"

    /// 상대 입금이 없는 출금을 **개인지갑으로 옮긴 것**으로 처리한다.
    ///
    /// 거래소 밖으로 나간 코인은 앱에 도착지가 없어 「미매칭 출금 = 취득원가 소멸」이 된다.
    /// 그러면 그 코인을 나중에 거래소로 다시 들여와 팔 때 **취득가 0원**이 되어 판 금액 전부가
    /// 이익으로 잡히고, 과세 시작 시점(2027-01-01 0시)의 의제취득가도 받지 못한다.
    ///
    /// 여기서는 개인지갑 계정에 **도착 입금 이벤트를 만들고 확정 연결**해서 원가가 따라가게 한다.
    /// 전송 자체는 양도가 아니므로 세금이 지금 생기지는 않는다.
    ///
    /// - Important: **자동으로 하지 않는다.** 상대 없는 출금은 ① 개인지갑 ② 아직 안 넣은 거래소 자료
    ///   ③ 실제 매도·타인 송금(= 양도) 셋 중 하나다. ②·③을 지갑으로 처리하면 각각
    ///   「계정 전체 누락」과 「과소신고」를 숨기게 되므로 사용자가 건별로 판단해야 한다.
    /// - Parameter receivedQty: 지갑에 실제로 도착한 수량. 생략하면 출금 수량 그대로.
    ///   (출금 수량이 네트워크 수수료를 포함한 총액인 거래소는 그만큼 줄여 넣어야 한다)
    @discardableResult
    func moveToWallet(withdrawal: LedgerEventEntity, project: ProjectEntity, receivedQty: Decimal? = nil) throws -> LedgerEventEntity {
        guard withdrawal.type == EventType.withdrawal.rawValue else {
            throw CoinTaxError.parserReject("출금 거래만 개인지갑으로 보낼 수 있습니다")
        }
        guard withdrawal.baseAsset.uppercased() != "KRW" else {
            throw CoinTaxError.parserReject("원화 출금은 가상자산 전송이 아닙니다")
        }
        let already = project.links.contains {
            $0.fromEventID == withdrawal.id && $0.status == LinkStatus.confirmed.rawValue
        }
        guard !already else {
            throw CoinTaxError.parserReject("이미 다른 입금에 연결된 출금입니다")
        }
        let wQty = Money.abs(Decimal(string: withdrawal.quantity) ?? 0)
        guard wQty > 0 else {
            throw CoinTaxError.parserReject("수량이 0인 출금은 처리할 수 없습니다")
        }
        let arrived = receivedQty.map { Money.abs($0) } ?? wQty
        guard arrived > 0, arrived <= wQty else {
            throw CoinTaxError.parserReject("도착 수량은 0보다 크고 출금 수량 이하여야 합니다")
        }

        let ps = ProjectService(modelContext: modelContext)
        let wallet = try ps.ensureAccount(.wallet, in: project)
        guard wallet.id != withdrawal.accountID else {
            throw CoinTaxError.parserReject("개인지갑에서 나간 출금입니다")
        }

        // 도착 시각은 출금과 같은 순간으로 둔다 (온체인 도착 시각을 알 수 없다).
        // 같은 시각이면 원장 정렬이 `rawRef` 로 갈리므로, 출금보다 뒤에 오도록 `wallet:` 접두사를 쓴다.
        var event = LedgerEvent(
            projectID: ProjectID(project.id),
            accountID: AccountID(wallet.id),
            timestamp: withdrawal.timestamp,
            type: .deposit,
            baseAsset: AssetSymbol(withdrawal.baseAsset),
            quantity: arrived,
            network: withdrawal.network,
            addressHash: withdrawal.addressHash,
            txidHash: withdrawal.txidHash,
            memo: "개인지갑 입고 (직접 지정)",
            sourceKind: Self.walletSourceKind,
            rawRef: "wallet:\(withdrawal.id.uuidString)"
        )
        event.fingerprint = Fingerprint.make(for: event, parserID: Self.walletSourceKind)
        let entity = EntityMappers.makeEntity(from: event)
        entity.project = project
        project.events.append(entity)
        modelContext.insert(entity)

        let link = TransferLinkEntity(
            fromEventID: withdrawal.id,
            toEventID: entity.id,
            status: LinkStatus.confirmed.rawValue,
            withdrawnQty: Money.decimalString(wQty),
            receivedQty: Money.decimalString(arrived)
        )
        link.score = 1.0
        link.note = "개인지갑"
        link.project = project
        project.links.append(link)
        modelContext.insert(link)
        try modelContext.save()
        return entity
    }

    /// F-MT-02 매칭 해제
    ///
    /// 개인지갑 입고는 이 연결 때문에 만들어진 이벤트다. 연결만 끊고 이벤트를 남기면
    /// 「출처 없는 입금 = 취득가 0원」이 원장에 그대로 남는다.
    func unlink(_ link: TransferLinkEntity, project: ProjectEntity) throws {
        let toID = link.toEventID
        project.links.removeAll { $0 === link }
        modelContext.delete(link)
        if let arrival = project.events.first(where: { $0.id == toID && $0.sourceKind == Self.walletSourceKind }) {
            project.events.removeAll { $0 === arrival }
            modelContext.delete(arrival)
        }
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
