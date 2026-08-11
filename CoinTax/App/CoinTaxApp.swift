import SwiftUI
import SwiftData

@main
struct CoinTaxApp: App {
    @StateObject private var env: AppEnvironment

    init() {
        // Unit tests inject XCTestConfigurationFilePath — use in-memory store so host launches cleanly.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        let container = try! CoinTaxModelContainer.make(inMemory: underTest)
        let environment = AppEnvironment(container: container)
        if !underTest {
            environment.bootstrap()
        }
        _env = StateObject(wrappedValue: environment)
    }

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environmentObject(env)
                .modelContainer(env.modelContainer)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
