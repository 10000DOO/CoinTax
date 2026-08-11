import Foundation

struct ParserRegistry: Sendable {
    var parsers: [any ExchangeDocumentParser]

    static var v1: ParserRegistry {
        ParserRegistry(parsers: [
            OKXFundingHistoryCSVParser(),
            OKXTradingHistoryCSVParser(),
            BinanceDepositXLSXParser(),
            BinanceWithdrawXLSXParser(),
            BinanceSpotXLSXParser(),
            BithumbCertificatePDFParser()
        ])
    }

    func ranked(for probe: FormatProbeResult) -> [(parser: any ExchangeDocumentParser, score: Double)] {
        parsers
            .map { ($0, $0.detect(probe)) }
            .filter { $0.1 > 0.3 }
            .sorted { $0.1 > $1.1 }
    }

    func resolve(for probe: FormatProbeResult) -> (any ExchangeDocumentParser)? {
        let r = ranked(for: probe)
        guard let top = r.first else { return nil }
        if top.score >= 0.85 { return top.parser }
        return top.parser
    }
}
