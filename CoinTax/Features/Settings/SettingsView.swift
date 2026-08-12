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
    /// 화면 본문에서 계산하면 렌더링마다 전체 이벤트를 변환한다 (리뷰 6-2) → 상태로 캐시
    @State private var missingFXDays: [String] = []
    @State private var allowPublicFX = FXPreferences.allowPublicFallback
    @State private var deemedMode = DeemedPreferences.basisMode
    @State private var showECOSGuide = false

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
                    Text("계산 시 누락된 거래일 환율을 **한국은행 ECOS**에서 가져옵니다. 인증키가 없으면 자동 조회를 하지 않고 수동 입력·CSV 가져오기를 안내합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("휴일·주말 등 미고시일: 국세청 서삼46015-11986 취지에 따라 직전 고시일 기준환율을 적용하고 적용 고시일(sourceDate)을 기록합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("한국은행 ECOS 인증키 (Keychain 저장)")
                                .font(.caption.weight(.semibold))
                            if FXKeychain.loadECOSKey() == nil {
                                Text("미등록")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.25), in: Capsule())
                                    .foregroundStyle(.orange)
                            } else {
                                Text("등록됨")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.22), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        SecureField("ECOS 인증키", text: $ecosKey)
                        HStack {
                            Button("키 저장") {
                                FXKeychain.saveECOSKey(ecosKey)
                                message = ecosKey.isEmpty ? "인증키를 삭제했습니다" : "인증키를 저장했습니다"
                            }
                            Button("삭제", role: .destructive) {
                                ecosKey = ""
                                FXKeychain.clearECOSKey()
                                message = "인증키를 삭제했습니다"
                            }
                            Button(showECOSGuide ? "발급 방법 숨기기" : "발급 방법 보기") {
                                showECOSGuide.toggle()
                            }
                            .buttonStyle(.borderless)
                            Link("ECOS 열기", destination: URL(string: "https://ecos.bok.or.kr/api/")!)
                        }

                        if showECOSGuide {
                            ecosGuide
                        }
                    }

                    Divider()

                    Toggle("공식 기준환율이 없을 때 공개 시세로 대체 (권장하지 않음)", isOn: $allowPublicFX)
                        .onChange(of: allowPublicFX) { _, on in
                            FXPreferences.allowPublicFallback = on
                            message = on
                                ? "공개 시세 대체를 허용했습니다 — 사용된 날짜는 리포트에 경고로 표시됩니다"
                                : "공개 시세 대체를 끔 (한국은행 기준환율만 사용)"
                        }
                    Text("공개 시세는 외국환거래법상 기준환율이 아닙니다. 켜두면 계산은 진행되지만 리포트에 「참고 시세 사용」 경고가 남습니다. 자세한 배경은 「세무 확인」 화면의 TQ-05 항목을 보세요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let project = env.currentProject {
                        if !missingFXDays.isEmpty {
                            Text("누락일 \(missingFXDays.count)일: \(missingFXDays.prefix(12).joined(separator: ", "))\(missingFXDays.count > 12 ? " …" : "")")
                                .foregroundStyle(.orange)
                                .font(.caption)
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

                        // day 가 중복될 수 있어 복합 식별자를 쓴다 (리뷰 4-6)
                        ForEach(project.fxRates.sorted(by: { $0.day < $1.day }), id: \.persistentModelID) { r in
                            Text("\(r.day) \(r.pair) = \(r.rate) (\(r.source)\(r.sourceDate.map { $0 == r.day ? "" : " ← \($0) 고시" } ?? ""))")
                                .font(.caption.monospaced())
                        }
                    }
                    Text("거래 원본은 기기에만 저장됩니다. 원격 조회는 날짜·통화쌍만 요청합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                GroupBox("의제취득가 산정 방식") {
                    Picker("비교 단위", selection: $deemedMode) {
                        ForEach(DeemedBasisMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: deemedMode) { _, m in
                        // 설정값 한 곳만 바꾼다. 정책 번들은 PolicyBundle.current 가 매번 만든다.
                        DeemedPreferences.basisMode = m
                        env.invalidateCalculation()
                        message = "의제 산정 방식을 바꿨습니다 — 리포트에서 재계산하세요"
                    }
                    Text(deemedMode.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let alt = env.lastCalculation?.summary.deemedAlternative {
                        Divider()
                        Text("다른 방식(\(alt.basisLabel))으로 계산하면")
                            .font(.caption.weight(.semibold))
                        Text("의제 취득가 \(Money.decimalString(Money.roundKRW(alt.totalDeemedCostKRW))) 원 · 소득 \(Money.decimalString(Money.roundKRW(alt.netIncomeKRW))) 원 · 예상 세액 \(Money.decimalString(Money.roundKRW(alt.totalTaxKRW))) 원")
                            .font(.caption.monospaced())
                    }
                    Text("어느 방식이 맞는지는 세무 확인이 필요합니다 (「세무 확인」 화면 TQ-01). 기본값은 세금이 다소 커지는 보수적인 쪽입니다.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                GroupBox("의제 시가") {
                    // 마지막 계산에서 시가가 없어 막힌 자산을 먼저 보여준다 (14-spec §13)
                    if let missing = env.lastCalculation?.replay.missingMarketAssets, !missing.isEmpty {
                        Text("입력 필요: \(missing.map(\.code).joined(separator: ", "))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        HStack {
                            ForEach(missing, id: \.code) { a in
                                Button(a.code) { marketAsset = a.code }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        TextField("자산", text: $marketAsset)
                        TextField("KRW 단가", text: $marketPrice)
                        Button("저장") { saveMarket() }
                    }
                    if let project = env.currentProject {
                        ForEach(project.marketPrices.sorted(by: { $0.asset < $1.asset }), id: \.persistentModelID) { m in
                            Text("\(m.asOf) \(m.asset) = \(m.priceKRW) (\(m.source))")
                                .font(.caption.monospaced())
                        }
                    }
                    Text("법령 기준: 소득세법 시행령 제88조제2항 — 시가고시 가상자산사업자 사업장에서 **2027-01-01 0시** 공시한 가격의 평균입니다. (「2026-12-31 종가」가 아닙니다.)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("홈택스·손택스의 「가상자산 일평균가격 조회」로 값을 확인할 수 있습니다. 어느 거래소가 시가고시 사업자인지, 국내 미상장 코인은 어떻게 하는지는 세무 확인 항목(TQ-10)입니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !message.isEmpty {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .onAppear {
            autoFX = env.fxService.autoFetchEnabled
            allowPublicFX = FXPreferences.allowPublicFallback
            deemedMode = DeemedPreferences.basisMode
            ecosKey = FXKeychain.loadECOSKey() ?? ""
            refreshMissingFX()
        }
        .fileImporter(
            isPresented: $isFXCSVImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importFXCSV(result)
        }
    }

    /// 한국은행 ECOS 인증키 발급 안내 (TQ-05)
    @ViewBuilder
    private var ecosGuide: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("발급 방법 (무료 · 보통 즉시 발급)")
                .font(.caption.weight(.semibold))
            Group {
                Text("1. ecos.bok.or.kr 접속 → 상단 **오픈API** 메뉴")
                Text("2. **인증키 신청** 선택")
                Text("3. 이메일 주소와 사용 용도(예: 개인 세무 자료 정리)를 입력하고 신청")
                Text("4. 메일로 받은 인증키를 위 칸에 붙여넣고 **키 저장**")
                Text("5. 「지금 자동 채우기」를 눌러 정상 조회되는지 확인")
            }
            .font(.caption2)
            Text("앱이 보내는 것은 날짜와 통화쌍뿐입니다. 거래 내역은 전송하지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("사용 통계표: 731Y001 (주요국 통화의 대원화 환율) · 항목 0000001 (원/미국달러) · 주기 일별")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("메뉴 이름은 사이트 개편에 따라 달라질 수 있습니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func refreshMissingFX() {
        guard let project = env.currentProject else {
            missingFXDays = []
            return
        }
        missingFXDays = env.fxService.missingDays(
            for: env.projectService.domainEvents(for: project),
            project: project
        )
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
            refreshMissingFX()
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
            refreshMissingFX()
            message = "수동 환율 저장됨 (자동이 덮어쓰지 않음)"
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
            message = "자산 코드를 입력하세요"
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
        message = "시가 저장됨"
    }

    private func fillRemote(project: ProjectEntity) async {
        let missing = env.fxService.missingDays(
            for: env.projectService.domainEvents(for: project),
            project: project
        )
        // 누락일이 없을 때 전체 거래일을 요청하면 수백~수천 번의 요청이 나간다 (리뷰 6-3)
        let unique = Array(Set(missing)).sorted()
        guard !unique.isEmpty else {
            message = "채울 누락일이 없습니다"
            return
        }
        do {
            let fetched = try await env.fxService.fillMissingFromRemote(days: unique, project: project, force: true)
            if fetched.isEmpty {
                message = "원격에서 채운 날짜 없음 — ECOS 키 또는 네트워크를 확인하거나 수동 입력하세요"
            } else {
                message = "자동 \(fetched.count)일 저장"
            }
            refreshMissingFX()
        } catch {
            message = error.localizedDescription
        }
    }
}
