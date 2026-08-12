import SwiftUI
import SwiftData

struct DashboardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var message = ""
    @State private var projects: [ProjectEntity] = []
    @State private var newName = ""
    /// 화면 본문에서 매번 계산하면 전체 이벤트를 변환한다 (리뷰 6-2)
    @State private var missingFX: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("대시보드")
                    .font(.largeTitle.bold())

                GroupBox("프로젝트") {
                    ForEach(projects, id: \.id) { p in
                        HStack {
                            Button(p.name) {
                                env.currentProject = p
                                message = "열림: \(p.name)"
                            }
                            .buttonStyle(.borderless)
                            .fontWeight(env.currentProject?.id == p.id ? .bold : .regular)
                            Spacer()
                            Text("이벤트 \(p.events.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        TextField("새 프로젝트 이름", text: $newName)
                        Button("만들기") { createProject() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let p = env.currentProject {
                    GroupBox("현재 프로젝트") {
                        LabeledContent("이름", value: p.name)
                        LabeledContent("기본 과세연도", value: "\(p.defaultTaxYear)")
                        LabeledContent("계정", value: "\(p.accounts.count)개 (다중 거래소)")
                        LabeledContent("이벤트", value: "\(p.events.count)건")
                        LabeledContent("전송 링크(확정)", value: "\(p.links.filter { $0.status == LinkStatus.confirmed.rawValue }.count)건")
                        LabeledContent("원본 파일", value: "\(p.sourceFiles.count)개")
                    }

                    if !missingFX.isEmpty {
                        GroupBox("환율 누락") {
                            Text("\(missingFX.count)일: " + missingFX.prefix(12).joined(separator: ", ") + (missingFX.count > 12 ? " …" : ""))
                                .foregroundStyle(.orange)
                            Text("자동 조회가 켜져 있으면 계산 시 채웁니다. 설정에서 수동/CSV도 가능합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("지금 계산 (기본 연도)") { runCalc(project: p) }
                        if !message.isEmpty {
                            Text(message).foregroundStyle(.secondary)
                        }
                    }
                }

                if let c = env.lastCalculation {
                    GroupBox("최근 계산") {
                        LabeledContent("연도", value: "\(c.summary.taxYear)")
                        LabeledContent("검증", value: c.verification.status)
                        LabeledContent("소득", value: Money.decimalString(c.summary.netIncomeKRW))
                        LabeledContent("예상 세액", value: Money.decimalString(c.summary.totalTaxKRW))
                        LabeledContent("보유 행", value: "\(c.replay.holdings.rows.count)")
                        LabeledContent("소실 원가(참고)", value: Money.decimalString(c.summary.abandonedTransferCostKRW))
                    }
                }

                GroupBox("정책") {
                    LabeledContent("PolicyBundle", value: env.policies.id)
                    Text(TaxCopy.notTaxAdvice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            reloadProjects()
            refreshMissingFX()
        }
    }

    private func refreshMissingFX() {
        guard let p = env.currentProject else {
            missingFX = []
            return
        }
        missingFX = env.fxService.missingDays(for: env.projectService.domainEvents(for: p), project: p)
    }

    private func reloadProjects() {
        projects = (try? env.projectService.fetchProjects()) ?? []
        if env.currentProject == nil {
            env.currentProject = projects.first
        }
    }

    private func createProject() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let p = try env.projectService.createProject(name: name)
            env.currentProject = p
            newName = ""
            reloadProjects()
            message = "생성됨: \(name)"
        } catch {
            message = error.localizedDescription
        }
    }

    private func runCalc(project: ProjectEntity) {
        message = "계산 중…"
        Task {
            do {
                let result = try await env.pipeline.calculate(project: project, taxYear: project.defaultTaxYear)
                env.lastCalculation = result
                env.calculationStale = false
                refreshMissingFX()
                message = "계산 완료 — \(result.verification.status)"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
