import Foundation

struct Account: Identifiable, Codable, Sendable {
    var id: AccountID
    var projectID: ProjectID
    var exchangeCode: ExchangeCode
    var venueKind: VenueKind
    var displayName: String
    var costMethod: CostBasisMethod

    static func defaults(for code: ExchangeCode, projectID: ProjectID) -> Account {
        switch code {
        case .bithumb:
            return Account(id: AccountID(), projectID: projectID, exchangeCode: .bithumb, venueKind: .domestic, displayName: "빗썸", costMethod: .movingAverage)
        case .binance:
            return Account(id: AccountID(), projectID: projectID, exchangeCode: .binance, venueKind: .overseas, displayName: "바이낸스", costMethod: .fifo)
        case .okx:
            return Account(id: AccountID(), projectID: projectID, exchangeCode: .okx, venueKind: .overseas, displayName: "OKX", costMethod: .fifo)
        case .generic:
            return Account(id: AccountID(), projectID: projectID, exchangeCode: .generic, venueKind: .unknown, displayName: "기타", costMethod: .fifo)
        }
    }
}
