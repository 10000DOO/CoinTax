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
    /// 거래소가 아닌 **내 지갑**(하드웨어·소프트웨어). 여기로 옮기는 것은 양도가 아니다.
    case wallet
}

enum ExchangeCode: String, Codable, Sendable {
    case bithumb, binance, okx, generic
    /// 개인지갑. 파일 import 대상이 아니고, 거래소 출금을 「여기로 보냈다」고 지정할 때만 쓴다.
    case wallet
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
    /// USD 1:1 연동으로 보는 자산. 이 자산이 견적이면 그날 USD/KRW 로 환산한다.
    ///
    /// USDC 를 빼면 「코인 바꾸기(USDC→USDT)」가 원화 환산 근거를 못 찾아
    /// 취득가 0원 + Critical 로 계산이 막힌다 (실데이터에서 실제로 발생).
    /// 페그가 없는 코인을 넣으면 근거 없는 환산이 되므로 **USD 페그 스테이블만** 넣는다.
    var isUSDPegged: Bool { code == "USDT" || code == "USDC" || code == "USD" }
}
