import SwiftUI

struct HoldingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var busy = false
    @State private var message: String?
    @State private var byAccount = false

    var body: some View {
        Page(title: "보유 현황", subtitle: "지금 장부에 남아 있는 코인과 취득가") {
            Picker("", selection: $byAccount) {
                Text("합산").tag(false)
                Text("거래소별").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Button {
                recalculate()
            } label: {
                HStack(spacing: 5) {
                    if busy { ProgressView().controlSize(.small) }
                    Text("새로 계산")
                }
            }
            .buttonStyle(.bordered)
            .disabled(busy || env.currentProject == nil)
        } content: {
            if let message { Banner(text: message, tone: .danger, systemImage: "xmark.circle.fill") }

            if let calc = env.lastCalculation {
                summaryCard(calc)
                holdingsCard(calc)
                Text("취득가는 계정별 원가법(빗썸 이동평균 · 해외 선입선출)으로 계산한 장부 값입니다. 지금 시세가 아니라 «산 값» 이므로 평가손익과는 다릅니다.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                EmptyState(
                    systemImage: "wallet.bifold",
                    title: "아직 계산하지 않았습니다",
                    message: "가져온 거래를 재생해야 보유 수량이 나옵니다.",
                    actionTitle: "지금 계산"
                ) { recalculate() }
            }
        }
    }

    private func summaryCard(_ calc: CalculationResult) -> some View {
        let rows = calc.replay.holdings.aggregated
        let totalCost = rows.reduce(Decimal(0)) { $0 + $1.totalCostKRW }
        return Card {
            HStack(spacing: Theme.gap) {
                StatTile(label: "보유 자산", value: "\(rows.count)종")
                StatTile(label: "총 취득가", value: Fmt.krwCompact(totalCost), caption: "산 값 기준")
                StatTile(label: "기준 시점", value: Fmt.date(calc.replay.holdings.asOf), caption: "마지막 계산")
            }
        }
    }

    private func holdingsCard(_ calc: CalculationResult) -> some View {
        let rows = byAccount ? calc.replay.holdings.rows : calc.replay.holdings.aggregated
        return Card(title: byAccount ? "거래소별" : "자산 합산", systemImage: "list.bullet") {
            if rows.isEmpty {
                Text("남아 있는 코인이 없습니다.").font(Theme.body).foregroundStyle(.secondary)
            } else {
                TableHeader(columns: byAccount
                    ? [("거래소", 90, .leading), ("자산", 60, .leading), ("수량", 130, .trailing),
                       ("평균 취득단가", 130, .trailing), ("총 취득가", nil, .trailing)]
                    : [("자산", 60, .leading), ("수량", 150, .trailing),
                       ("평균 취득단가", 150, .trailing), ("총 취득가", nil, .trailing)])
                ForEach(rows, id: \.listID) { r in
                    HStack(spacing: Theme.gap) {
                        if byAccount {
                            Text(accountLabel(r)).frame(width: 90, alignment: .leading)
                            Text(r.asset.code).font(Theme.body.weight(.medium)).frame(width: 60, alignment: .leading)
                            Text(Fmt.qtyString(r.quantity)).frame(width: 130, alignment: .trailing)
                            Text(Fmt.unitPriceString(r.averageUnitKRW)).frame(width: 130, alignment: .trailing)
                        } else {
                            Text(r.asset.code).font(Theme.body.weight(.medium)).frame(width: 60, alignment: .leading)
                            Text(Fmt.qtyString(r.quantity)).frame(width: 150, alignment: .trailing)
                            Text(Fmt.unitPriceString(r.averageUnitKRW)).frame(width: 150, alignment: .trailing)
                        }
                        Text(Fmt.krwString(r.totalCostKRW))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(Theme.mono)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func accountLabel(_ r: HoldingsRow) -> String {
        guard let id = r.accountID else { return "합산" }
        return env.currentProject?.accounts.first { $0.id == id.raw }?.displayName
            ?? String(id.raw.uuidString.prefix(6))
    }

    private func recalculate() {
        guard let project = env.currentProject else { return }
        busy = true
        message = nil
        Task {
            do {
                let result = try await env.pipeline.calculate(project: project, taxYear: project.defaultTaxYear)
                env.lastCalculation = result
                env.calculationStale = false
            } catch {
                message = "계산하지 못했습니다 — \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

private extension HoldingsRow {
    var listID: String { "\(accountID?.raw.uuidString ?? "agg")-\(asset.code)" }
}
