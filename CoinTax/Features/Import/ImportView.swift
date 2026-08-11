import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedAccountID: UUID?
    @State private var message: String = ""
    @State private var isImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import")
                .font(.largeTitle.bold())
            if let project = env.currentProject {
                Picker("계정", selection: $selectedAccountID) {
                    Text("선택").tag(Optional<UUID>.none)
                    ForEach(project.accounts, id: \.id) { acc in
                        Text(acc.displayName).tag(Optional(acc.id))
                    }
                }
                .frame(maxWidth: 320)
                Button("파일 추가…") { isImporterPresented = true }
                    .disabled(selectedAccountID == nil)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                GroupBox("원본 파일") {
                    if project.sourceFiles.isEmpty {
                        Text("아직 import한 파일이 없습니다.")
                    } else {
                        ForEach(project.sourceFiles, id: \.id) { f in
                            HStack {
                                Text(f.fileName)
                                Spacer()
                                Text(f.parserID).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding()
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.commaSeparatedText, .pdf, .data, .plainText, .spreadsheet],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .onAppear {
            selectedAccountID = env.currentProject?.accounts.first?.id
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
            let outcome = try env.importService.importFile(url: url, project: project, account: account)
            message = "가져옴 \(outcome.inserted)건, 중복 \(outcome.skippedDupe)건 (\(outcome.parseResult.parserID))"
            if !outcome.parseResult.warnings.isEmpty {
                message += " / 경고 \(outcome.parseResult.warnings.count)"
            }
        } catch {
            message = "오류: \(error.localizedDescription)"
        }
    }
}
