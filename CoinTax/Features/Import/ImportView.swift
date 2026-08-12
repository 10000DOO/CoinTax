import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct ImportView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedAccountID: UUID?
    @State private var message: String?
    @State private var messageTone: Tone = .neutral
    @State private var isImporterPresented = false
    @State private var isTargeted = false
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
    @State private var showGuide = false

    var body: some View {
        Page(title: "자료 넣기", subtitle: "거래소에서 받은 파일을 그대로 넣으면 됩니다") {
            Button {
                showGuide.toggle()
            } label: {
                Label("어디서 받나요?", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showGuide) { guidePopover }
        } content: {
            if env.currentProject == nil {
                EmptyState(systemImage: "folder.badge.plus", title: "프로젝트가 없습니다",
                           message: "홈에서 프로젝트를 먼저 만드세요.",
                           actionTitle: "홈으로") { env.section = .home }
            } else {
                dropCard
                if let message { statusBanner(message) }
                if !lastErrors.isEmpty || !lastWarnings.isEmpty { issuesCard }
                if !lastPreview.isEmpty { previewCard }
                filesCard
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.commaSeparatedText, .pdf, .data, .plainText, .spreadsheet],
            allowsMultipleSelection: true
        ) { handleImport($0) }
        .sheet(isPresented: $showGenericSheet) { genericSheet }
        .sheet(isPresented: $showPDFPassword) { passwordSheet }
        .onAppear {
            if selectedAccountID == nil { selectedAccountID = env.currentProject?.accounts.first?.id }
        }
    }

    // MARK: 넣는 곳

    private var dropCard: some View {
        Card {
            HStack(spacing: Theme.gap) {
                Text("어느 거래소 자료인가요?")
                    .font(Theme.body)
                Picker("", selection: $selectedAccountID) {
                    ForEach(env.currentProject?.accounts.sorted { $0.displayName < $1.displayName } ?? [], id: \.id) { acc in
                        Text(acc.displayName).tag(Optional(acc.id))
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Toggle("직접 열 지정", isOn: $forceGeneric)
                    .toggleStyle(.checkbox)
                    .help("프리셋이 못 읽는 파일일 때 열을 손으로 연결합니다")
                    .font(Theme.caption)
            }

            dropZone

            if let account = selectedAccount, account.exchangeCode == ExchangeCode.binance.rawValue {
                binanceChecklist
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            Text(isTargeted ? "여기에 놓으세요" : "파일을 여기에 끌어다 놓으세요")
                .font(.system(size: 13, weight: .semibold))
            Text("빗썸 거래내역 확인서 PDF · 바이낸스/OKX CSV · XLSX")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Button("파일 고르기…") { isImporterPresented = true }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAccountID == nil)
            if let d = lastDetect { detectBadge(d) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius)
                .fill(isTargeted ? Color.accentColor.opacity(0.06) : Theme.subtleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Theme.hairline,
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var selectedAccount: AccountEntity? {
        env.currentProject?.accounts.first { $0.id == selectedAccountID }
    }

    // MARK: 바이낸스 3파일 안내

    private var binanceChecklist: some View {
        let names = (env.currentProject?.sourceFiles ?? []).map { $0.fileName.lowercased() + " " + $0.parserID.lowercased() }
        let spot = names.contains { $0.contains("spot") }
        let deposit = names.contains { $0.contains("deposit") }
        let withdraw = names.contains { $0.contains("withdraw") }
        return VStack(alignment: .leading, spacing: 6) {
            Text("바이낸스는 파일 3개가 다 있어야 합니다")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.gap) {
                checkItem("거래내역", spot)
                checkItem("입금내역", deposit)
                checkItem("출금내역", withdraw)
            }
            if spot && !(deposit && withdraw) {
                Text("입출금 내역이 없으면 국내에서 보낸 코인의 취득원가가 이어지지 않아 세금이 실제보다 커집니다.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func checkItem(_ label: String, _ done: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11))
                .foregroundStyle(done ? Theme.positive : Color.secondary.opacity(0.5))
            Text(label).font(Theme.caption)
                .foregroundStyle(done ? .primary : .secondary)
        }
    }

    // MARK: 결과

    private func statusBanner(_ text: String) -> some View {
        Banner(
            text: text,
            tone: messageTone,
            systemImage: messageTone == .positive ? "checkmark.circle.fill"
                : (messageTone == .danger ? "xmark.circle.fill" : "info.circle.fill")
        )
    }

    private var issuesCard: some View {
        Card(title: "확인할 점", systemImage: "exclamationmark.triangle") {
            ForEach(Array(lastErrors.prefix(20).enumerated()), id: \.offset) { _, e in
                issueLine(e, tone: .danger)
            }
            ForEach(Array(lastWarnings.prefix(20).enumerated()), id: \.offset) { _, w in
                issueLine(w, tone: .warning)
            }
            if lastErrors.count + lastWarnings.count > 40 {
                Text("외 \(lastErrors.count + lastWarnings.count - 40)건")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func issueLine(_ text: String, tone: Tone) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(tone.color).frame(width: 5, height: 5).padding(.top, 5)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewCard: some View {
        Card(title: "방금 들어온 거래 (\(lastPreview.count)건)", systemImage: "eye") {
            TableHeader(columns: [("시각", 130, .leading), ("종류", 70, .leading),
                                  ("자산", 55, .leading), ("수량", nil, .trailing)])
            ForEach(lastPreview.prefix(12), id: \.id) { e in
                HStack(spacing: Theme.gap) {
                    Text(Fmt.dateTime(e.timestamp)).frame(width: 130, alignment: .leading)
                    Text(eventLabel(e.type)).frame(width: 70, alignment: .leading)
                    Text(e.baseAsset).frame(width: 55, alignment: .leading)
                    Text(Fmt.qtyString(Decimal(string: e.quantity) ?? 0))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(Theme.mono)
                .padding(.horizontal, 10)
            }
            if lastPreview.count > 12 {
                Button("전체 보기") { env.section = .ledger }
                    .buttonStyle(.link).font(Theme.caption)
            }
        }
    }

    private var filesCard: some View {
        Card(title: "가져온 파일", systemImage: "doc.on.doc") {
            let files = (env.currentProject?.sourceFiles ?? []).sorted { $0.importedAt > $1.importedAt }
            if files.isEmpty {
                Text("아직 없습니다.").font(Theme.body).foregroundStyle(.secondary)
            } else {
                ForEach(files, id: \.id) { f in
                    HStack(spacing: Theme.gap) {
                        Image(systemName: f.format == "pdf" ? "doc.richtext" : "tablecells")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.fileName).font(Theme.body).lineLimit(1).truncationMode(.middle)
                            Text(Fmt.dateTime(f.importedAt)).font(Theme.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let excluded = Self.excludedCount(f.metaJSON), excluded > 0 {
                            Pill(text: "제외 \(excluded)", tone: .warning)
                        }
                        Pill(text: parserLabel(f.parserID), tone: .neutral)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: 안내

    private var guidePopover: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("파일 받는 곳").font(Theme.cardTitle)
            guideRow("빗썸", "고객센터 → 거래내역 확인서 → 기간 선택 후 PDF 발급")
            guideRow("바이낸스", "지갑 → 거래내역 / 입금내역 / 출금내역 각각 CSV 내려받기 (3개 모두)")
            guideRow("OKX", "자산 → 거래내역(Trading History) · 입출금내역(Funding History) CSV")
            Divider()
            Text("기간은 **처음 거래한 날부터** 잡으세요. 앞부분이 빠지면 그때 갖고 있던 코인의 취득가를 알 수 없어 세금이 커집니다.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.cardPadding)
        .frame(width: 380)
    }

    private func guideRow(_ name: String, _ how: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(name).font(Theme.caption.weight(.bold)).frame(width: 54, alignment: .leading)
            Text(how).font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func detectBadge(_ d: ImportService.DetectOutcome) -> some View {
        let conf = d.ranked.first?.score ?? 0
        Pill(
            text: "\(parserLabel(d.topParserID ?? "미인식")) \(Int(conf * 100))%",
            tone: conf >= 0.85 ? .positive : .warning,
            systemImage: conf >= 0.85 ? "checkmark" : "questionmark"
        )
    }

    private func parserLabel(_ id: String) -> String {
        switch id {
        case "bithumb-certificate-pdf-v1": return "빗썸 확인서"
        case "binance-spot-xlsx-v1": return "바이낸스 거래"
        case "binance-deposit-xlsx-v1": return "바이낸스 입금"
        case "binance-withdraw-xlsx-v1": return "바이낸스 출금"
        case "okx-trading-history-csv-v1": return "OKX 거래"
        case "okx-funding-history-csv-v1": return "OKX 입출금"
        case "generic-tabular-v1": return "직접 지정"
        default: return id
        }
    }

    private func eventLabel(_ raw: String) -> String {
        switch raw {
        case "buy": return "매수"
        case "sell": return "매도"
        case "deposit": return "입금"
        case "withdrawal": return "출금"
        case "income": return "보상"
        case "transferInternal": return "내부이동"
        case "fiatDeposit": return "원화입금"
        case "fiatWithdraw": return "원화출금"
        default: return raw
        }
    }

    // MARK: 시트

    private var genericSheet: some View {
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

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("PDF 비밀번호").font(Theme.cardTitle)
            Text("빗썸 확인서는 비밀번호가 걸려 있을 수 있습니다. 입력한 값은 저장하지 않습니다.")
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("비밀번호", text: $pdfPassword)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("취소") {
                    showPDFPassword = false
                    pdfPassword = ""
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
        .padding(Theme.cardPadding)
        .frame(width: 340)
    }

    // MARK: 동작

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard selectedAccountID != nil else {
            set("먼저 어느 거래소 자료인지 골라 주세요.", .warning)
            return
        }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ingest(url) }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard selectedAccountID != nil else { return }
        do {
            for url in try result.get() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                ingest(url)
            }
        } catch {
            set("파일을 열지 못했습니다 — \(error.localizedDescription)", .danger)
        }
    }

    private func ingest(_ url: URL) {
        do {
            lastDetect = env.importService.detect(url: url)

            if forceGeneric || lastDetect?.topParserID == "generic-tabular-v1" {
                genericHeaders = (try? env.importService.peekHeaders(url: url)) ?? []
                guard !genericHeaders.isEmpty else {
                    set("이 파일의 열 이름을 읽지 못했습니다.", .danger)
                    return
                }
                pendingURL = try Self.stageCopy(of: url)
                showGenericSheet = true
                return
            }
            if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url), doc.isLocked {
                pendingURL = try Self.stageCopy(of: url)
                showPDFPassword = true
                return
            }
            let tmp = try Self.stageCopy(of: url)
            defer { Self.discard(tmp) }
            runImport(url: tmp, forceGeneric: false, columnMap: [:])
        } catch {
            set("가져오지 못했습니다 — \(error.localizedDescription)", .danger)
            lastErrors = [error.localizedDescription]
        }
    }

    private func runImport(
        url: URL, forceGeneric: Bool, columnMap: [String: String],
        timeZone: String = "UTC", pdfPassword: String? = nil
    ) {
        guard let project = env.currentProject,
              let accID = selectedAccountID,
              let account = project.accounts.first(where: { $0.id == accID }) else { return }
        do {
            let outcome = try env.importService.importFile(
                url: url, project: project, account: account,
                forceParserID: forceGeneric ? "generic-tabular-v1" : nil,
                genericColumnMap: columnMap, genericTimeZone: timeZone, pdfPassword: pdfPassword
            )
            lastWarnings = outcome.parseResult.warnings
            lastErrors = outcome.parseResult.errors
            lastPreview = project.events
                .filter { $0.sourceFileID == outcome.sourceFileID }
                .sorted { $0.timestamp > $1.timestamp }
            if outcome.inserted > 0 { env.invalidateCalculation() }

            var parts = ["\(outcome.inserted)건 들어왔습니다"]
            if outcome.skippedDupe > 0 { parts.append("이미 있던 \(outcome.skippedDupe)건은 건너뜀") }
            if outcome.parseResult.ignoredCount > 0 { parts.append("대상 아닌 \(outcome.parseResult.ignoredCount)건 제외") }
            set(parts.joined(separator: " · "), outcome.inserted > 0 ? .positive : .neutral)
        } catch let e as CoinTaxError {
            set(e.errorDescription ?? "가져오지 못했습니다", .danger)
            lastErrors = [e.errorDescription ?? ""]
        } catch {
            set("가져오지 못했습니다 — \(error.localizedDescription)", .danger)
            lastErrors = [error.localizedDescription]
        }
    }

    private func set(_ text: String, _ tone: Tone) {
        message = text
        messageTone = tone
    }

    // MARK: - 임시 사본 관리
    //
    // 사용자가 고른 파일에는 성명·계좌·주소가 들어 있다. 작업용 사본을 임시 폴더에
    // 남겨두면 안 된다 (docs/IMPLEMENTATION.md §9 PII 최소 저장 · 리뷰 4-4).

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
        let dir = url.deletingLastPathComponent()
        if dir.lastPathComponent.hasPrefix("CoinTaxImport-") {
            try? FileManager.default.removeItem(at: dir)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
