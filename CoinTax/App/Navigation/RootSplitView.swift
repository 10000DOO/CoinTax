import SwiftUI
import SwiftData

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home = "홈"
    case importFiles = "자료 넣기"
    case matching = "전송 연결"
    case ledger = "거래내역"
    case holdings = "보유 현황"
    case report = "세금 리포트"
    case taxNotes = "세무 확인"
    case settings = "설정"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .importFiles: return "tray.and.arrow.down"
        case .matching: return "arrow.left.arrow.right"
        case .ledger: return "list.bullet.rectangle"
        case .holdings: return "wallet.bifold"
        case .report: return "doc.text.magnifyingglass"
        case .taxNotes: return "questionmark.circle"
        case .settings: return "gearshape"
        }
    }

    /// 사이드바 묶음 — 순서가 곧 사용 순서다
    enum Group: String, CaseIterable {
        case start = "시작"
        case prepare = "자료 준비"
        case result = "결과"
        case etc = "기타"
    }

    var group: Group {
        switch self {
        case .home: return .start
        case .importFiles, .matching: return .prepare
        case .ledger, .holdings, .report: return .result
        case .taxNotes, .settings: return .etc
        }
    }

    static func members(of group: Group) -> [AppSection] {
        allCases.filter { $0.group == group }
    }
}

/// 사이드바 한 줄. 본문에 인라인으로 두면 타입 검사가 급격히 느려진다.
private struct SidebarRow: View {
    let section: AppSection
    let flag: (text: String, tone: Tone)?

    var body: some View {
        HStack(spacing: 6) {
            Label(section.rawValue, systemImage: section.systemImage)
            Spacer(minLength: 4)
            if let flag {
                Text(flag.text)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(flag.tone.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(flag.tone.color)
            }
        }
    }
}

struct RootSplitView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var progress = SetupProgress()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail.frame(minWidth: 620)
        }
        .task { refresh() }
        .onChange(of: env.section) { _, _ in refresh() }
        .onChange(of: env.calculationStale) { _, _ in refresh() }
    }

    private var selection: Binding<AppSection?> {
        Binding(get: { env.section }, set: { env.section = $0 ?? .home })
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(AppSection.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(AppSection.members(of: group)) { section in
                        SidebarRow(section: section, flag: flag(for: section))
                            .tag(section)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 208, max: 250)
        .safeAreaInset(edge: .bottom) { projectFooter }
    }

    @ViewBuilder
    private var detail: some View {
        switch env.section {
        case .home: HomeView(progress: $progress)
        case .importFiles: ImportView()
        case .matching: MatchingView()
        case .ledger: LedgerView()
        case .holdings: HoldingsView()
        case .report: ReportView()
        case .taxNotes: TaxOpenQuestionsView()
        case .settings: SettingsView()
        }
    }

    /// 손봐야 할 곳을 사이드바에서 바로 알 수 있게 한다.
    private func flag(for section: AppSection) -> (text: String, tone: Tone)? {
        switch section {
        case .matching:
            guard progress.pendingCandidates > 0 else { return nil }
            return ("\(progress.pendingCandidates)", .warning)
        case .settings:
            let n = progress.missingFXDays.count + progress.missingMarketAssets.count
            return n > 0 ? ("\(n)", .warning) : nil
        case .report:
            if env.calculationStale { return ("갱신", .warning) }
            if let v = env.lastCalculation?.verification, !v.isExportAllowed { return ("확인", .danger) }
            return nil
        default:
            return nil
        }
    }

    private var projectFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(env.currentProject?.name ?? "프로젝트 없음")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func refresh() {
        progress = SetupProgress.evaluate(env: env)
    }
}
