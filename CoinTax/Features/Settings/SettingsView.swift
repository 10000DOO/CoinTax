import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    // 환율
    @State private var autoFetch = FXPreferences.autoFetchEnabled
    @State private var allowPublic = FXPreferences.allowPublicFallback
    @State private var ecosKeyInput = ""
    @State private var savedKeyMask: String? = FXKeychain.maskedECOSKey()
    @State private var keyMessage: String?
    @State private var keyMessageTone: Tone = .neutral
    @State private var showKeyEditor = false
    @State private var showECOSGuide = false
    @State private var testing = false

    @State private var missingFXDays: [String] = []
    @State private var fxDay = ""
    @State private var fxRate = ""
    @State private var showFXImporter = false

    // 시가
    @State private var marketAsset = ""
    @State private var marketPrice = ""
    @State private var missingMarket: [String] = []

    // 의제 방식
    @State private var deemedMode = DeemedPreferences.basisMode

    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Page(title: "설정", subtitle: "환율과 시가를 채우면 계산이 완성됩니다") {
        } content: {
            if let message { Banner(text: message, tone: .neutral, systemImage: "info.circle.fill") }
            exchangeRateCard
            marketPriceCard
            deemedModeCard
            privacyCard
        }
        .onAppear { refresh() }
        .fileImporter(isPresented: $showFXImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText],
                      allowsMultipleSelection: false) { importFXCSV($0) }
    }

    // MARK: - 환율

    private var exchangeRateCard: some View {
        Card(
            title: "환율",
            systemImage: "dollarsign.arrow.circlepath",
            footnote: "해외 거래소 거래는 그날의 원/달러 기준환율로 원화 환산합니다. 앱이 보내는 건 날짜와 통화쌍뿐이고 거래 내역은 나가지 않습니다."
        ) {
            HStack {
                statusDot(missingFXDays.isEmpty ? .positive : .warning)
                Text(missingFXDays.isEmpty ? "필요한 환율이 모두 있습니다" : "\(missingFXDays.count)일 부족")
                    .font(Theme.body)
                Spacer()
                if !missingFXDays.isEmpty {
                    Button {
                        Task { await fillRemote() }
                    } label: {
                        HStack(spacing: 5) {
                            if busy { ProgressView().controlSize(.small) }
                            Text("자동으로 채우기")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || env.currentProject == nil)
                }
            }

            if !missingFXDays.isEmpty {
                Text(missingFXDays.prefix(14).joined(separator: "  ") + (missingFXDays.count > 14 ? "  외 \(missingFXDays.count - 14)일" : ""))
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: 6))
            }

            Divider()
            ecosKeySection
            Divider()

            DisclosureGroup("직접 넣기") {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    HStack {
                        TextField("2027-05-04", text: $fxDay).frame(width: 110)
                        TextField("1380.5", text: $fxRate).frame(width: 90)
                        Button("추가") { saveFX() }
                            .disabled(fxDay.count < 8 || fxRate.isEmpty)
                        Spacer()
                        Button("CSV 가져오기…") { showFXImporter = true }
                    }
                    .textFieldStyle(.roundedBorder)
                    Text("CSV 는 `날짜, 환율` 두 열이면 됩니다. 직접 넣은 값은 자동 조회가 덮어쓰지 않습니다.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .font(Theme.body)

            Toggle("계산할 때 자동으로 받아오기", isOn: $autoFetch)
                .toggleStyle(.switch)
                .font(Theme.body)
                .onChange(of: autoFetch) { _, v in FXPreferences.autoFetchEnabled = v }
        }
    }

    private var ecosKeySection: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack(spacing: 8) {
                Image(systemName: savedKeyMask == nil ? "key" : "key.fill")
                    .foregroundStyle(savedKeyMask == nil ? .secondary : Theme.positive)
                VStack(alignment: .leading, spacing: 1) {
                    Text("한국은행 ECOS 인증키").font(Theme.body.weight(.medium))
                    if let mask = savedKeyMask {
                        HStack(spacing: 5) {
                            Text(mask).font(Theme.mono)
                            Pill(text: "이 Mac 에만 · 암호화 저장", tone: .positive, systemImage: "lock.fill")
                        }
                    } else {
                        Text("등록하면 누락된 환율을 자동으로 받아옵니다. 한 번만 넣으면 다음부터 기억합니다.")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if savedKeyMask != nil {
                    Button(testing ? "확인 중…" : "연결 확인") { Task { await testKey() } }
                        .buttonStyle(.bordered).controlSize(.small).disabled(testing)
                    Button("변경") { showKeyEditor = true; ecosKeyInput = "" }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("삭제", role: .destructive) { clearKey() }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("인증키 등록") { showKeyEditor = true; ecosKeyInput = "" }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }

            if showKeyEditor {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("발급받은 인증키를 붙여넣으세요", text: $ecosKeyInput)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button(showECOSGuide ? "발급 방법 접기" : "발급 방법 보기") { showECOSGuide.toggle() }
                            .buttonStyle(.link).font(Theme.caption)
                        Link("ecos.bok.or.kr 열기", destination: URL(string: "https://ecos.bok.or.kr/api/")!)
                            .font(Theme.caption)
                        Spacer()
                        Button("취소") { showKeyEditor = false; ecosKeyInput = "" }
                        Button("저장") { saveKey() }
                            .buttonStyle(.borderedProminent)
                            .disabled(ecosKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
                .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }

            if showECOSGuide { ecosGuide }

            if let keyMessage {
                HStack(spacing: 5) {
                    Image(systemName: keyMessageTone == .danger ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(keyMessageTone.color)
                    Text(keyMessage).font(Theme.caption).foregroundStyle(keyMessageTone.color)
                }
            }

            Toggle("인증키가 없을 때 공개 시세로 대신 채우기", isOn: $allowPublic)
                .toggleStyle(.checkbox)
                .font(Theme.caption)
                .onChange(of: allowPublic) { _, v in FXPreferences.allowPublicFallback = v }
            Text("공개 시세는 외국환거래법상 기준환율이 아닙니다. 쓰면 리포트에 표시됩니다 (세무 확인 TQ-05).")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private var ecosGuide: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("인증키 발급 (무료 · 1분)").font(Theme.caption.weight(.semibold))
            guideStep(1, "ecos.bok.or.kr 접속 → 상단 **오픈API**")
            guideStep(2, "**인증키 신청** 선택")
            guideStep(3, "이메일과 사용 용도(예: 개인 세무 자료 정리) 입력 후 신청")
            guideStep(4, "메일로 받은 키를 위 칸에 붙여넣고 **저장**")
            guideStep(5, "**연결 확인** 을 눌러 정상 조회되는지 확인")
            Text("사용 통계표 731Y001 · 항목 0000001 (원/미국달러) · 일별. 메뉴 이름은 사이트 개편에 따라 달라질 수 있습니다.")
                .font(Theme.caption).foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private func guideStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(n)")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 14, height: 14)
                .background(Color.secondary.opacity(0.18), in: Circle())
            Text(.init(text)).font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 2026-12-31 시가

    private var marketPriceCard: some View {
        Card(
            title: "2026-12-31 시가",
            systemImage: "clock.arrow.circlepath",
            footnote: "과세는 2027-01-01 양도분부터입니다. 그 전부터 갖고 있던 코인은 «실제 산 값» 과 «이 시가» 중 큰 쪽을 취득가로 봅니다. 홈택스·손택스 「가상자산 일평균가격 조회」에서 확인할 수 있습니다."
        ) {
            HStack {
                statusDot(missingMarket.isEmpty ? .positive : .warning)
                Text(missingMarket.isEmpty ? "필요한 시가가 모두 있습니다" : "\(missingMarket.count)종 필요")
                    .font(Theme.body)
                Spacer()
            }

            if !missingMarket.isEmpty {
                HStack(spacing: 6) {
                    ForEach(missingMarket.prefix(10), id: \.self) { code in
                        Button(code) { marketAsset = code }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            HStack {
                TextField("자산 (BTC)", text: $marketAsset).frame(width: 110)
                TextField("원 단위 가격", text: $marketPrice).frame(width: 130)
                Button("저장") { saveMarket() }
                    .disabled(marketAsset.isEmpty || marketPrice.isEmpty)
                Spacer()
            }
            .textFieldStyle(.roundedBorder)

            let saved = (env.currentProject?.marketPrices ?? []).filter { $0.asOf == "2026-12-31" }
            if !saved.isEmpty {
                Divider()
                ForEach(saved.sorted { $0.asset < $1.asset }, id: \.id) { m in
                    HStack {
                        Text(m.asset).font(Theme.mono).frame(width: 70, alignment: .leading)
                        Text(Fmt.unitPriceString(Decimal(string: m.priceKRW) ?? 0)).font(Theme.mono)
                        Spacer()
                        Button {
                            env.modelContext.delete(m)
                            try? env.modelContext.save()
                            refresh()
                        } label: { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 의제 방식

    private var deemedModeCard: some View {
        Card(
            title: "과세 시작 전 보유분 계산 방식",
            systemImage: "arrow.triangle.branch",
            footnote: "법령·국세청 안내에 어느 쪽인지 명시가 없습니다. 두 방식 결과를 리포트에 함께 보여줍니다 (세무 확인 TQ-01)."
        ) {
            Picker("", selection: $deemedMode) {
                ForEach(DeemedBasisMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: deemedMode) { _, v in
                DeemedPreferences.basisMode = v
                env.invalidateCalculation()
            }
            Text(deemedMode.detail)
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 개인정보

    private var privacyCard: some View {
        Card(title: "개인정보", systemImage: "lock.shield") {
            privacyRow("거래 자료는 이 Mac 에만 저장됩니다", "서버로 보내지 않습니다.")
            privacyRow("네트워크는 환율 조회에만 씁니다", "날짜와 통화쌍만 보냅니다.")
            privacyRow("인증키는 키체인에 암호화 보관", "이 Mac 밖으로 백업·동기화되지 않습니다.")
            privacyRow("가져온 파일의 작업용 사본은 즉시 삭제", "성명·계좌·지갑주소가 남지 않습니다.")
        }
    }

    private func privacyRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.positive).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body)
                Text(detail).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func statusDot(_ tone: Tone) -> some View {
        Circle().fill(tone.color).frame(width: 7, height: 7)
    }

    // MARK: - 동작

    private func refresh() {
        autoFetch = FXPreferences.autoFetchEnabled
        allowPublic = FXPreferences.allowPublicFallback
        savedKeyMask = FXKeychain.maskedECOSKey()
        deemedMode = DeemedPreferences.basisMode
        let progress = SetupProgress.evaluate(env: env)
        missingFXDays = progress.missingFXDays
        missingMarket = progress.missingMarketAssets
    }

    private func saveKey() {
        let result = FXKeychain.saveECOSKey(ecosKeyInput)
        ecosKeyInput = ""
        savedKeyMask = FXKeychain.maskedECOSKey()
        keyMessage = result.message
        keyMessageTone = result.isFailure ? .danger : .positive
        if !result.isFailure {
            showKeyEditor = false
            showECOSGuide = false
        }
    }

    private func clearKey() {
        let result = FXKeychain.clearECOSKey()
        savedKeyMask = nil
        keyMessage = result.message
        keyMessageTone = .neutral
    }

    /// 실제로 한 번 조회해 본다. 「저장됨」만으로는 키가 유효한지 알 수 없다.
    private func testKey() async {
        testing = true
        defer { testing = false }
        guard let key = FXKeychain.loadECOSKey() else { return }
        let day = TaxTime.dayKST(Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        do {
            let rates = try await ECOSFXClient(apiKey: key).fetchUSD_KRW(days: [day])
            if rates.isEmpty {
                keyMessage = "키가 거부되었거나 조회 결과가 없습니다. 발급 메일의 키를 다시 확인하세요."
                keyMessageTone = .danger
            } else {
                keyMessage = "정상 조회됩니다 (\(rates.count)일)."
                keyMessageTone = .positive
            }
        } catch {
            keyMessage = "조회하지 못했습니다 — \(error.localizedDescription)"
            keyMessageTone = .danger
        }
    }

    private func importFXCSV(_ result: Result<[URL], Error>) {
        guard let project = env.currentProject else { return }
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = try env.fxService.importRatesCSV(text: text, project: project)
            refresh()
            env.invalidateCalculation()
            message = "환율 \(n)일을 가져왔습니다."
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveFX() {
        guard let project = env.currentProject,
              let rate = Money.parseDecimal(fxRate) else { return }
        do {
            try env.fxService.setRate(day: fxDay, rate: rate, project: project, source: "manual")
            fxDay = ""; fxRate = ""
            refresh()
            env.invalidateCalculation()
            message = "환율을 저장했습니다. 자동 조회가 덮어쓰지 않습니다."
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveMarket() {
        guard let project = env.currentProject,
              let price = Money.parseDecimal(marketPrice) else { return }
        // 장부 키와 같은 정규화를 거친다 (공백·별칭 티커 불일치 방지)
        let code = AssetSymbol(marketAsset).code
        guard !code.isEmpty else {
            message = "자산 코드를 입력하세요."
            return
        }
        if let existing = project.marketPrices.first(where: { AssetSymbol($0.asset).code == code && $0.asOf == "2026-12-31" }) {
            existing.priceKRW = Money.decimalString(price)
        } else {
            let e = MarketPriceEntity(asOf: "2026-12-31", asset: code, priceKRW: Money.decimalString(price), source: "manual")
            e.project = project
            project.marketPrices.append(e)
            env.modelContext.insert(e)
        }
        try? env.modelContext.save()
        marketAsset = ""; marketPrice = ""
        env.invalidateCalculation()
        refresh()
        message = "\(code) 시가를 저장했습니다."
    }

    private func fillRemote() async {
        guard let project = env.currentProject else { return }
        busy = true
        defer { busy = false }
        // 누락일이 없을 때 전체 거래일을 요청하면 수백~수천 번의 요청이 나간다 (리뷰 6-3)
        let unique = Array(Set(missingFXDays)).sorted()
        guard !unique.isEmpty else {
            message = "채울 날짜가 없습니다."
            return
        }
        do {
            let fetched = try await env.fxService.fillMissingFromRemote(days: unique, project: project, force: true)
            if fetched.isEmpty {
                message = FXKeychain.loadECOSKey() == nil
                    ? "받아오지 못했습니다 — 한국은행 인증키를 등록하거나 직접 넣어 주세요."
                    : "받아오지 못했습니다 — 인증키나 네트워크를 확인하세요."
            } else {
                message = "환율 \(fetched.count)일을 받아왔습니다."
                env.invalidateCalculation()
            }
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }
}
