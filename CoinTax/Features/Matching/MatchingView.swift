import SwiftUI

struct MatchingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var candidates: [TransferMatchCandidate] = []
    @State private var unmatchedWithdrawals: [LedgerEventEntity] = []
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("전송 매칭")
                .font(.largeTitle.bold())
            HStack {
                Button("후보 새로고침") { refresh() }
                Text(message).foregroundStyle(.secondary)
                Spacer()
                if !unmatchedWithdrawals.isEmpty {
                    Text("미매칭 출금 \(unmatchedWithdrawals.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
            }

            if candidates.isEmpty {
                Text("제안된 매칭이 없습니다. Import 후 새로고침하세요.")
                    .foregroundStyle(.secondary)
            } else {
                List(candidates) { c in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "점수 %.2f", c.score))
                                .font(.headline)
                            Text("출 \(Money.decimalString(c.withdrawnQty)) → 입 \(Money.decimalString(c.receivedQty))")
                            if let project = env.currentProject {
                                Text(eventSummary(c.fromEventID.raw, project: project) + "  →  " + eventSummary(c.toEventID.raw, project: project))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(c.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("확정") { confirm(c) }
                            .buttonStyle(.borderedProminent)
                        Button("거부", role: .destructive) { reject(c) }
                    }
                }
            }

            if !unmatchedWithdrawals.isEmpty {
                GroupBox("미매칭 출금 (원가 이전 없음)") {
                    ForEach(unmatchedWithdrawals.prefix(15), id: \.id) { e in
                        HStack {
                            Text(e.timestamp.formatted(date: .abbreviated, time: .shortened))
                            Text(e.baseAsset)
                            Text(e.quantity)
                            if let hint = e.counterpartyHint, !hint.isEmpty {
                                Text("힌트: \(hint)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption.monospaced())
                    }
                }
            }

            if let project = env.currentProject {
                let confirmed = project.links.filter { $0.status == LinkStatus.confirmed.rawValue }
                GroupBox("확정 링크 \(confirmed.count)건") {
                    if confirmed.isEmpty {
                        Text("없음").foregroundStyle(.secondary)
                    } else {
                        ForEach(confirmed, id: \.id) { link in
                            Text("\(link.withdrawnQty) → \(link.receivedQty)  score=\(link.score.map { String(format: "%.2f", $0) } ?? "-")")
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
            Spacer()
        }
        .padding()
        .onAppear { refresh() }
    }

    private func eventSummary(_ id: UUID, project: ProjectEntity) -> String {
        guard let e = project.events.first(where: { $0.id == id }) else { return id.uuidString.prefix(8).description }
        let acc = project.accounts.first { $0.id == e.accountID }?.displayName ?? "?"
        return "\(acc) \(e.baseAsset) \(e.quantity)"
    }

    private func refresh() {
        guard let project = env.currentProject else { return }
        candidates = env.matchingService.suggest(for: project)
        let linkedFrom = Set(
            project.links
                .filter { $0.status == LinkStatus.confirmed.rawValue || $0.status == LinkStatus.suggested.rawValue }
                .map(\.fromEventID)
        )
        unmatchedWithdrawals = project.events
            .filter { $0.type == EventType.withdrawal.rawValue && $0.baseAsset.uppercased() != "KRW" && !linkedFrom.contains($0.id) }
            .sorted { $0.timestamp > $1.timestamp }
        message = "후보 \(candidates.count)건 · 미매칭 출금 \(unmatchedWithdrawals.count)건"
    }

    private func confirm(_ c: TransferMatchCandidate) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.confirm(candidate: c, project: project)
            refresh()
            message = "확정됨 · 후보 \(candidates.count)건"
        } catch {
            message = error.localizedDescription
        }
    }

    private func reject(_ c: TransferMatchCandidate) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.reject(candidate: c, project: project)
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }
}
