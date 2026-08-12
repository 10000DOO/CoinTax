import SwiftUI
import SwiftData

@main
struct CoinTaxApp: App {
    @StateObject private var env: AppEnvironment
    /// 저장소를 열지 못했을 때 사용자에게 보여줄 사유. 앱을 죽이지 않는다.
    private let storeFailure: String?

    init() {
        // Unit tests inject XCTestConfigurationFilePath — use in-memory store so host launches cleanly.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

        // `try!` 로 열면 스키마 변경·파일 손상 시 실행 즉시 크래시하고 복구 경로가 없다 (리뷰 4-2).
        // 열기에 실패하면 메모리 저장소로 실행해 사유를 화면에 표시한다 (기존 파일은 건드리지 않는다).
        var failure: String?
        var container: ModelContainer
        do {
            container = try CoinTaxModelContainer.make(inMemory: underTest)
        } catch {
            failure = String(describing: error)
            container = try! CoinTaxModelContainer.make(inMemory: true)
        }
        storeFailure = failure

        // 강제 종료로 남은 import 임시 사본을 정리한다 (개인정보 포함 가능)
        Self.purgeStaleImportCopies()

        let environment = AppEnvironment(container: container)
        if !underTest && failure == nil {
            environment.bootstrap()
        }
        _env = StateObject(wrappedValue: environment)
    }

    private static func purgeStaleImportCopies() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in entries where name.hasPrefix("CoinTaxImport-") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environmentObject(env)
                .modelContainer(env.modelContainer)
                .frame(minWidth: 980, minHeight: 660)
                .alert(
                    "저장소를 열 수 없습니다",
                    isPresented: .constant(storeFailure != nil)
                ) {
                    Button("확인") { }
                } message: {
                    Text("""
                    기존 프로젝트 데이터를 열지 못해 임시(메모리) 모드로 실행했습니다. \
                    이 상태에서 가져온 자료는 저장되지 않습니다.

                    사유: \(storeFailure ?? "")
                    """)
                }
        }
    }
}
