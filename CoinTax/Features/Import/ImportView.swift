import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedAccountID: UUID?
    @State private var message: String = ""
    @State private var isImporterPresented = false
    @State private var lastDetect: ImportService.DetectOutcome?
    @State private var lastPreview: [LedgerEventEntity] = []
    @State private var lastWarnings: [String] = []
    @State private var lastErrors: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import")
                    .font(.largeTitle.bold())
                if let project = env.currentProject {
                    Picker("계정", selection: $selectedAccountID) {
                        Text("선택").tag(Optional<UUID>.none)
                        ForEach(project.accounts, id: \.id) { acc in
                            Text("\(acc.displayName) (\(acc.exchangeCode))").tag(Optional(acc.id))
                        }
                    }
                    .frame(maxWidth: 400)

                    HStack {
                        Button("파일 추가…") { isImporterPresented = true }
                            .disabled(selectedAccountID == nil)
                        if let d = lastDetect {
                            detectBadge(d)
                        }
                    }

                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    binanceChecklist(project)

                    if !lastWarnings.isEmpty || !lastErrors.isEmpty {
                        GroupBox("이슈") {
                            ForEach(lastErrors, id: \.self) { e in
                                Text("오류: \(e)").foregroundStyle(.red)
                            }
                            ForEach(lastWarnings, id: \.self) { w in
                                Text("경고: \(w)").foregroundStyle(.orange)
                            }
                        }
                    }

                    if !lastPreview.isEmpty {
                        GroupBox("최근 미리보기 (\(lastPreview.count)건)") {
                            ForEach(lastPreview.prefix(20), id: \.id) { e in
                                HStack {
                                    Text(e.timestamp.formatted(date: .numeric, time: .shortened))
                                        .frame(width: 130, alignment: .leading)
                                    Text(e.type).frame(width: 90, alignment: .leading)
                                    Text(e.baseAsset).frame(width: 50)
                                    Text(e.quantity).frame(width: 90, alignment: .trailing)
                                    Spacer()
                                    Text(e.sourceKind).font(.caption).foregroundStyle(.secondary)
                                }
                                .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }

                    GroupBox("원본 파일") {
                        if project.sourceFiles.isEmpty {
                            Text("아직 import한 파일이 없습니다.")
                        } else {
                            ForEach(project.sourceFiles.sorted(by: { $0.importedAt > $1.importedAt }), id: \.id) { f in
                                HStack {
                                    Text(f.fileName)
                                    Spacer()
                                    Text(f.format).foregroundStyle(.secondary)
                                    Text(f.parserID)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.commaSeparatedText, .pdf, .data, .plainText, .spreadsheet],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = env.currentProject?.accounts.first?.id
            }
        }
    }

    @ViewBuilder
    private func detectBadge(_ d: ImportService.DetectOutcome) -> some View {
        let label = d.topParserID ?? "미인식"
        let conf = d.ranked.first?.score ?? 0
        Text("\(d.probe.format.rawValue) · \(label) (\(String(format: "%.0f%%", conf * 100)))")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(conf >= 0.85 ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
    }

    @ViewBuilder
    private func binanceChecklist(_ project: ProjectEntity) -> some View {
        let names = project.sourceFiles.map { $0.fileName.lowercased() + " " + $0.parserID.lowercased() }
        let spot = names.contains { $0.contains("spot") || $0.contains("binance-spot") }
        let deposit = names.contains { $0.contains("deposit") || $0.contains("binance-deposit") }
        let withdraw = names.contains { $0.contains("withdraw") || $0.contains("binance-withdraw") }
        GroupBox("바이낸스 3파일 체크리스트") {
            Label(spot ? "Spot Trade History" : "Spot Trade History (미반입)", systemImage: spot ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(spot ? .green : .secondary)
            Label(deposit ? "Deposit History" : "Deposit History (미반입)", systemImage: deposit ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(deposit ? .green : .secondary)
            Label(withdraw ? "Withdraw History" : "Withdraw History (미반입)", systemImage: withdraw ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(withdraw ? .green : .secondary)
            Text("빗썸↔바이낸스 전송 매칭에는 Spot + Deposit + Withdraw 조합이 필요합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let project = env.currentProject,
              let accID = selectedAccountID,
              let account = project.accounts.first(where: { $0.id == accID }) else { return }
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            lastDetect = env.importService.detect(url: url)
            let outcome = try env.importService.importFile(url: url, project: project, account: account)
            lastWarnings = outcome.parseResult.warnings
            lastErrors = outcome.parseResult.errors
            lastPreview = project.events
                .filter { $0.sourceFileID == outcome.sourceFileID }
                .sorted { $0.timestamp > $1.timestamp }

            message = "가져옴 \(outcome.inserted)건, 중복 \(outcome.skippedDupe)건, 제외 \(outcome.parseResult.ignoredCount)건 (\(outcome.parseResult.parserID))"
            if !outcome.parseResult.warnings.isEmpty {
                message += " / 경고 \(outcome.parseResult.warnings.count)"
            }
        } catch {
            message = "오류: \(error.localizedDescription)"
            lastErrors = [error.localizedDescription]
        }
    }
}
