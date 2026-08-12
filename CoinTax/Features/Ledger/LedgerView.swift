import SwiftUI

/// 거래내역 — 가져온 자료가 제대로 들어왔는지 눈으로 확인하는 곳.
struct LedgerView: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var search = ""
    @State private var filterType = "전체"
    @State private var filterAccountID: UUID?
    @State private var filterAsset = "전체"
    @State private var rows: [LedgerRow] = []
    @State private var sortOrder = [KeyPathComparator(\LedgerRow.timestamp, order: .reverse)]

    /// 표에 그대로 넣을 수 있게 미리 문자열로 만들어 둔다.
    /// SwiftData 엔티티를 그대로 정렬·필터하면 스크롤할 때마다 변환이 다시 돈다.
    struct LedgerRow: Identifiable {
        let id: UUID
        let timestamp: Date
        let account: String
        let type: String
        let typeLabel: String
        let asset: String
        let quantity: Decimal
        let krw: Decimal?
        let source: String
        let memo: String
    }

    private static let typeOptions: [(String, String)] = [
        ("전체", "전체"), ("buy", "매수"), ("sell", "매도"),
        ("deposit", "입금"), ("withdrawal", "출금"), ("income", "보상"),
        ("transferInternal", "내부이동"), ("fiatDeposit", "원화입금"), ("fiatWithdraw", "원화출금")
    ]

    var body: some View {
        FullPage(title: "거래내역", subtitle: "\(rows.count)건") {
            TextField("자산·메모 검색", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        } content: {
            filterCard
            if rows.isEmpty {
                EmptyState(
                    systemImage: "list.bullet.rectangle",
                    title: env.currentProject?.events.isEmpty == false ? "조건에 맞는 거래가 없습니다" : "아직 거래가 없습니다",
                    message: env.currentProject?.events.isEmpty == false ? "필터를 바꿔 보세요." : "거래소 파일을 먼저 넣어 주세요.",
                    actionTitle: env.currentProject?.events.isEmpty == false ? nil : "자료 넣기"
                ) { env.section = .importFiles }
                Spacer()
            } else {
                tableCard
            }
        }
        .onAppear { reload() }
        .onChange(of: filterAccountID) { _, _ in reload() }
        .onChange(of: filterAsset) { _, _ in reload() }
        .onChange(of: filterType) { _, _ in reload() }
        .onChange(of: search) { _, _ in reload() }
    }

    private var filterCard: some View {
        Card {
            HStack(spacing: Theme.gap) {
                Picker("", selection: $filterAccountID) {
                    Text("모든 거래소").tag(Optional<UUID>.none)
                    ForEach(env.currentProject?.accounts ?? [], id: \.id) { a in
                        Text(a.displayName).tag(Optional(a.id))
                    }
                }
                .labelsHidden().frame(width: 130)

                Picker("", selection: $filterAsset) {
                    Text("모든 자산").tag("전체")
                    ForEach(assetOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 110)

                Picker("", selection: $filterType) {
                    ForEach(Self.typeOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 110)

                Spacer()

                if filterAccountID != nil || filterAsset != "전체" || filterType != "전체" || !search.isEmpty {
                    Button("초기화") {
                        filterAccountID = nil; filterAsset = "전체"; filterType = "전체"; search = ""
                    }
                    .buttonStyle(.link).font(Theme.caption)
                }
            }
        }
    }

    private var tableCard: some View {
        Card {
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("시각", value: \.timestamp) { r in
                    Text(Fmt.dateTime(r.timestamp)).font(Theme.mono)
                }
                .width(min: 120, ideal: 138)

                TableColumn("거래소", value: \.account) { r in
                    Text(r.account).font(Theme.body)
                }
                .width(min: 60, ideal: 78)

                TableColumn("종류", value: \.type) { r in
                    Pill(text: r.typeLabel, tone: tone(for: r.type))
                }
                .width(min: 62, ideal: 74)

                TableColumn("자산", value: \.asset) { r in
                    Text(r.asset).font(Theme.mono)
                }
                .width(min: 50, ideal: 62)

                TableColumn("수량", value: \.quantity) { r in
                    Text(Fmt.qtyString(r.quantity))
                        .font(Theme.mono)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 120)

                TableColumn("원화 금액") { r in
                    Text(r.krw.map { Fmt.krwString($0) } ?? "—")
                        .font(Theme.mono)
                        .foregroundStyle(r.krw == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 120)

                TableColumn("비고") { r in
                    Text(r.memo).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: sortOrder) { _, order in rows.sort(using: order) }
        }
    }

    private func tone(for type: String) -> Tone {
        switch type {
        case "buy": return .accent
        case "sell": return .danger
        case "deposit", "fiatDeposit": return .positive
        case "withdrawal", "fiatWithdraw": return .warning
        case "income": return .positive
        default: return .neutral
        }
    }

    private var assetOptions: [String] {
        Array(Set((env.currentProject?.events ?? []).map(\.baseAsset))).sorted()
    }

    private func reload() {
        guard let project = env.currentProject else { rows = []; return }
        let accounts = Dictionary(project.accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()

        var out = project.events.compactMap { e -> LedgerRow? in
            if let aid = filterAccountID, e.accountID != aid { return nil }
            if filterType != "전체", e.type != filterType { return nil }
            if filterAsset != "전체", e.baseAsset != filterAsset { return nil }
            if !needle.isEmpty {
                let hay = (e.baseAsset + " " + (e.memo ?? "") + " " + (e.counterpartyHint ?? "")).lowercased()
                if !hay.contains(needle) { return nil }
            }
            return LedgerRow(
                id: e.id,
                timestamp: e.timestamp,
                account: accounts[e.accountID] ?? "?",
                type: e.type,
                typeLabel: Self.typeOptions.first { $0.0 == e.type }?.1 ?? e.type,
                asset: e.baseAsset,
                quantity: Money.abs(Decimal(string: e.quantity) ?? 0),
                krw: e.quoteAmountKRW.flatMap { Decimal(string: $0) },
                source: e.sourceKind,
                memo: e.memo ?? ""
            )
        }
        out.sort(using: sortOrder)
        rows = out
    }
}
