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
    init(_ s: String) {
        code = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    var description: String { code }
    var isKRW: Bool { code == "KRW" }
    var isUSDTish: Bool { code == "USDT" || code == "USD" }
}
