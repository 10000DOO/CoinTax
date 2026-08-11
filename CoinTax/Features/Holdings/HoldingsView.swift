import SwiftUI

struct HoldingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("보유")
                    .font(.largeTitle.bold())
                Spacer()
                Button("재계산") { recalculate() }
            }

            if let calc = env.lastCalculation {
                Text("계정별 · 수량 · 평단(KRW) · 총원가")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    Section("계정별") {
                        ForEach(calc.replay.holdings.rows, id: \.listID) { r in
                            HStack {
                                Text(accountLabel(r, calc: calc))
                                    .frame(width: 100, alignment: .leading)
                                Text(r.asset.code).frame(width: 60, alignment: .leading)
                                Spacer()
                                Text(Money.decimalString(r.quantity))
                                    .frame(width: 100, alignment: .trailing)
                                Text(Money.decimalString(Money.roundKRW(r.averageUnitKRW)))
                                    .frame(width: 100, alignment: .trailing)
                                Text(Money.decimalString(Money.roundKRW(r.totalCostKRW)))
                                    .frame(width: 120, alignment: .trailing)
                            }
                            .font(.system(.body, design: .monospaced))
                        }
                    }
                    Section("합산") {
                        ForEach(calc.replay.holdings.aggregated, id: \.listID) { r in
                            HStack {
                                Text(r.asset.code)
                                Spacer()
                                Text(Money.decimalString(r.quantity))
                                Text(Money.decimalString(Money.roundKRW(r.averageUnitKRW)))
                                Text(Money.decimalString(Money.roundKRW(r.totalCostKRW)))
                            }
                            .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            } else {
                Text("재계산을 누르면 보유 현황이 표시됩니다.")
                    .foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private func accountLabel(_ r: HoldingsRow, calc: CalculationResult) -> String {
        guard let id = r.accountID else { return "합산" }
        if let name = env.currentProject?.accounts.first(where: { $0.id == id.raw })?.displayName {
            return name
        }
        return String(id.raw.uuidString.prefix(8))
    }

    private func recalculate() {
        guard let project = env.currentProject else { return }
        do {
            let result = try env.pipeline.calculate(project: project, taxYear: project.defaultTaxYear)
            env.lastCalculation = result
            message = "갱신 · 검증 \(result.verification.status)"
        } catch {
            message = error.localizedDescription
        }
    }
}

private extension HoldingsRow {
    var listID: String { "\(accountID?.raw.uuidString ?? "agg")-\(asset.code)" }
}
