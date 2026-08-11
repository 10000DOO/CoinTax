import Foundation
import SwiftData

enum CoinTaxModelContainer {
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            ProjectEntity.self,
            AccountEntity.self,
            SourceFileEntity.self,
            LedgerEventEntity.self,
            TransferLinkEntity.self,
            FXRateEntity.self,
            MarketPriceEntity.self,
            SnapshotEntity.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
