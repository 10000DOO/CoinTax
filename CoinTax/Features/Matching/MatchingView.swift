import SwiftUI

/// 전송 연결 — 「국내에서 보낸 코인」과 「해외에서 받은 코인」을 이어 붙인다.
///
/// 이걸 안 하면 보낸 쪽의 취득원가가 사라지고 받은 쪽은 취득가 0원이 되어
/// 나중에 팔 때 전액이 이익으로 잡힌다. 그래서 화면 맨 위에 그 이유를 적어 둔다.
struct MatchingView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var candidates: [TransferMatchCandidate] = []
    @State private var unmatchedWithdrawals: [LedgerEventEntity] = []
    @State private var unmatchedDeposits: [LedgerEventEntity] = []
    @State private var manualWithdrawalID: UUID?
    @State private var manualDepositID: UUID?
    @State private var message: String?
    @State private var messageTone: Tone = .neutral
    @State private var showManual = false

    var body: some View {
        Page(title: "전송 연결", subtitle: "거래소 사이를 옮긴 코인을 이어 붙입니다") {
            Button {
                refresh()
            } label: {
                Label("다시 찾기", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        } content: {
            if let message { Banner(text: message, tone: messageTone, systemImage: bannerIcon) }

            whyCard
            if !candidates.isEmpty { candidatesCard }
            confirmedCard
            if !unmatchedWithdrawals.isEmpty || !unmatchedDeposits.isEmpty { unmatchedCard }
            manualCard
        }
        .onAppear { refresh() }
    }

    // MARK: 왜 해야 하는가

    private var whyCard: some View {
        let confirmed = env.currentProject?.links.filter { $0.status == LinkStatus.confirmed.rawValue }.count ?? 0
        return Card {
            HStack(spacing: Theme.gapSection) {
                StatTile(label: "연결 대기", value: "\(candidates.count)건",
                         caption: candidates.isEmpty ? "모두 처리했습니다" : "확인이 필요합니다",
                         tone: candidates.isEmpty ? .positive : .warning)
                StatTile(label: "연결 완료", value: "\(confirmed)건", caption: "원가가 이어집니다", tone: .positive)
                StatTile(label: "연결 안 됨", value: "\(unmatchedWithdrawals.count)건",
                         caption: unmatchedWithdrawals.isEmpty ? "없음" : "취득원가가 사라집니다",
                         tone: unmatchedWithdrawals.isEmpty ? .neutral : .warning)
            }
            Text("연결하지 않으면 보낸 쪽 취득원가가 없어지고 받은 쪽은 0원으로 시작합니다. 그만큼 세금이 실제보다 커집니다. 개인 지갑으로 보낸 것이라면 아래에서 「개인지갑으로」를 눌러 두세요 — 그래야 산 값이 지갑까지 이어집니다.")
                .font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 후보

    private var candidatesCard: some View {
        Card(title: "이 전송들을 연결할까요?", systemImage: "arrow.left.arrow.right") {
            HStack {
                Spacer()
                Button("모두 연결 (\(candidates.count))") { confirmAll() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            ForEach(candidates) { c in
                candidateRow(c)
                if c.id != candidates.last?.id { Divider() }
            }
        }
    }

    private func candidateRow(_ c: TransferMatchCandidate) -> some View {
        let lost = c.withdrawnQty - c.receivedQty
        let lowConfidence = c.note.contains("확인 필요")
        return HStack(alignment: .center, spacing: Theme.gap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(endpointLabel(c.fromEventID.raw)).font(Theme.body.weight(.medium))
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(endpointLabel(c.toEventID.raw)).font(Theme.body.weight(.medium))
                    if lowConfidence { Pill(text: "확인 필요", tone: .warning) }
                }
                HStack(spacing: 6) {
                    Text(assetOf(c.fromEventID.raw)).font(Theme.mono).foregroundStyle(.secondary)
                    Text(Fmt.qtyString(c.withdrawnQty)).font(Theme.mono)
                    Text("→").foregroundStyle(.tertiary)
                    Text(Fmt.qtyString(c.receivedQty)).font(Theme.mono)
                    if lost > 0 {
                        Text("(수수료 \(Fmt.qtyString(lost)))")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                Text(dateLabel(c.fromEventID.raw)).font(Theme.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("연결") { confirm(c) }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button("아니오") { reject(c) }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 5)
    }

    // MARK: 연결됨

    private var confirmedCard: some View {
        let links = (env.currentProject?.links ?? []).filter { $0.status == LinkStatus.confirmed.rawValue }
        return Card(title: "연결된 전송 (\(links.count))", systemImage: "link") {
            if links.isEmpty {
                Text("아직 없습니다.").font(Theme.body).foregroundStyle(.secondary)
            } else {
                ForEach(links.sorted { linkDate($0) > linkDate($1) }, id: \.id) { l in
                    HStack(spacing: Theme.gap) {
                        Text(Fmt.date(linkDate(l))).font(Theme.mono)
                            .frame(width: 84, alignment: .leading)
                        Text(assetOf(l.fromEventID)).font(Theme.mono).frame(width: 54, alignment: .leading)
                        Text(endpointLabel(l.fromEventID)).font(Theme.caption).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Text(endpointLabel(l.toEventID)).font(Theme.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.qtyString(Decimal(string: l.receivedQty) ?? 0)).font(Theme.mono)
                        Button {
                            unlink(l)
                        } label: {
                            Image(systemName: "xmark.circle").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("연결 해제")
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: 미연결

    private var unmatchedCard: some View {
        Card(
            title: "연결 상대를 못 찾은 전송",
            systemImage: "questionmark.circle",
            footnote: "이대로 두면 보낸 코인의 취득원가가 사라집니다. 나중에 그 코인을 거래소로 다시 들여와 팔면 «산 값 0원»으로 계산되어 판 금액 전부가 이익이 됩니다."
        ) {
            if !unmatchedWithdrawals.isEmpty {
                HStack {
                    Text("보낸 것 \(unmatchedWithdrawals.count)건")
                        .font(Theme.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("전부 개인지갑으로 (\(unmatchedWithdrawals.count))") { moveAllToWallet() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Text("**개인지갑(레저·메타마스크 등)으로 보낸 것**이면 「개인지갑으로」를 누르세요 — 산 값이 지갑까지 따라갑니다. "
                     + "**다른 거래소로 보낸 것**이면 그 거래소 파일을 먼저 넣으세요. "
                     + "**실제로 팔았거나 남에게 보낸 것**이면 개인지갑이 아닙니다 (양도로 신고해야 합니다).")
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unmatchedWithdrawals.prefix(20), id: \.id) { e in
                    unmatchedRow(e, outgoing: true)
                }
                if unmatchedWithdrawals.count > 20 {
                    Text("외 \(unmatchedWithdrawals.count - 20)건").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            if !unmatchedDeposits.isEmpty {
                HStack {
                    Text("받은 것 \(unmatchedDeposits.count)건")
                        .font(Theme.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if walletReceivable > 0 {
                        Button("전부 개인지갑에서 (\(walletReceivable))") { receiveAllFromWallet() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Text("**개인지갑에서 되가져온 것**이면 「개인지갑에서」를 누르세요 — 지갑에 남아 있던 산 값이 이어집니다. "
                     + "지갑이 그 시점에 그 코인을 갖고 있을 때만 누를 수 있습니다.")
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unmatchedDeposits.prefix(20), id: \.id) { e in
                    unmatchedRow(e, outgoing: false)
                }
                if unmatchedDeposits.count > 20 {
                    Text("외 \(unmatchedDeposits.count - 20)건").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func unmatchedRow(_ e: LedgerEventEntity, outgoing: Bool) -> some View {
        HStack(spacing: Theme.gap) {
            Image(systemName: outgoing ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 9))
                .foregroundStyle(outgoing ? Theme.warning : Theme.positive)
            Text(Fmt.date(e.timestamp)).font(Theme.mono).frame(width: 84, alignment: .leading)
            Text(accountName(e.accountID)).font(Theme.caption).frame(width: 66, alignment: .leading)
            Text(e.baseAsset).font(Theme.mono).frame(width: 54, alignment: .leading)
            Text(Fmt.qtyString(Money.abs(Decimal(string: e.quantity) ?? 0))).font(Theme.mono)
            if let hint = e.counterpartyHint, !hint.isEmpty {
                Pill(text: hint, tone: .neutral)
            }
            Spacer()
            if outgoing {
                Button("개인지갑으로") { moveToWallet(e) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("거래소 밖 내 지갑으로 보낸 것으로 처리합니다. 산 값이 지갑으로 이어지고, 전송 자체는 세금이 붙지 않습니다")
            } else if canReceiveFromWallet(e) {
                Button("개인지갑에서") { receiveFromWallet(e) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("개인지갑에 있던 코인을 거래소로 되가져온 것으로 처리합니다. 지갑에 남아 있던 산 값이 이어집니다")
            }
        }
        .padding(.vertical, 1)
    }

    /// 그 시점 개인지갑에 그 코인이 충분히 있어야 「개인지갑에서」를 누를 수 있다.
    /// 없는데 누르면 없던 자산을 만들어 내는 셈이라 음수 재고로 계산이 막힌다.
    private func canReceiveFromWallet(_ e: LedgerEventEntity) -> Bool {
        guard let project = env.currentProject, e.baseAsset.uppercased() != "KRW" else { return false }
        let qty = Money.abs(Decimal(string: e.quantity) ?? 0)
        guard qty > 0 else { return false }
        return env.matchingService.walletBalance(asset: e.baseAsset, at: e.timestamp, project: project) >= qty
    }

    private var walletReceivable: Int {
        unmatchedDeposits.filter { canReceiveFromWallet($0) }.count
    }

    // MARK: 수동 연결

    private var manualCard: some View {
        Card {
            DisclosureGroup(isExpanded: $showManual) {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    Text("자동으로 못 찾은 짝을 직접 이어 붙입니다. 자산이 같아야 하고, 받은 수량이 보낸 수량보다 클 수 없습니다.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                    HStack(spacing: Theme.gap) {
                        Picker("보낸 거래", selection: $manualWithdrawalID) {
                            Text("고르기").tag(Optional<UUID>.none)
                            ForEach(unmatchedWithdrawals, id: \.id) { e in
                                Text("\(Fmt.date(e.timestamp)) \(e.baseAsset) \(Fmt.qtyString(Money.abs(Decimal(string: e.quantity) ?? 0)))")
                                    .tag(Optional(e.id))
                            }
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("받은 거래", selection: $manualDepositID) {
                            Text("고르기").tag(Optional<UUID>.none)
                            ForEach(unmatchedDeposits, id: \.id) { e in
                                Text("\(Fmt.date(e.timestamp)) \(e.baseAsset) \(Fmt.qtyString(Money.abs(Decimal(string: e.quantity) ?? 0)))")
                                    .tag(Optional(e.id))
                            }
                        }
                        Button("연결") { linkManually() }
                            .buttonStyle(.borderedProminent)
                            .disabled(manualWithdrawalID == nil || manualDepositID == nil)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("직접 연결하기").font(Theme.cardTitle)
            }
        }
    }

    // MARK: 표시 도우미

    private func event(_ id: UUID) -> LedgerEventEntity? {
        env.currentProject?.events.first { $0.id == id }
    }

    private func accountName(_ id: UUID) -> String {
        env.currentProject?.accounts.first { $0.id == id }?.displayName ?? "?"
    }

    private func endpointLabel(_ eventID: UUID) -> String {
        guard let e = event(eventID) else { return "?" }
        return accountName(e.accountID)
    }

    private func assetOf(_ eventID: UUID) -> String {
        event(eventID)?.baseAsset ?? "?"
    }

    private func dateLabel(_ eventID: UUID) -> String {
        guard let e = event(eventID) else { return "" }
        return Fmt.dateTime(e.timestamp)
    }

    private func linkDate(_ l: TransferLinkEntity) -> Date {
        event(l.fromEventID)?.timestamp ?? .distantPast
    }

    private var bannerIcon: String {
        switch messageTone {
        case .positive: return "checkmark.circle.fill"
        case .danger: return "xmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    // MARK: 동작

    private func refresh() {
        guard let project = env.currentProject else {
            candidates = []; unmatchedWithdrawals = []; unmatchedDeposits = []
            return
        }
        candidates = env.matchingService.suggest(for: project)
        let confirmedFrom = Set(project.links.filter { $0.status == LinkStatus.confirmed.rawValue }.map(\.fromEventID))
        let confirmedTo = Set(project.links.filter { $0.status == LinkStatus.confirmed.rawValue }.map(\.toEventID))
        unmatchedWithdrawals = project.events
            .filter { $0.type == EventType.withdrawal.rawValue && $0.baseAsset.uppercased() != "KRW" && !confirmedFrom.contains($0.id) }
            .sorted { $0.timestamp > $1.timestamp }
        unmatchedDeposits = project.events
            .filter { $0.type == EventType.deposit.rawValue && $0.baseAsset.uppercased() != "KRW" && !confirmedTo.contains($0.id) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private func confirm(_ c: TransferMatchCandidate) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.confirm(candidate: c, project: project)
            env.invalidateCalculation()
            refresh()
            set("연결했습니다.", .positive)
        } catch {
            set(error.localizedDescription, .danger)
        }
    }

    private func confirmAll() {
        guard let project = env.currentProject else { return }
        var ok = 0
        var failed = 0
        for c in candidates {
            do {
                try env.matchingService.confirm(candidate: c, project: project)
                ok += 1
            } catch {
                failed += 1
            }
        }
        env.invalidateCalculation()
        refresh()
        set(failed == 0 ? "\(ok)건을 연결했습니다." : "\(ok)건 연결 · \(failed)건 실패", failed == 0 ? .positive : .warning)
    }

    private func reject(_ c: TransferMatchCandidate) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.reject(candidate: c, project: project)
            refresh()
            set("다시 제안하지 않습니다.", .neutral)
        } catch {
            set(error.localizedDescription, .danger)
        }
    }

    private func unlink(_ l: TransferLinkEntity) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.unlink(l, project: project)
            env.invalidateCalculation()
            refresh()
            set("연결을 해제했습니다.", .neutral)
        } catch {
            set(error.localizedDescription, .danger)
        }
    }

    private func moveToWallet(_ e: LedgerEventEntity) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.moveToWallet(withdrawal: e, project: project)
            env.invalidateCalculation()
            refresh()
            set("개인지갑으로 옮겼습니다 — 산 값이 이어집니다.", .positive)
        } catch let err as CoinTaxError {
            set(err.errorDescription ?? "처리하지 못했습니다", .danger)
        } catch {
            set(error.localizedDescription, .danger)
        }
    }

    private func moveAllToWallet() {
        guard let project = env.currentProject else { return }
        var ok = 0
        var failed = 0
        for e in unmatchedWithdrawals {
            do {
                try env.matchingService.moveToWallet(withdrawal: e, project: project)
                ok += 1
            } catch {
                failed += 1
            }
        }
        env.invalidateCalculation()
        refresh()
        set(failed == 0 ? "\(ok)건을 개인지갑으로 옮겼습니다." : "\(ok)건 처리 · \(failed)건 실패",
            failed == 0 ? .positive : .warning)
    }

    private func receiveFromWallet(_ e: LedgerEventEntity) {
        guard let project = env.currentProject else { return }
        do {
            try env.matchingService.receiveFromWallet(deposit: e, project: project)
            env.invalidateCalculation()
            refresh()
            set("개인지갑에서 받은 것으로 처리했습니다 — 산 값이 이어집니다.", .positive)
        } catch let err as CoinTaxError {
            set(err.errorDescription ?? "처리하지 못했습니다", .danger)
        } catch {
            set(error.localizedDescription, .danger)
        }
    }

    private func receiveAllFromWallet() {
        guard let project = env.currentProject else { return }
        var ok = 0
        var failed = 0
        // 시간 순으로 처리해야 한다 — 뒤 건을 먼저 처리하면 앞 건에서 지갑 잔고가 모자란다
        for e in unmatchedDeposits.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard canReceiveFromWallet(e) else { continue }
            do {
                try env.matchingService.receiveFromWallet(deposit: e, project: project)
                ok += 1
            } catch {
                failed += 1
            }
        }
        env.invalidateCalculation()
        refresh()
        set(failed == 0 ? "\(ok)건을 개인지갑에서 받은 것으로 처리했습니다." : "\(ok)건 처리 · \(failed)건 실패",
            failed == 0 ? .positive : .warning)
    }

    private func linkManually() {
        guard let project = env.currentProject,
              let wID = manualWithdrawalID, let dID = manualDepositID,
              let w = event(wID), let d = event(dID) else { return }
        do {
            try env.matchingService.linkManually(withdrawal: w, deposit: d, project: project)
            manualWithdrawalID = nil
            manualDepositID = nil
            env.invalidateCalculation()
            refresh()
            set("연결했습니다.", .positive)
        } catch let e as CoinTaxError {
            set(e.errorDescription ?? "연결하지 못했습니다", .danger)
        } catch {
            set(error.localizedDescription, .danger)
        }
    }

    private func set(_ text: String, _ tone: Tone) {
        message = text
        messageTone = tone
    }
}
