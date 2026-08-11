import Foundation

struct LedgerEvent: Identifiable, Codable, Sendable {
    var id: EventID
    var projectID: ProjectID
    var accountID: AccountID
    var sourceFileID: SourceFileID?
    var externalID: String?
    var fingerprint: String
    var timestamp: Date
    var type: EventType
    var baseAsset: AssetSymbol
    var quoteAsset: AssetSymbol?
    var quantity: Decimal
    var price: Decimal?
    var quoteAmount: Decimal?
    var quoteAmountKRW: Decimal?
    var feeAmount: Decimal?
    var feeAsset: AssetSymbol?
    var network: String?
    var addressHash: String?
    var txidHash: String?
    var memo: String?
    var counterpartyHint: String?
    var sourceKind: String
    var rawRef: String?
    var needsFX: Bool

    init(
        id: EventID = EventID(),
        projectID: ProjectID,
        accountID: AccountID,
        sourceFileID: SourceFileID? = nil,
        externalID: String? = nil,
        fingerprint: String = "",
        timestamp: Date,
        type: EventType,
        baseAsset: AssetSymbol,
        quoteAsset: AssetSymbol? = nil,
        quantity: Decimal,
        price: Decimal? = nil,
        quoteAmount: Decimal? = nil,
        quoteAmountKRW: Decimal? = nil,
        feeAmount: Decimal? = nil,
        feeAsset: AssetSymbol? = nil,
        network: String? = nil,
        addressHash: String? = nil,
        txidHash: String? = nil,
        memo: String? = nil,
        counterpartyHint: String? = nil,
        sourceKind: String,
        rawRef: String? = nil,
        needsFX: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.accountID = accountID
        self.sourceFileID = sourceFileID
        self.externalID = externalID
        self.fingerprint = fingerprint
        self.timestamp = timestamp
        self.type = type
        self.baseAsset = baseAsset
        self.quoteAsset = quoteAsset
        self.quantity = quantity
        self.price = price
        self.quoteAmount = quoteAmount
        self.quoteAmountKRW = quoteAmountKRW
        self.feeAmount = feeAmount
        self.feeAsset = feeAsset
        self.network = network
        self.addressHash = addressHash
        self.txidHash = txidHash
        self.memo = memo
        self.counterpartyHint = counterpartyHint
        self.sourceKind = sourceKind
        self.rawRef = rawRef
        self.needsFX = needsFX
    }
}

struct SourceFile: Identifiable, Codable, Sendable {
    var id: SourceFileID
    var projectID: ProjectID
    var fileName: String
    var format: SourceFormat
    var parserID: String
    var sha256: String
    var importedAt: Date
    var meta: [String: String]
}
