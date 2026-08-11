import SwiftUI

struct HoldingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("보유")
                .font(.largeTitle.bold())
            if let calc = env.lastCalculation {
                List(calc.replay.holdings.rows, id: \.listID) { r in
                    HStack {
                        Text(r.accountID.map { String($0.raw.uuidString.prefix(8)) } ?? "-")
                        Text(r.asset.code)
                        Spacer()
                        Text(Money.decimalString(r.quantity))
                        Text(Money.decimalString(Money.roundKRW(r.averageUnitKRW)))
                        Text(Money.decimalString(Money.roundKRW(r.totalCostKRW)))
                    }
                }
            } else {
                Text("리포트에서 계산을 실행하면 보유 현황이 표시됩니다.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}

private extension HoldingsRow {
    var listID: String { "\(accountID?.raw.uuidString ?? "agg")-\(asset.code)" }
}
