import Foundation

struct ParseResult: Sendable {
    var parserID: String
    var events: [LedgerEvent]
    var meta: [String: String]
    var warnings: [String]
    var errors: [String]
    var ignoredCount: Int
}
