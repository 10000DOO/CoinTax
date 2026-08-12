import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct ImportView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedAccountID: UUID?
    @State private var message: String = ""
    @State private var isImporterPresented = false
    @State private var lastDetect: ImportService.DetectOutcome?
    @State private var lastPreview: [LedgerEventEntity] = []
    @State private var lastWarnings: [String] = []
    @State private var lastErrors: [String] = []
    @State private var forceGeneric = false
    @State private var pendingURL: URL?
    @State private var genericHeaders: [String] = []
    @State private var showGenericSheet = false
    @State private var pdfPassword = ""
    @State private var showPDFPassword = false
    @State private var genericTimeZone = "UTC"

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

                    Toggle("제네릭 표 매핑으로 강제 (프리셋 무시)", isOn: $forceGeneric)

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
                        GroupBox("이슈 (행/사유)") {
                            ForEach(lastErrors, id: \.self) { e in
                                Text("오류: \(e)").foregroundStyle(.red).font(.caption)
                            }
                            ForEach(lastWarnings, id: \.self) { w in
                                Text("경고: \(w)").foregroundStyle(.orange).font(.caption)
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
                                    if let excluded = Self.excludedCount(f.metaJSON), excluded > 0 {
                                        Text("제외 \(excluded)건")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
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
        .sheet(isPresented: $showGenericSheet) {
            GenericMappingSheet(
                headers: genericHeaders,
                onConfirm: { map, tz in
                    showGenericSheet = false
                    genericTimeZone = tz
                    if let url = pendingURL {
                        runImport(url: url, forceGeneric: true, columnMap: map, timeZone: tz)
                        Self.discard(url)
                    }
                    pendingURL = nil
                },
                onCancel: {
                    showGenericSheet = false
                    if let url = pendingURL { Self.discard(url) }
                    pendingURL = nil
                }
            )
        }
        .sheet(isPresented: $showPDFPassword) {
            VStack(spacing: 12) {
                Text("PDF 비밀번호").font(.headline)
                SecureField("비밀번호", text: $pdfPassword)
                HStack {
                    Button("취소") {
                        showPDFPassword = false
                        pdfPassword = ""   // 비밀번호를 화면 상태에 남기지 않는다
                        if let url = pendingURL { Self.discard(url) }
                        pendingURL = nil
                    }
                    Button("열기") {
                        showPDFPassword = false
                        if let url = pendingURL {
                            runImport(url: url, forceGeneric: false, columnMap: [:], pdfPassword: pdfPassword)
                            Self.discard(url)
                        }
                        pdfPassword = ""
                        pendingURL = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 320)
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
            if spot && !deposit {
                Text("Spot only — 전송 매칭을 위해 Deposit History가 필요합니다.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard selectedAccountID != nil else { return }
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            lastDetect = env.importService.detect(url: url)

            if forceGeneric || (lastDetect?.topParserID == "generic-tabular-v1") {
                genericHeaders = (try? env.importService.peekHeaders(url: url)) ?? []
                if genericHeaders.isEmpty {
                    message = "헤더를 읽지 못했습니다"
                    return
                }
                pendingURL = try Self.stageCopy(of: url)
                showGenericSheet = true
                return
            }

            if url.pathExtension.lowercased() == "pdf",
               let doc = PDFDocument(url: url), doc.isLocked {
                pendingURL = try Self.stageCopy(of: url)
                showPDFPassword = true
                return
            }

            let tmp = try Self.stageCopy(of: url)
            defer { Self.discard(tmp) }
            runImport(url: tmp, forceGeneric: false, columnMap: [:])
        } catch {
            message = "오류: \(error.localizedDescription)"
            lastErrors = [error.localizedDescription]
        }
    }

    private func runImport(
        url: URL,
        forceGeneric: Bool,
        columnMap: [String: String],
        timeZone: String = "UTC",
        pdfPassword: String? = nil
    ) {
        guard let project = env.currentProject,
              let accID = selectedAccountID,
              let account = project.accounts.first(where: { $0.id == accID }) else { return }
        do {
            let outcome = try env.importService.importFile(
                url: url,
                project: project,
                account: account,
                forceParserID: forceGeneric ? "generic-tabular-v1" : nil,
                genericColumnMap: columnMap,
                genericTimeZone: timeZone,
                pdfPassword: pdfPassword
            )
            lastWarnings = outcome.parseResult.warnings
            lastErrors = outcome.parseResult.errors
            lastPreview = project.events
                .filter { $0.sourceFileID == outcome.sourceFileID }
                .sorted { $0.timestamp > $1.timestamp }
            if outcome.inserted > 0 { env.invalidateCalculation() }
            message = "가져옴 \(outcome.inserted)건, 중복 \(outcome.skippedDupe)건, 제외 \(outcome.parseResult.ignoredCount)건 (\(outcome.parseResult.parserID))"
        } catch {
            message = "오류: \(error.localizedDescription)"
            lastErrors = [error.localizedDescription]
        }
    }

    // MARK: - 임시 사본 관리
    //
    // 사용자가 고른 파일에는 성명·계좌·주소가 들어 있다. 작업용 사본을 임시 폴더에
    // 남겨두면 안 된다 (docs/IMPLEMENTATION.md §9 PII 최소 저장 · 리뷰 4-4).

    /// F-CB-06 「선물 등 제외 N건」을 파일 목록에 지속 노출
    private static func excludedCount(_ metaJSON: String) -> Int? {
        guard let data = metaJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let raw = obj["ignoredCount"] else { return nil }
        return Int(raw)
    }

    private static func stageCopy(of url: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoinTaxImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    private static func discard(_ url: URL) {
        // 사본이 담긴 전용 폴더째로 지운다
        let dir = url.deletingLastPathComponent()
        if dir.lastPathComponent.hasPrefix("CoinTaxImport-") {
            try? FileManager.default.removeItem(at: dir)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
