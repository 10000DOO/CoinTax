import Foundation

struct Project: Identifiable, Codable, Sendable {
    var id: ProjectID
    var name: String
    var createdAt: Date
    var defaultTaxYear: Int
    var notes: String?
    var lastPolicyBundleID: String?
}
