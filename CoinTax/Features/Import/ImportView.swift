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
    /// 시트(제네릭 매핑·PDF 비밀번호)를 거쳐 돌아왔을 때 넣을 계정.
    /// 자동 구분이면 파일마다 다를 수 있으므로 화면 선택값을 다시 읽으면 안 된다.
    @State private var pendingAccountID: UUID?
    @State private var batchLines: [String] = []
    @State private var batchTone: Tone = .neutral
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
            allowedContentTypes: [.folder, .commaSeparatedText, .pdf, .data, .plainText, .spreadsheet],
            allowsMultipleSelection: true
        ) { handleImport($0) }
        .sheet(isPresented: $showGenericSheet) { genericSheet }
        .sheet(isPresented: $showPDFPassword) { passwordSheet }
        // 기본값은 「자동으로 구분」(nil). 계정을 미리 골라 두면 여러 거래소 파일이
        // 한 계정으로 몰려 원가법이 뒤바뀌고 거래소 간 전송이 사라진다.
    }

    // MARK: 넣는 곳

    private var dropCard: some View {
        Card {
            HStack(spacing: Theme.gap) {
                Text("거래소 구분")
                    .font(Theme.body)
                Picker("", selection: $selectedAccountID) {
                    Text("자동으로 구분").tag(UUID?.none)
                    // 개인지갑은 거래소 파일을 넣는 곳이 아니다 — 「전송 연결」에서 출금을 지정해 채운다
                    ForEach(importableAccounts, id: \.id) { acc in
                        Text(acc.displayName).tag(Optional(acc.id))
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .help("자동으로 구분하면 파일 내용을 보고 빗썸·바이낸스·OKX 계정에 알아서 나눠 담습니다")
                Spacer()
                Toggle("직접 열 지정", isOn: $forceGeneric)
                    .toggleStyle(.checkbox)
                    .help("프리셋이 못 읽는 파일일 때 열을 손으로 연결합니다")
                    .font(Theme.caption)
            }

            if selectedAccountID == nil {
                Text("여러 거래소 파일을 한꺼번에 넣어도 됩니다 — 파일 내용을 보고 거래소를 구분해 각 계정으로 나눠 담습니다.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            dropZone

            if selectedAccountID == nil || selectedAccount?.exchangeCode == ExchangeCode.binance.rawValue {
                binanceChecklist
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            Text(isTargeted ? "여기에 놓으세요" : "파일이나 폴더를 여기에 끌어다 놓으세요")
                .font(.system(size: 13, weight: .semibold))
            Text("빗썸 확인서 PDF · 바이낸스/OKX CSV · XLSX — 폴더를 넣으면 하위 파일까지 모두 찾습니다")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Button("파일·폴더 고르기…") { isImporterPresented = true }
                .buttonStyle(.borderedProminent)
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

    /// 파일을 넣을 수 있는 계정. 개인지갑은 거래소 export 가 없으므로 제외한다.
    private var importableAccounts: [AccountEntity] {
        (env.currentProject?.accounts ?? [])
            .filter { $0.exchangeCode != ExchangeCode.wallet.rawValue }
            .sorted { $0.displayName < $1.displayName }
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
                if let url = pendingURL, let accID = pendingAccountID {
                    runImport(url: url, accountID: accID, forceGeneric: true, columnMap: map, timeZone: tz)
                    Self.discard(url)
                }
                pendingURL = nil
                pendingAccountID = nil
            },
            onCancel: {
                showGenericSheet = false
                if let url = pendingURL { Self.discard(url) }
                pendingURL = nil
                pendingAccountID = nil
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
                    pendingAccountID = nil
                }
                Button("열기") {
                    showPDFPassword = false
                    if let url = pendingURL, let accID = pendingAccountID {
                        runImport(url: url, accountID: accID, forceGeneric: false, columnMap: [:], pdfPassword: pdfPassword)
                        Self.discard(url)
                    }
                    pdfPassword = ""
                    pendingURL = nil
                    pendingAccountID = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.cardPadding)
        .frame(width: 340)
    }

    // MARK: 동작

    private func handleDrop(_ providers: [NSItemProvider]) {
        startBatch()
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ingest(url) }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        startBatch()
        do {
            for url in try result.get() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                ingest(url)
            }
        } catch {
            append("파일을 열지 못했습니다 — \(error.localizedDescription)", .danger)
        }
    }

    /// 한 번에 여러 파일을 넣으므로 결과를 파일별로 쌓는다.
    /// 마지막 파일 결과만 남기면 「어느 파일이 어디로 들어갔는지」를 알 수 없다.
    private func startBatch() {
        batchLines = []
        batchTone = .neutral
        lastWarnings = []
        lastErrors = []
        lastPreview = []
    }

    /// 이 파일을 넣을 계정. 자동 구분이면 파일 내용으로 정하고, 없으면 계정을 만든다.
    private func resolvedAccount(for url: URL, project: ProjectEntity) throws -> AccountEntity? {
        if let accID = selectedAccountID {
            return project.accounts.first { $0.id == accID }
        }
        guard let resolved = try env.importService.resolveAccount(url: url, project: project) else {
            return nil
        }
        return resolved.account
    }

    /// 파일이면 그대로, 폴더면 그 아래 파일을 모두 넣는다.
    private func ingest(_ url: URL) {
        let files = ImportService.expandToImportableFiles(url)
        guard !files.isEmpty else {
            append("\(url.lastPathComponent): 넣을 파일이 없습니다 (csv · xlsx · pdf)", .warning)
            return
        }
        for file in files { ingestFile(file) }
    }

    private func ingestFile(_ url: URL) {
        guard let project = env.currentProject else { return }
        do {
            lastDetect = env.importService.detect(url: url)
            let name = url.lastPathComponent

            guard let account = try resolvedAccount(for: url, project: project) else {
                append("\(name): 어느 거래소 자료인지 알 수 없습니다 — 위에서 거래소를 직접 고른 뒤 다시 넣어 주세요", .warning)
                return
            }

            // 열 지정·비밀번호 시트는 한 번에 하나만 뜬다. 폴더째 넣을 때 뒤 파일이 앞 파일의
            // 대기 상태를 덮어쓰면 앞 파일이 말없이 빠지므로, 건너뛴 사실을 알린다.
            if forceGeneric || lastDetect?.topParserID == "generic-tabular-v1" {
                guard pendingURL == nil else {
                    append("\(name): 열을 직접 지정해야 해서 건너뛰었습니다 — 이 파일만 따로 넣어 주세요", .warning)
                    return
                }
                genericHeaders = (try? env.importService.peekHeaders(url: url)) ?? []
                guard !genericHeaders.isEmpty else {
                    append("\(name): 열 이름을 읽지 못했습니다", .danger)
                    return
                }
                pendingURL = try Self.stageCopy(of: url)
                pendingAccountID = account.id
                showGenericSheet = true
                return
            }
            if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url), doc.isLocked {
                guard pendingURL == nil else {
                    append("\(name): 비밀번호를 물어봐야 해서 건너뛰었습니다 — 이 파일만 따로 넣어 주세요", .warning)
                    return
                }
                pendingURL = try Self.stageCopy(of: url)
                pendingAccountID = account.id
                showPDFPassword = true
                return
            }
            let tmp = try Self.stageCopy(of: url)
            defer { Self.discard(tmp) }
            runImport(url: tmp, accountID: account.id, forceGeneric: false, columnMap: [:])
        } catch {
            append("\(url.lastPathComponent): 가져오지 못했습니다 — \(error.localizedDescription)", .danger)
            lastErrors.append(error.localizedDescription)
        }
    }

    private func runImport(
        url: URL, accountID: UUID, forceGeneric: Bool, columnMap: [String: String],
        timeZone: String = "UTC", pdfPassword: String? = nil
    ) {
        guard let project = env.currentProject,
              let account = project.accounts.first(where: { $0.id == accountID }) else { return }
        do {
            let outcome = try env.importService.importFile(
                url: url, project: project, account: account,
                forceParserID: forceGeneric ? "generic-tabular-v1" : nil,
                genericColumnMap: columnMap, genericTimeZone: timeZone, pdfPassword: pdfPassword
            )
            lastWarnings.append(contentsOf: outcome.parseResult.warnings)
            lastErrors.append(contentsOf: outcome.parseResult.errors)
            lastPreview.append(contentsOf: project.events
                .filter { $0.sourceFileID == outcome.sourceFileID }
                .sorted { $0.timestamp > $1.timestamp })
            if outcome.inserted > 0 { env.invalidateCalculation() }

            var parts = ["\(account.displayName) ← \(outcome.inserted)건"]
            if outcome.skippedDupe > 0 { parts.append("이미 있던 \(outcome.skippedDupe)건은 건너뜀") }
            if outcome.parseResult.ignoredCount > 0 { parts.append("대상 아닌 \(outcome.parseResult.ignoredCount)건 제외") }
            append(parts.joined(separator: " · "), outcome.inserted > 0 ? .positive : .neutral)
        } catch let e as CoinTaxError {
            append("\(account.displayName): \(e.errorDescription ?? "가져오지 못했습니다")", .danger)
            lastErrors.append(e.errorDescription ?? "")
        } catch {
            append("\(account.displayName): 가져오지 못했습니다 — \(error.localizedDescription)", .danger)
            lastErrors.append(error.localizedDescription)
        }
    }

    /// 파일 한 건의 결과를 배너에 덧붙인다. 배너 색은 가장 나쁜 결과를 따른다.
    private func append(_ text: String, _ tone: Tone) {
        batchLines.append(text)
        if tone == .danger || (tone == .warning && batchTone != .danger) {
            batchTone = tone
        } else if batchTone == .neutral {
            batchTone = tone
        }
        message = batchLines.joined(separator: "\n")
        messageTone = batchTone
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
