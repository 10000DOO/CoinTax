import Foundation

enum EntityMappers {
    static func project(_ e: ProjectEntity) -> Project {
        Project(
            id: ProjectID(e.id),
            name: e.name,
            createdAt: e.createdAt,
            defaultTaxYear: e.defaultTaxYear,
            notes: e.notes,
            lastPolicyBundleID: e.lastPolicyBundleID
        )
    }

    static func account(_ e: AccountEntity, projectID: ProjectID) -> Account {
        Account(
            id: AccountID(e.id),
            projectID: projectID,
            exchangeCode: ExchangeCode(rawValue: e.exchangeCode) ?? .generic,
            venueKind: VenueKind(rawValue: e.venueKind) ?? .unknown,
            displayName: e.displayName,
            costMethod: CostBasisMethod(rawValue: e.costMethod) ?? .fifo
        )
    }

    static func event(_ e: LedgerEventEntity, projectID: ProjectID) -> LedgerEvent {
        LedgerEvent(
            id: EventID(e.id),
            projectID: projectID,
            accountID: AccountID(e.accountID),
            sourceFileID: e.sourceFileID.map { SourceFileID($0) },
            externalID: e.externalID,
            fingerprint: e.fingerprint,
            timestamp: e.timestamp,
            type: EventType(rawValue: e.type) ?? .other,
            baseAsset: AssetSymbol(e.baseAsset),
            quoteAsset: e.quoteAsset.map { AssetSymbol($0) },
            quantity: Decimal(string: e.quantity) ?? 0,
            price: e.price.flatMap { Decimal(string: $0) },
            quoteAmount: e.quoteAmount.flatMap { Decimal(string: $0) },
            quoteAmountKRW: e.quoteAmountKRW.flatMap { Decimal(string: $0) },
            feeAmount: e.feeAmount.flatMap { Decimal(string: $0) },
            feeAsset: e.feeAsset.map { AssetSymbol($0) },
            network: e.network,
            addressHash: e.addressHash,
            txidHash: e.txidHash,
            memo: e.memo,
            counterpartyHint: e.counterpartyHint,
            sourceKind: e.sourceKind,
            rawRef: e.rawRef,
            needsFX: e.needsFX,
            quantityIsNetOfFee: e.quantityIsNetOfFee,
            balanceAfter: e.balanceAfter.flatMap { Decimal(string: $0) },
            quoteBalanceAfter: e.quoteBalanceAfter.flatMap { Decimal(string: $0) }
        )
    }

    static func link(_ e: TransferLinkEntity, projectID: ProjectID) -> TransferLink {
        TransferLink(
            id: LinkID(e.id),
            projectID: projectID,
            fromEventID: EventID(e.fromEventID),
            toEventID: EventID(e.toEventID),
            status: LinkStatus(rawValue: e.status) ?? .suggested,
            withdrawnQty: Decimal(string: e.withdrawnQty) ?? 0,
            receivedQty: Decimal(string: e.receivedQty) ?? 0,
            score: e.score,
            note: e.note,
            transferredCostKRW: e.transferredCostKRW.flatMap { Decimal(string: $0) },
            abandonedCostKRW: e.abandonedCostKRW.flatMap { Decimal(string: $0) }
        )
    }

    static func apply(_ event: LedgerEvent, to entity: LedgerEventEntity) {
        entity.accountID = event.accountID.raw
        entity.sourceFileID = event.sourceFileID?.raw
        entity.externalID = event.externalID
        entity.fingerprint = event.fingerprint
        entity.timestamp = event.timestamp
        entity.type = event.type.rawValue
        entity.baseAsset = event.baseAsset.code
        entity.quoteAsset = event.quoteAsset?.code
        entity.quantity = Money.decimalString(event.quantity)
        entity.price = event.price.map { Money.decimalString($0) }
        entity.quoteAmount = event.quoteAmount.map { Money.decimalString($0) }
        entity.quoteAmountKRW = event.quoteAmountKRW.map { Money.decimalString($0) }
        entity.feeAmount = event.feeAmount.map { Money.decimalString($0) }
        entity.feeAsset = event.feeAsset?.code
        entity.network = event.network
        entity.addressHash = event.addressHash
        entity.txidHash = event.txidHash
        entity.memo = event.memo
        entity.counterpartyHint = event.counterpartyHint
        entity.sourceKind = event.sourceKind
        entity.rawRef = event.rawRef
        entity.needsFX = event.needsFX
        entity.quantityIsNetOfFee = event.quantityIsNetOfFee
        entity.balanceAfter = event.balanceAfter.map { Money.decimalString($0) }
        entity.quoteBalanceAfter = event.quoteBalanceAfter.map { Money.decimalString($0) }
    }

    static func makeEntity(from event: LedgerEvent) -> LedgerEventEntity {
        let e = LedgerEventEntity(
            id: event.id.raw,
            accountID: event.accountID.raw,
            fingerprint: event.fingerprint,
            timestamp: event.timestamp,
            type: event.type.rawValue,
            baseAsset: event.baseAsset.code,
            quantity: Money.decimalString(event.quantity),
            sourceKind: event.sourceKind
        )
        apply(event, to: e)
        return e
    }
}
