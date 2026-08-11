import Foundation

protocol ExchangeDocumentParser: Sendable {
    var parserID: String { get }
    /// 0...1 detect confidence
    func detect(_ probe: FormatProbeResult) -> Double
    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult
    /// Optional text mode for synthetic fixtures
    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult
}

extension ExchangeDocumentParser {
    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        throw CoinTaxError.parserReject("텍스트 모드 미지원: \(parserID)")
    }
}
