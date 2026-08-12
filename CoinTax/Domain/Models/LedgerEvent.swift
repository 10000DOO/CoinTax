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
    /// `quantity`가 이미 수수료를 차감한 **순증분**인지.
    ///
    /// 거래소별 관례가 다르다 — 바이낸스 `Amount`는 수수료 차감 **전**,
    /// OKX `Balance Change`는 차감 **후** 값이다. 엔진이 base 수수료를 한 번 더 빼면
    /// OKX 쪽 수량이 이중으로 줄어든다(리뷰 1-1). 파서가 이 플래그로 관례를 흡수한다.
    var quantityIsNetOfFee: Bool
    /// 거래소가 원본에 찍어준 **이 거래 직후 잔고** (기초자산). 없으면 nil.
    ///
    /// 거래소 자기 장부의 값이라 우리 코드와 독립이다. 검증기가 매 거래마다 대조해
    /// 파싱 오류·이벤트 누락·수량 규칙 오해를 **자동으로** 잡는다 (V-BAL).
    var balanceAfter: Decimal?
    /// 견적자산 잔고 (OKX 거래내역처럼 한 주문에 두 자산 잔고가 다 있는 경우)
    var quoteBalanceAfter: Decimal?
    /// 잘못 보내 되돌릴 수 없게 된 출금인지 (사용자가 직접 확인해 지정).
    ///
    /// 처리 결과는 「연결되지 않은 출금」과 같다 — 취득원가가 소멸한다.
    /// 다른 점은 **사용자가 이미 판단했다는 사실**이다. 그래서 「연결하세요」 경고를 더 내지 않는다.
    var lostForever: Bool = false

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
        needsFX: Bool = false,
        quantityIsNetOfFee: Bool = false,
        balanceAfter: Decimal? = nil,
        quoteBalanceAfter: Decimal? = nil
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
        self.quantityIsNetOfFee = quantityIsNetOfFee
        self.balanceAfter = balanceAfter
        self.quoteBalanceAfter = quoteBalanceAfter
    }
}

extension LedgerEvent {
    /// 코인↔코인 매매에서 실제로 움직이는 **견적자산 수량**.
    ///
    /// 원화 마켓(빗썸)이나 견적 금액 근거가 없으면 `nil`.
    /// 매수면 이 수량만큼 견적자산이 나가고(= 그 자산의 처분), 매도면 이 수량만큼 들어온다.
    /// 이 leg 을 빼먹으면 USDT 잔고가 줄지 않아 원장이 붕괴한다.
    var cryptoQuoteQuantity: Decimal? {
        guard type == .buy || type == .sell else { return nil }
        guard let quote = quoteAsset, !quote.isKRW, quote != baseAsset else { return nil }
        let amount: Decimal
        if let quoteAmount {
            amount = Money.abs(quoteAmount)
        } else if let price {
            amount = Money.abs(quantity) * price
        } else {
            return nil
        }
        return amount > 0 ? amount : nil
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
