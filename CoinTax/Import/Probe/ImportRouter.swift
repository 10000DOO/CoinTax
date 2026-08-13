import Foundation

/// 파일 하나가 **어느 거래소 계정으로 들어가야 하는지** 판단한다.
///
/// 계정을 사람이 고르게 두면, 여러 거래소 파일을 한 번에 넣을 때 전부 한 계정으로 들어간다.
/// 그러면 두 가지가 동시에 망가진다.
///
/// 1. **원가법이 뒤바뀐다** — 빗썸은 이동평균, 해외는 선입선출이다 (05-decisions §1.2).
/// 2. **거래소 간 전송이 사라진다** — 전송 매칭은 계정이 서로 달라야 후보로 잡는다
///    (`TransferMatchingEngine.suggest`). 같은 계정이 되면 매칭이 안 되고 취득원가가 소멸해
///    **세금이 실제보다 커진다.**
///
/// 그래서 파일 내용으로 파서를 찾은 뒤, 그 파서가 어느 거래소 것인지까지 확정한다.
enum ImportRouter {
    /// 자동 배정을 받아들이는 최소 신뢰도.
    ///
    /// 프리셋 파서들은 파일명·헤더가 맞으면 0.85 이상을 낸다. 그 아래는 「모르겠다」로 두고
    /// 사용자에게 묻는다 — 틀린 계정으로 조용히 들어가는 것보다 낫다.
    static let autoAcceptScore = 0.6

    struct Route: Sendable {
        var parserID: String?
        var score: Double
        var exchange: ExchangeCode?

        /// 자동으로 계정을 정해도 되는가
        var isConfident: Bool { exchange != nil && score >= ImportRouter.autoAcceptScore }
    }

    /// 파서 ID → 거래소. 제네릭 매핑은 어느 거래소인지 알 수 없으므로 `nil`.
    static func exchange(forParserID id: String) -> ExchangeCode? {
        switch id {
        case "bithumb-certificate-pdf-v1":
            return .bithumb
        case "binance-spot-xlsx-v1", "binance-deposit-xlsx-v1", "binance-withdraw-xlsx-v1",
             "binance-transaction-history-csv-v1":
            return .binance
        case "okx-trading-history-csv-v1", "okx-funding-history-csv-v1":
            return .okx
        default:
            return nil
        }
    }

    static func route(_ probe: FormatProbeResult, registry: ParserRegistry = .v1) -> Route {
        guard let best = registry.bestPreset(for: probe) else {
            return Route(parserID: nil, score: 0, exchange: nil)
        }
        return Route(
            parserID: best.parser.parserID,
            score: best.score,
            exchange: exchange(forParserID: best.parser.parserID)
        )
    }

    /// 손으로 고른 계정과 **파일 내용**이 어긋나는가. 어긋나면 파일이 가리키는 거래소를 돌려준다.
    ///
    /// 사용자가 거래소를 직접 고르면 앱은 그대로 따른다 — 그게 맞다. 다만 앱은 바로 직전에
    /// 파일 내용으로 어느 거래소 것인지 **이미 알고 있으면서** 아무 말도 하지 않았다.
    /// 잘못 들어가면 원가법이 바뀌고(빗썸=이동평균 vs 해외=선입선출) 거래소 간 전송이 안 잡혀
    /// **세금이 달라지는데**, 잔고 대조는 (계정, 원본 종류)별로 보므로 그래도 통과한다 — 아무도 못 잡는다.
    static func mismatch(route: Route, chosenExchange: String?) -> ExchangeCode? {
        guard let chosen = chosenExchange, route.isConfident,
              let detected = route.exchange, detected.rawValue != chosen else { return nil }
        return detected
    }

    /// 사용자에게 보여줄 거래소 이름
    static func displayName(_ code: ExchangeCode) -> String {
        switch code {
        case .bithumb: return "빗썸"
        case .binance: return "바이낸스"
        case .okx: return "OKX"
        case .generic: return "기타"
        case .wallet: return "개인지갑"
        }
    }
}
