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
            TrezorSuiteCSVParser(),
            GenericTabularMapper() // 폴백 — detect 점수 낮음
        ])
    }

    func ranked(for probe: FormatProbeResult) -> [(parser: any ExchangeDocumentParser, score: Double)] {
        parsers
            .map { ($0, $0.detect(probe)) }
            .filter { $0.1 > 0.3 }
            // 점수가 같으면 **파서 ID 순**으로 고른다.
            //
            // Swift 의 `sort` 는 안정성을 보장하지 않는다 (`RowOrder` 에도 같은 이유가 적혀 있다).
            // 동점은 실제 파일명에서 난다 — `binance-deposit-withdraw-history.csv` 는
            // 입금 파서와 출금 파서가 나란히 0.92 다. 지금은 동점 파서가 같은 거래소로 가므로
            // 계정 배정이 흔들리진 않지만, 배열 순서에 결과가 달리면 나중에 파서를 추가·재배치할 때
            // **조용히 다른 파서가 선택된다.** 계산 결과가 실행마다 달라지면 안 된다 (06-integrity V-RE-01).
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.parserID < $1.0.parserID }
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
