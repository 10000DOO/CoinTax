import Combine
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class AppEnvironment: ObservableObject {
    let modelContainer: ModelContainer
    let modelContext: ModelContext
    var policies: PolicyBundle = .v1Default

    lazy var projectService: ProjectService = ProjectService(modelContext: modelContext)
    lazy var importService: ImportService = ImportService(modelContext: modelContext)
    lazy var matchingService: MatchingService = MatchingService(modelContext: modelContext)
    lazy var fxService: FXService = FXService(modelContext: modelContext)
    lazy var pipeline: CalculationPipeline = {
        let p = CalculationPipeline(modelContext: modelContext)
        p.policies = policies
        return p
    }()

    @Published var currentProject: ProjectEntity?
    @Published var lastCalculation: CalculationResult?

    init(container: ModelContainer) {
        self.modelContainer = container
        self.modelContext = container.mainContext
    }

    func bootstrap() {
        do {
            currentProject = try projectService.ensureDefaultProject()
        } catch {
            print("bootstrap error: \(error)")
        }
    }
}
