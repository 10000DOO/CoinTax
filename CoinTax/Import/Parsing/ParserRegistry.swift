import Foundation

struct ParserRegistry: Sendable {
    var parsers: [any ExchangeDocumentParser]

    static var v1: ParserRegistry {
        ParserRegistry(parsers: [
            OKXFundingHistoryCSVParser(),
            OKXTradingHistoryCSVParser(),
            BinanceTransactionHistoryCSVParser(),
            BinanceDepositXLSXParser(),
            BinanceWithdrawXLSXParser(),
            BinanceSpotXLSXParser(),
            BithumbCertificatePDFParser(),
            GenericTabularMapper() // 폴백 — detect 점수 낮음
        ])
    }

    func ranked(for probe: FormatProbeResult) -> [(parser: any ExchangeDocumentParser, score: Double)] {
        parsers
            .map { ($0, $0.detect(probe)) }
            .filter { $0.1 > 0.3 }
            .sorted { $0.1 > $1.1 }
    }

    /// 최종 선택 (제네릭 폴백 포함). 아무것도 안 걸리면 `nil`.
    func resolve(for probe: FormatProbeResult) -> (any ExchangeDocumentParser)? {
        ranked(for: probe).first?.parser
    }

    /// **거래소 프리셋 중에서만** 가장 잘 맞는 것. 제네릭 매핑은 제외한다.
    ///
    /// 제네릭은 열 이름에 `date`·`amount` 만 있으면 0.35 를 내므로 항상 후보에 남는다.
    /// 계정 자동 배정처럼 「어느 거래소인지」가 결론이어야 하는 곳에서 제네릭을 섞으면
    /// 근거 없이 특정 계정으로 들어간다.
    func bestPreset(for probe: FormatProbeResult) -> (parser: any ExchangeDocumentParser, score: Double)? {
        ranked(for: probe).first { $0.parser.parserID != "generic-tabular-v1" }
    }
}
