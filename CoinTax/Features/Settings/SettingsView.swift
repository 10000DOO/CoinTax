import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var fxDay = "2027-01-02"
    @State private var fxRate = "1400"
    @State private var marketAsset = "USDT"
    @State private var marketPrice = "1400"
    @State private var message = ""
    @State private var autoFX = FXPreferences.autoFetchEnabled
    @State private var ecosKey = FXKeychain.loadECOSKey() ?? ""
    @State private var showManual = false
    @State private var isFXCSVImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("설정")
                    .font(.largeTitle.bold())

                GroupBox("세금 계산 가정 (읽기 전용)") {
                    ForEach(TaxCopy.all, id: \.self) { t in
                        Text("• \(t)").font(.caption).padding(.bottom, 4)
                    }
                    LabeledContent("PolicyBundle", value: env.policies.id)
                }

                GroupBox("USD/KRW 환율") {
                    Toggle("자동 환율 조회 (기본 켜짐)", isOn: $autoFX)
                        .onChange(of: autoFX) { _, on in
                            env.fxService.autoFetchEnabled = on
                            FXPreferences.autoFetchEnabled = on
                        }
                    Text("계산 시 누락된 거래일 환율을 자동으로 가져옵니다. 한국은행 ECOS 키가 있으면 기준환율 계열을 우선하고, 없으면 공개 시세 폴백을 씁니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("휴일·주말 등 미고시일: 국세청 서삼46015-11986 취지에 따라 직전 고시일 기준환율을 적용하고 적용 고시일(sourceDate)을 기록합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("한국은행 ECOS API 키 (선택 · Keychain 저장)")
                            .font(.caption.weight(.semibold))
                        SecureField("ECOS 인증키", text: $ecosKey)
                        HStack {
                            Button("키 저장") {
                                FXKeychain.saveECOSKey(ecosKey)
                                message = ecosKey.isEmpty ? "ECOS 키 삭제됨 — 공개 시세 폴백" : "ECOS 키 저장됨"
                            }
                            Button("삭제", role: .destructive) {
                                ecosKey = ""
                                FXKeychain.clearECOSKey()
                                message = "ECOS 키 삭제됨"
                            }
                            Link("키 발급", destination: URL(string: "https://ecos.bok.or.kr/api/")!)
                        }
                    }

                    if let project = env.currentProject {
                        let missing = env.fxService.missingDays(
                            for: env.projectService.domainEvents(for: project),
                            project: project
                        )
                        if !missing.isEmpty {
                            Text("누락일: \(missing.joined(separator: ", "))")
                                .foregroundStyle(.orange)
                        }
                        Button("지금 자동 채우기") {
                            Task { await fillRemote(project: project) }
                        }
                        .help("누락일을 원격에서 채웁니다 (자동 설정이 꺼져 있어도 한 번 실행 가능)")

                        Button("환율 CSV import…") { isFXCSVImporter = true }

                        Button(showManual ? "수동 입력 숨기기" : "수동 입력 (옵션)") {
                            showManual.toggle()
                        }
                        .buttonStyle(.borderless)

                        if showManual {
                            HStack {
                                TextField("날짜 yyyy-MM-dd", text: $fxDay)
                                TextField("환율", text: $fxRate)
                                Button("수동 저장") { saveFX() }
                            }
                            Text("수동 값은 이후 자동 조회가 덮어쓰지 않습니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(project.fxRates.sorted(by: { $0.day < $1.day }), id: \.day) { r in
                            Text("\(r.day) \(r.pair) = \(r.rate) (\(r.source))")
                                .font(.caption.monospaced())
                        }
                    }
                    Text("거래 원본은 기기에만 저장됩니다. 원격 조회는 날짜·통화쌍만 요청합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                GroupBox("의제 시가 (2026-12-31)") {
                    HStack {
                        TextField("자산", text: $marketAsset)
                        TextField("KRW 단가", text: $marketPrice)
                        Button("저장") { saveMarket() }
                    }
                    if let project = env.currentProject {
                        ForEach(project.marketPrices, id: \.asset) { m in
                            Text("\(m.asOf) \(m.asset) = \(m.priceKRW)")
                        }
                    }
                }

                if !message.isEmpty {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .onAppear {
            autoFX = env.fxService.autoFetchEnabled
            ecosKey = FXKeychain.loadECOSKey() ?? ""
        }
        .fileImporter(
            isPresented: $isFXCSVImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importFXCSV(result)
        }
    }

    private func importFXCSV(_ result: Result<[URL], Error>) {
        guard let project = env.currentProject else { return }
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = try env.fxService.importRatesCSV(text: text, project: project)
            message = "환율 CSV \(n)일 import"
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveFX() {
        guard let project = env.currentProject,
              let rate = Money.parseDecimal(fxRate) else { return }
        do {
            try env.fxService.setRate(day: fxDay, rate: rate, project: project, source: "manual")
            message = "수동 환율 저장됨 (자동이 덮어쓰지 않음)"
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveMarket() {
        guard let project = env.currentProject,
              let price = Money.parseDecimal(marketPrice) else { return }
        if let existing = project.marketPrices.first(where: { $0.asset.uppercased() == marketAsset.uppercased() && $0.asOf == "2026-12-31" }) {
            existing.priceKRW = Money.decimalString(price)
        } else {
            let e = MarketPriceEntity(asOf: "2026-12-31", asset: marketAsset.uppercased(), priceKRW: Money.decimalString(price), source: "manual")
            e.project = project
            project.marketPrices.append(e)
            env.modelContext.insert(e)
        }
        try? env.modelContext.save()
        message = "시가 저장됨"
    }

    private func fillRemote(project: ProjectEntity) async {
        let missing = env.fxService.missingDays(
            for: env.projectService.domainEvents(for: project),
            project: project
        )
        let days = missing.isEmpty
            ? env.projectService.domainEvents(for: project).map { TaxTime.dayKST($0.timestamp) }
            : missing
        let unique = Array(Set(days)).sorted()
        do {
            let fetched = try await env.fxService.fillMissingFromRemote(days: unique, project: project, force: true)
            if fetched.isEmpty {
                message = "원격에서 채운 날짜 없음 — ECOS 키 또는 네트워크를 확인하거나 수동 입력하세요"
            } else {
                message = "자동 \(fetched.count)일 저장"
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
