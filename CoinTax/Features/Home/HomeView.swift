import SwiftUI
import SwiftData

/// 홈 — 「지금 뭘 해야 하는지」 한 화면에서 알 수 있게 한다.
///
/// 이 앱은 순서가 있는 도구다. 기능을 나열하면 사용자는 어디서 시작할지 모른다.
/// 그래서 위에는 **결과 한 줄**, 아래에는 **막힌 단계** 를 둔다.
struct HomeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Binding var progress: SetupProgress

    @State private var projects: [ProjectEntity] = []
    @State private var newName = ""
    @State private var showNewProject = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Page(title: "홈", subtitle: "가상자산 기타소득 신고 준비 상태") {
            if projects.count > 1 || showNewProject {
                projectPicker
            }
        } content: {
            heroCard
            checklistCard
            if env.lastCalculation != nil { snapshotCard }
            disclaimerCard
        }
        .task { reload() }
        .onChange(of: env.currentProject?.id) { _, _ in reload() }
    }

    // MARK: 결과 요약

    private var heroCard: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.gapSection) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        // SwiftUI 의 `Text` 보간은 로캘 숫자 형식을 적용한다 — 연도를 그대로 넣으면
                        // **"2,026년"** 이 된다. 빌드·테스트로는 안 잡히고 화면에서만 보인다.
                        Text("\(String(taxYear))년 예상 세액")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                        if let pill = statusPill { pill }
                    }
                    Text(env.lastCalculation.map { Fmt.krwString($0.summary.totalTaxKRW) } ?? "—")
                        .font(Theme.heroNumber)
                    Text(heroCaption)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        calculate()
                    } label: {
                        HStack(spacing: 5) {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "계산 중…" : (env.lastCalculation == nil ? "계산하기" : "다시 계산"))
                        }
                        .frame(minWidth: 84)
                    }
                    .primaryAction()
                    .disabled(busy || env.currentProject == nil)

                    if env.lastCalculation != nil {
                        Button("리포트 열기") { env.section = .report }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            if let message {
                Text(message).font(Theme.caption).foregroundStyle(.secondary)
            }

            if let c = env.lastCalculation, !env.calculationStale {
                Divider().padding(.vertical, 2)
                HStack(spacing: Theme.gap) {
                    StatTile(label: "소득금액", value: Fmt.krwCompact(c.summary.netIncomeKRW),
                             caption: "총수입 − 필요경비", tone: c.summary.netIncomeKRW >= 0 ? .neutral : .accent)
                    StatTile(label: "과세표준", value: Fmt.krwCompact(c.summary.taxBaseKRW),
                             caption: "소득 − 공제 250만")
                    StatTile(label: "과세 처분", value: "\(c.summary.disposals.count)건",
                             caption: "\(String(taxYear))년 양도")
                }
            }
        }
    }

    private var statusPill: Pill? {
        if env.currentProject == nil { return nil }
        if env.calculationStale { return Pill(text: "자료 변경됨", tone: .warning, systemImage: "arrow.clockwise") }
        guard let v = env.lastCalculation?.verification else { return nil }
        switch v.status {
        case "passed": return Pill(text: "검증 통과", tone: .positive, systemImage: "checkmark")
        case "passedWithWarnings": return Pill(text: "확인할 점 있음", tone: .warning, systemImage: "exclamationmark")
        default: return Pill(text: "검증 실패", tone: .danger, systemImage: "xmark")
        }
    }

    private var heroCaption: String {
        if env.currentProject == nil { return "프로젝트를 먼저 만드세요." }
        if env.lastCalculation == nil { return "아직 계산하지 않았습니다. 국세 20% + 지방소득세 2% 기준입니다." }
        if env.calculationStale { return "자료가 바뀌어 아래 숫자는 낡았습니다. 다시 계산하세요." }
        return "국세 20% + 지방소득세 2% · 세무 자문이 아닌 참고용입니다."
    }

    // MARK: 시작하기 체크리스트

    private var checklistCard: some View {
        Card {
            HStack {
                Text("시작하기").font(Theme.cardTitle)
                Spacer()
                Text("\(progress.doneCount) / \(progress.total) 완료")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(progress.doneCount), total: Double(max(progress.total, 1)))
                .tint(progress.doneCount == progress.total ? Theme.positive : .accentColor)

            VStack(spacing: 0) {
                ForEach(Array(progress.steps.enumerated()), id: \.element.id) { idx, step in
                    if idx > 0 { Divider() }
                    StepRow(
                        index: step.id,
                        title: step.title,
                        detail: step.detail,
                        state: stepState(step.state),
                        actionTitle: step.actionTitle,
                        action: step.section.map { s in { env.section = s } }
                    )
                }
            }
        }
    }

    private func stepState(_ s: SetupProgress.Step.State) -> StepRow.State {
        switch s {
        case .done: return .done
        case .needsAction: return .action
        case .waiting: return .waiting
        }
    }

    // MARK: 현재 자료

    private var snapshotCard: some View {
        Card(title: "지금 들어 있는 자료", systemImage: "shippingbox") {
            if let p = env.currentProject {
                HStack(spacing: Theme.gap) {
                    StatTile(label: "원본 파일", value: "\(p.sourceFiles.count)개")
                    StatTile(label: "거래", value: "\(p.events.count)건")
                    StatTile(label: "전송 연결", value: "\(p.links.filter { $0.status == LinkStatus.confirmed.rawValue }.count)건")
                    StatTile(label: "보유 자산",
                             value: "\(env.lastCalculation?.replay.holdings.aggregated.count ?? 0)종")
                }
            }
        }
    }

    private var disclaimerCard: some View {
        Card(title: "알아두실 점", systemImage: "info.circle") {
            ForEach(Array(TaxCopy.all.enumerated()), id: \.offset) { _, d in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(d)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("세무 확인이 필요한 항목 보기 (\(TaxOpenQuestions.needsConfirmation.count)건)") {
                env.section = .taxNotes
            }
            .buttonStyle(.link)
            .font(Theme.caption)
        }
    }

    // MARK: 프로젝트

    private var projectPicker: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { env.currentProject?.id },
                set: { id in env.currentProject = projects.first { $0.id == id } }
            )) {
                ForEach(projects, id: \.id) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)

            Button {
                showNewProject = true
            } label: {
                Image(systemName: "plus")
            }
            .help("새 프로젝트")
            .popover(isPresented: $showNewProject) {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    Text("새 프로젝트").font(Theme.cardTitle)
                    Text("연도나 용도별로 자료를 나눠 담을 수 있습니다.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                    TextField("이름", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    HStack {
                        Spacer()
                        Button("취소") { showNewProject = false; newName = "" }
                        Button("만들기") { createProject() }
                            .buttonStyle(.borderedProminent)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(Theme.cardPadding)
            }
        }
    }

    private var taxYear: Int { env.lastCalculation?.summary.taxYear ?? env.currentProject?.displayTaxYear ?? 2027 }

    private func reload() {
        projects = (try? env.projectService.fetchProjects()) ?? []
        if env.currentProject == nil { env.currentProject = projects.first }
        progress = SetupProgress.evaluate(env: env)
    }

    private func createProject() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            env.currentProject = try env.projectService.createProject(name: name)
            newName = ""
            showNewProject = false
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func calculate() {
        guard let project = env.currentProject else { return }
        busy = true
        message = nil
        Task {
            do {
                let result = try await env.pipeline.calculate(project: project, taxYear: project.displayTaxYear)
                env.lastCalculation = result
                env.calculationStale = false
                message = nil
            } catch {
                message = "계산하지 못했습니다 — \(error.localizedDescription)"
            }
            busy = false
            reload()
        }
    }
}
