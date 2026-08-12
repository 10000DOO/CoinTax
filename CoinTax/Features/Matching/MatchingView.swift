import SwiftUI

struct MatchingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var candidates: [TransferMatchCandidate] = []
    @State private var unmatchedWithdrawals: [LedgerEventEntity] = []
    @State private var unmatchedDeposits: [LedgerEventEntity] = []
    @State private var manualWithdrawalID: UUID?
    @State private var manualDepositID: UUID?
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

            manualLinkBox

            if let project = env.currentProject {
                let confirmed = project.links.filter { $0.status == LinkStatus.confirmed.rawValue }
                GroupBox("확정 링크 \(confirmed.count)건") {
                    if confirmed.isEmpty {
                        Text("없음").foregroundStyle(.secondary)
                    } else {
                        ForEach(confirmed, id: \.id) { link in
                            HStack {
                                Text("\(link.withdrawnQty) → \(link.receivedQty)  score=\(link.score.map { String(format: "%.2f", $0) } ?? "-")")
                                    .font(.caption.monospaced())
                                if let note = link.note, !note.isEmpty {
                                    Text(note).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("연결 해제") { unlink(link, project: project) }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding()
        .onAppear { refresh() }
    }

    /// F-MT-02 수동 매칭 — 자동 후보가 못 잡은 전송을 직접 연결
    @ViewBuilder
    private var manualLinkBox: some View {
        GroupBox("수동 연결 (자동 후보가 없을 때)") {
            if unmatchedWithdrawals.isEmpty || unmatchedDeposits.isEmpty {
                Text("연결할 수 있는 미매칭 출금·입금 조합이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("출금", selection: $manualWithdrawalID) {
                        Text("선택").tag(Optional<UUID>.none)
                        ForEach(unmatchedWithdrawals.prefix(50), id: \.id) { e in
                            Text(eventLabel(e)).tag(Optional(e.id))
                        }
                    }
                    Image(systemName: "arrow.right")
                    Picker("입금", selection: $manualDepositID) {
                        Text("선택").tag(Optional<UUID>.none)
                        ForEach(unmatchedDeposits.prefix(50), id: \.id) { e in
                            Text(eventLabel(e)).tag(Optional(e.id))
                        }
                    }
                    Button("연결") { linkManually() }
                        .disabled(manualWithdrawalID == nil || manualDepositID == nil)
                }
                Text("자산이 같고 계정이 다르며 입금 수량이 출금 수량을 넘지 않아야 합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func eventLabel(_ e: LedgerEventEntity) -> String {
        let acc = env.currentProject?.accounts.first { $0.id == e.accountID }?.displayName ?? "?"
        return "\(e.timestamp.formatted(date: .numeric, time: .shortened)) \(acc) \(e.baseAsset) \(e.quantity)"
    }

    private func linkManually() {
        guard let project = env.currentProject,
              let wID = manualWithdrawalID, let dID = manualDepositID,
              let w = project.events.first(where: { $0.id == wID }),
              let d = project.events.first(where: { $0.id == dID }) else { return }
        do {
            try env.matchingService.linkManually(withdrawal: w, deposit: d, project: project)
            env.invalidateCalculation()
            manualWithdrawalID = nil
            manualDepositID = nil
            refresh()
            message = "수동 연결 완료"
        } catch {
            message = error.localizedDescription
        }
    }

    private func unlink(_ link: TransferLinkEntity, project: ProjectEntity) {
        do {
            try env.matchingService.unlink(link, project: project)
            env.invalidateCalculation()
            refresh()
            message = "연결 해제됨 — 재계산이 필요합니다"
        } catch {
            message = error.localizedDescription
        }
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
        let linkedTo = Set(
            project.links
                .filter { $0.status == LinkStatus.confirmed.rawValue || $0.status == LinkStatus.suggested.rawValue }
                .map(\.toEventID)
        )
        unmatchedWithdrawals = project.events
            .filter { $0.type == EventType.withdrawal.rawValue && $0.baseAsset.uppercased() != "KRW" && !linkedFrom.contains($0.id) }
            .sorted { $0.timestamp > $1.timestamp }
        unmatchedDeposits = project.events
            .filter { $0.type == EventType.deposit.rawValue && $0.baseAsset.uppercased() != "KRW" && !linkedTo.contains($0.id) }
            .sorted { $0.timestamp > $1.timestamp }
        message = "후보 \(candidates.count)건 · 미매칭 출금 \(unmatchedWithdrawals.count)건 · 미매칭 입금 \(unmatchedDeposits.count)건"
    }

    private func confirm(_ c: TransferMatchCandidate) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.confirm(candidate: c, project: project)
            env.invalidateCalculation()
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
