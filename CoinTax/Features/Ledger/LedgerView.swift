import SwiftUI

struct LedgerView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var filterType: String = "전체"
    @State private var filterAccountID: UUID?
    @State private var filterExchange: String = "전체"
    @State private var filterAsset: String = "전체"
    @State private var fromDate = Calendar.current.date(byAdding: .year, value: -3, to: Date()) ?? Date()
    @State private var toDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("거래내역")
                .font(.largeTitle.bold())

            if let project = env.currentProject {
                HStack {
                    Picker("계정", selection: $filterAccountID) {
                        Text("전체 계정").tag(Optional<UUID>.none)
                        ForEach(project.accounts, id: \.id) { a in
                            Text(a.displayName).tag(Optional(a.id))
                        }
                    }
                    .frame(maxWidth: 180)

                    Picker("거래소", selection: $filterExchange) {
                        Text("전체").tag("전체")
                        ForEach(exchanges(in: project), id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 140)

                    Picker("자산", selection: $filterAsset) {
                        Text("전체").tag("전체")
                        ForEach(assets(in: project), id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 120)

                    DatePicker("부터", selection: $fromDate, displayedComponents: .date)
                    DatePicker("까지", selection: $toDate, displayedComponents: .date)
                }

                Picker("유형", selection: $filterType) {
                    Text("전체").tag("전체")
                    ForEach(["buy", "sell", "deposit", "withdrawal", "income", "transferInternal", "fiatDeposit", "fiatWithdraw"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.segmented)

                let filtered = filteredEvents(project)
                Text("\(filtered.count)건")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List(filtered, id: \.id) { e in
                    HStack {
                        Text(e.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .frame(width: 140, alignment: .leading)
                        Text(accountName(e.accountID, project: project))
                            .frame(width: 70, alignment: .leading)
                        Text(exchangeCode(e.accountID, project: project))
                            .frame(width: 70, alignment: .leading)
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

    private func assets(in project: ProjectEntity) -> [String] {
        Array(Set(project.events.map(\.baseAsset))).sorted()
    }

    private func exchanges(in project: ProjectEntity) -> [String] {
        Array(Set(project.accounts.map(\.exchangeCode))).sorted()
    }

    private func accountName(_ id: UUID, project: ProjectEntity) -> String {
        project.accounts.first { $0.id == id }?.displayName ?? String(id.uuidString.prefix(6))
    }

    private func exchangeCode(_ id: UUID, project: ProjectEntity) -> String {
        project.accounts.first { $0.id == id }?.exchangeCode ?? "-"
    }

    private func filteredEvents(_ project: ProjectEntity) -> [LedgerEventEntity] {
        let start = Calendar.current.startOfDay(for: fromDate)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate)) ?? toDate
        return project.events
            .filter { e in
                if let aid = filterAccountID, e.accountID != aid { return false }
                if filterExchange != "전체" {
                    let ex = project.accounts.first { $0.id == e.accountID }?.exchangeCode
                    if ex != filterExchange { return false }
                }
                if filterType != "전체", e.type != filterType { return false }
                if filterAsset != "전체", e.baseAsset != filterAsset { return false }
                if e.timestamp < start || e.timestamp >= end { return false }
                return true
            }
            .sorted { $0.timestamp > $1.timestamp }
    }
}

