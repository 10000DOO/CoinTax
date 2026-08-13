import Combine
import Foundation
import SwiftData
import SwiftUI

@MainActor
final class AppEnvironment: ObservableObject {
    let modelContainer: ModelContainer
    let modelContext: ModelContext
    /// 표시·계산이 같은 값을 보도록 **매번 단일 출처에서 만든다** (저장 사본 금지)
    var policies: PolicyBundle { .current }

    lazy var projectService: ProjectService = ProjectService(modelContext: modelContext)
    lazy var importService: ImportService = ImportService(modelContext: modelContext)
    lazy var matchingService: MatchingService = MatchingService(modelContext: modelContext)
    lazy var fxService: FXService = FXService(modelContext: modelContext)
    lazy var pipeline: CalculationPipeline = {
        let p = CalculationPipeline(modelContext: modelContext)
        p.fxService = fxService
        return p
    }()

    @Published var currentProject: ProjectEntity?
    /// 지금 보고 있는 화면. 홈의 체크리스트가 여기를 바꿔 해당 화면으로 보낸다.
    @Published var section: AppSection = .home
    @Published var lastCalculation: CalculationResult?
    /// 계산 이후 데이터가 바뀌었는지. true 면 리포트·내보내기가 낡은 결과다.
    @Published var calculationStale = false

    /// import·매칭 등으로 원본이 바뀌면 호출한다.
    /// 낡은 검증 결과로 내보내기가 열려 있으면 사용자가 최신 자료라고 오해한다.
    func invalidateCalculation() {
        guard lastCalculation != nil else { return }
        calculationStale = true
    }

    /// 계산에 **들어가는 값**(의제 시가 등)을 지운다.
    ///
    /// 지우기와 「다시 계산해야 함」 표시를 **한 곳에 묶는다.** 화면마다 따로 적으면
    /// 한 곳이 빠지고, 그러면 낡은 계산이 「검증 완료」로 남아 **신고자료 내보내기가 열린 채**가 된다
    /// (`ReportView.canExport` 가 이 표시로 잠근다). 실제로 시가 삭제 버튼에서 그렇게 빠져 있었다.
    func deleteCalculationInput(_ object: some PersistentModel) throws {
        modelContext.delete(object)
        try modelContext.save()
        invalidateCalculation()
    }

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
