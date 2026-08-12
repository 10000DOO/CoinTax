import Foundation
import SwiftData

@Model
final class ProjectEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var defaultTaxYear: Int
    var notes: String?
    var lastPolicyBundleID: String?

    @Relationship(deleteRule: .cascade, inverse: \AccountEntity.project)
    var accounts: [AccountEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \SourceFileEntity.project)
    var sourceFiles: [SourceFileEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \LedgerEventEntity.project)
    var events: [LedgerEventEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \TransferLinkEntity.project)
    var links: [TransferLinkEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \FXRateEntity.project)
    var fxRates: [FXRateEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \MarketPriceEntity.project)
    var marketPrices: [MarketPriceEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \SnapshotEntity.project)
    var snapshots: [SnapshotEntity] = []

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), defaultTaxYear: Int, notes: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.defaultTaxYear = defaultTaxYear
        self.notes = notes
    }
}

@Model
final class AccountEntity {
    @Attribute(.unique) var id: UUID
    var exchangeCode: String
    var venueKind: String
    var displayName: String
    var costMethod: String
    var project: ProjectEntity?

    init(id: UUID = UUID(), exchangeCode: String, venueKind: String, displayName: String, costMethod: String) {
        self.id = id
        self.exchangeCode = exchangeCode
        self.venueKind = venueKind
        self.displayName = displayName
        self.costMethod = costMethod
    }
}

@Model
final class SourceFileEntity {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var format: String
    var parserID: String
    var sha256: String
    var importedAt: Date
    var metaJSON: String
    var project: ProjectEntity?

    init(id: UUID = UUID(), fileName: String, format: String, parserID: String, sha256: String, importedAt: Date = Date(), metaJSON: String = "{}") {
        self.id = id
        self.fileName = fileName
        self.format = format
        self.parserID = parserID
        self.sha256 = sha256
        self.importedAt = importedAt
        self.metaJSON = metaJSON
    }
}

@Model
final class LedgerEventEntity {
    @Attribute(.unique) var id: UUID
    var accountID: UUID
    var sourceFileID: UUID?
    var externalID: String?
    var fingerprint: String
    var timestamp: Date
    var type: String
    var baseAsset: String
    var quoteAsset: String?
    var quantity: String
    var price: String?
    var quoteAmount: String?
    var quoteAmountKRW: String?
    var feeAmount: String?
    var feeAsset: String?
    var network: String?
    var addressHash: String?
    var txidHash: String?
    var memo: String?
    var counterpartyHint: String?
    var sourceKind: String
    var rawRef: String?
    var needsFX: Bool
    /// 선언부 기본값 필수 — 기존 저장소를 경량 마이그레이션으로 열기 위함 (docs/fix-review-findings.md §8)
    var quantityIsNetOfFee: Bool = false
    var project: ProjectEntity?

    init(id: UUID = UUID(), accountID: UUID, fingerprint: String, timestamp: Date, type: String, baseAsset: String, quantity: String, sourceKind: String) {
        self.id = id
        self.accountID = accountID
        self.fingerprint = fingerprint
        self.timestamp = timestamp
        self.type = type
        self.baseAsset = baseAsset
        self.quantity = quantity
        self.sourceKind = sourceKind
        self.needsFX = false
    }
}

@Model
final class TransferLinkEntity {
    @Attribute(.unique) var id: UUID
    var fromEventID: UUID
    var toEventID: UUID
    var status: String
    var withdrawnQty: String
    var receivedQty: String
    var score: Double?
    var note: String?
    var transferredCostKRW: String?
    var abandonedCostKRW: String?
    var project: ProjectEntity?

    init(id: UUID = UUID(), fromEventID: UUID, toEventID: UUID, status: String, withdrawnQty: String, receivedQty: String) {
        self.id = id
        self.fromEventID = fromEventID
        self.toEventID = toEventID
        self.status = status
        self.withdrawnQty = withdrawnQty
        self.receivedQty = receivedQty
    }
}

@Model
final class FXRateEntity {
    var day: String
    var pair: String
    var rate: String
    var source: String
    var sourceDate: String?
    var project: ProjectEntity?

    init(day: String, pair: String = "USD/KRW", rate: String, source: String, sourceDate: String? = nil) {
        self.day = day
        self.pair = pair
        self.rate = rate
        self.source = source
        self.sourceDate = sourceDate
    }
}

@Model
final class MarketPriceEntity {
    var asOf: String
    var asset: String
    var priceKRW: String
    var source: String
    var project: ProjectEntity?

    init(asOf: String, asset: String, priceKRW: String, source: String) {
        self.asOf = asOf
        self.asset = asset
        self.priceKRW = priceKRW
        self.source = source
    }
}

@Model
final class SnapshotEntity {
    var taxYear: Int
    var status: String
    var policyBundleID: String
    var payloadJSON: String
    var calculatedAt: Date
    var project: ProjectEntity?

    init(taxYear: Int, status: String, policyBundleID: String, payloadJSON: String, calculatedAt: Date = Date()) {
        self.taxYear = taxYear
        self.status = status
        self.policyBundleID = policyBundleID
        self.payloadJSON = payloadJSON
        self.calculatedAt = calculatedAt
    }
}
