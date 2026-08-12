import Foundation

struct ProjectID: Hashable, Codable, Sendable {
    var raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
}

struct AccountID: Hashable, Codable, Sendable {
    var raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
}

struct EventID: Hashable, Codable, Sendable {
    var raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
}

struct SourceFileID: Hashable, Codable, Sendable {
    var raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
}

struct LinkID: Hashable, Codable, Sendable {
    var raw: UUID
    init(_ raw: UUID = UUID()) { self.raw = raw }
}

enum VenueKind: String, Codable, Sendable {
    case domestic, overseas, unknown
}

enum ExchangeCode: String, Codable, Sendable {
    case bithumb, binance, okx, generic
}

enum CostBasisMethod: String, Codable, Sendable {
    case movingAverage, fifo
}

enum EventType: String, Codable, Sendable {
    case buy, sell, deposit, withdrawal, fee, income
    case transferInternal
    case fiatDeposit, fiatWithdraw
    case other, ignored
}

enum LinkStatus: String, Codable, Sendable {
    case suggested, confirmed, rejected
}

enum SummaryStatus: String, Codable, Sendable {
    case draft, verified, blocked
}

enum SourceFormat: String, Codable, Sendable {
    case pdf, xlsx, csv, text, unknown
}

struct AssetSymbol: Hashable, Codable, Sendable, CustomStringConvertible {
    var code: String

    /// 같은 자산을 거래소가 다른 티커로 표기하는 경우만 정규화한다 (F-TX-02).
    ///
    /// **의도적으로 넣지 않는 것** — 이름이 비슷해도 세무상 다른 자산이다:
    /// - `WBTC`/`WETH` (래핑 토큰): BTC·ETH 와 별개 자산. 합치면 서로 다른 취득 이력이 한 원장에 섞인다.
    /// - `USDT.E`/`USDC.E` (브릿지 토큰): 원본 토큰과 별개.
    /// - `KRWT` 같은 원화 연동 토큰: `KRW` 로 합치면 엔진이 원화로 보고 **원장에서 아예 제외**해 버린다.
    /// 이런 자산은 별도 원장으로 남기고, 필요하면 세무 확인 후 사용자가 판단한다.
    static let aliases: [String: String] = [
        "XBT": "BTC",       // 비트코인의 ISO 스타일 티커 (일부 거래소·시세 피드)
        "BCHABC": "BCH",    // 하드포크 당시 임시 티커
        "BCHSV": "BSV"
    ]

    init(_ s: String) {
        let raw = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        code = Self.aliases[raw] ?? raw
    }

    var description: String { code }
    var isKRW: Bool { code == "KRW" }
    var isUSDTish: Bool { code == "USDT" || code == "USD" }
}
