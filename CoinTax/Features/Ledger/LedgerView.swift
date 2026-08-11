import SwiftUI

struct LedgerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var filterType: String = "전체"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("거래내역")
                .font(.largeTitle.bold())
            Picker("유형", selection: $filterType) {
                Text("전체").tag("전체")
                ForEach(["buy","sell","deposit","withdrawal","income","transferInternal"], id: \.self) {
                    Text($0).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            if let project = env.currentProject {
                let events = project.events.sorted { $0.timestamp > $1.timestamp }
                let filtered = filterType == "전체" ? events : events.filter { $0.type == filterType }
                List(filtered, id: \.id) { e in
                    HStack {
                        Text(e.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .frame(width: 140, alignment: .leading)
                        Text(e.type).frame(width: 100, alignment: .leading)
                        Text(e.baseAsset).frame(width: 60, alignment: .leading)
                        Text(e.quantity).frame(width: 100, alignment: .trailing)
                        Text(e.quoteAmountKRW ?? "-").frame(width: 100, alignment: .trailing)
                        Text(e.sourceKind).foregroundStyle(.secondary)
                    }
                    .font(.system(.body, design: .monospaced))
                }
            }
            Spacer()
        }
        .padding()
    }
}

