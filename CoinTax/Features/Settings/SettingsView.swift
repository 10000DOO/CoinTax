import SwiftUI
import SwiftData

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var fxDay = "2027-01-02"
    @State private var fxRate = "1400"
    @State private var marketAsset = "USDT"
    @State private var marketPrice = "1400"
    @State private var message = ""
    @State private var remoteFX = false

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
                    Toggle("원격 환율 조회 옵트인 (기본 오프라인, v1 스텁)", isOn: $remoteFX)
                        .onChange(of: remoteFX) { _, on in
                            env.fxService.remoteOptIn = on
                        }
                    HStack {
                        TextField("날짜 yyyy-MM-dd", text: $fxDay)
                        TextField("환율", text: $fxRate)
                        Button("수동 저장") { saveFX() }
                    }
                    if let project = env.currentProject {
                        let missing = env.fxService.missingDays(
                            for: env.projectService.domainEvents(for: project),
                            project: project
                        )
                        if !missing.isEmpty {
                            Text("누락일: \(missing.joined(separator: ", "))")
                                .foregroundStyle(.orange)
                            Button("누락일 원격 채우기 (스텁)") {
                                Task { await fillRemote(days: missing, project: project) }
                            }
                            .disabled(!remoteFX)
                        }
                        ForEach(project.fxRates.sorted(by: { $0.day < $1.day }), id: \.day) { r in
                            Text("\(r.day) \(r.pair) = \(r.rate) (\(r.source))")
                        }
                    }
                    Text("거래 원본은 기기에만 저장됩니다. 원격 조회 시에도 날짜·통화쌍만 요청하는 설계입니다.")
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
    }

    private func saveFX() {
        guard let project = env.currentProject,
              let rate = Money.parseDecimal(fxRate) else { return }
        do {
            try env.fxService.setRate(day: fxDay, rate: rate, project: project)
            message = "환율 저장됨"
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

    private func fillRemote(days: [String], project: ProjectEntity) async {
        do {
            let fetched = try await env.fxService.fillMissingFromRemote(days: days, project: project)
            if fetched.isEmpty {
                message = "원격 스텁: 데이터 없음 — 수동 입력하세요"
            } else {
                message = "원격 \(fetched.count)일 저장"
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
