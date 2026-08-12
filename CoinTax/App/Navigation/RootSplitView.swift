import SwiftUI
import SwiftData

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard = "대시보드"
    case importFiles = "Import"
    case ledger = "거래내역"
    case matching = "전송 매칭"
    case holdings = "보유"
    case report = "리포트"
    case taxNotes = "세무 확인"
    case settings = "설정"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .importFiles: return "square.and.arrow.down"
        case .ledger: return "list.bullet.rectangle"
        case .matching: return "arrow.left.arrow.right"
        case .holdings: return "bitcoinsign.circle"
        case .report: return "doc.text"
        case .taxNotes: return "exclamationmark.questionmark"
        case .settings: return "gearshape"
        }
    }
}

struct RootSplitView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selection: AppSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("CoinTax")
            .safeAreaInset(edge: .bottom) {
                if let p = env.currentProject {
                    Text(p.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                }
            }
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard: DashboardView()
            case .importFiles: ImportView()
            case .ledger: LedgerView()
            case .matching: MatchingView()
            case .holdings: HoldingsView()
            case .report: ReportView()
            case .taxNotes: TaxOpenQuestionsView()
            case .settings: SettingsView()
            }
        }
    }
}
