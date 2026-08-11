import Foundation

struct TransferLink: Identifiable, Codable, Sendable {
    var id: LinkID
    var projectID: ProjectID
    var fromEventID: EventID
    var toEventID: EventID
    var status: LinkStatus
    var withdrawnQty: Decimal
    var receivedQty: Decimal
    var score: Double?
    var note: String?
    var transferredCostKRW: Decimal?
    var abandonedCostKRW: Decimal?
}
