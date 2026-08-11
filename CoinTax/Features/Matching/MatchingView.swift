import SwiftUI

struct MatchingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var candidates: [TransferMatchCandidate] = []
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("전송 매칭")
                .font(.largeTitle.bold())
            HStack {
                Button("후보 새로고침") { refresh() }
                Text(message).foregroundStyle(.secondary)
            }
            if candidates.isEmpty {
                Text("제안된 매칭이 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                List(candidates) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(String(format: "점수 %.2f", c.score))
                            Text("출 \(Money.decimalString(c.withdrawnQty)) → 입 \(Money.decimalString(c.receivedQty))")
                                .font(.caption)
                            Text(c.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("확정") { confirm(c) }
                        Button("거부", role: .destructive) { reject(c) }
                    }
                }
            }
            if let project = env.currentProject {
                GroupBox("확정 링크 \(project.links.filter { $0.status == LinkStatus.confirmed.rawValue }.count)건") {
                    ForEach(project.links.filter { $0.status == LinkStatus.confirmed.rawValue }, id: \.id) { link in
                        Text("\(link.withdrawnQty) → \(link.receivedQty)")
                    }
                }
            }
            Spacer()
        }
        .padding()
        .onAppear { refresh() }
    }

    private func refresh() {
        guard let project = env.currentProject else { return }
        candidates = env.matchingService.suggest(for: project)
        message = "후보 \(candidates.count)건"
    }

    private func confirm(_ c: TransferMatchCandidate) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.confirm(candidate: c, project: project)
            refresh()
            message = "확정됨"
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
