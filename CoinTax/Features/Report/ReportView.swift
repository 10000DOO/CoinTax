import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ReportView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var taxYear: Int = 2027
    @State private var message: String?
    @State private var messageTone: Tone = .neutral
    @State private var busy = false
    @State private var showAllDisposals = false

    var body: some View {
        Page(title: "세금 리포트", subtitle: "\(taxYear)년 귀속 가상자산 기타소득") {
            Picker("", selection: $taxYear) {
                ForEach(2027...2035, id: \.self) { Text("\($0)년").tag($0) }
            }
            .labelsHidden()
            .frame(width: 92)

            Button {
                calculate()
            } label: {
                HStack(spacing: 5) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "계산 중" : "계산")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || env.currentProject == nil)

            Menu {
                Button("CSV로 저장") { exportCSV() }
                Button("PDF로 저장") { exportPDF() }
            } label: {
                Label("내려받기", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!canExport)
            .help(canExport ? "신고 보조자료를 저장합니다" : "검증을 통과해야 내려받을 수 있습니다")
        } content: {
            if env.calculationStale {
                Banner(text: "자료가 바뀌었습니다. 다시 계산하기 전까지 아래 숫자는 낡은 값이고 내려받기가 잠깁니다.",
                       tone: .warning, actionTitle: "다시 계산") { calculate() }
            }
            if let message { Banner(text: message, tone: messageTone, systemImage: bannerIcon) }

            if let c = env.lastCalculation {
                taxFlowCard(c)
                verificationCard(c)
                if !c.summary.disposals.isEmpty { assetBreakdownCard(c) }
                if !c.summary.deemed.isEmpty { deemedCard(c) }
                if !c.summary.disposals.isEmpty { disposalsCard(c) }
                if !c.summary.fxSources.isEmpty { fxCard(c) }
                noticesCard(c)
            } else {
                EmptyState(
                    systemImage: "doc.text.magnifyingglass",
                    title: "아직 계산하지 않았습니다",
                    message: "위의 «계산» 을 누르면 그해 양도분으로 예상 세액을 만듭니다.",
                    actionTitle: "계산하기"
                ) { calculate() }
            }
        }
        .onAppear { taxYear = env.lastCalculation?.summary.taxYear ?? env.currentProject?.defaultTaxYear ?? 2027 }
    }

    // MARK: 세액이 나오는 과정

    private func taxFlowCard(_ c: CalculationResult) -> some View {
        let s = c.summary
        return Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("예상 납부 세액").font(Theme.caption).foregroundStyle(.secondary)
                    Text(Fmt.krwString(s.totalTaxKRW)).font(Theme.heroNumber)
                }
                Spacer()
                statusPill(c)
            }

            Divider().padding(.vertical, 4)

            Row(label: "총수입금액 (양도가액 합계)", value: Fmt.krwString(s.totalProceedsKRW),
                help: "그해 판 가격의 합계입니다. 코인끼리 교환한 것도 판 것으로 봅니다.")
            Row(label: "− 필요경비 (취득가 + 수수료)", value: Fmt.krwString(s.totalCostsKRW),
                help: "산 값과 거래 수수료입니다.")
            Row(label: "= 소득금액", value: Fmt.krwString(s.netIncomeKRW),
                tone: s.netIncomeKRW >= 0 ? .neutral : .accent, emphasized: true)
            Row(label: "− 기본공제", value: Fmt.krwString(s.basicDeductionKRW),
                help: "연 250만 원까지는 세금이 없습니다.")
            Row(label: "= 과세표준", value: Fmt.krwString(s.taxBaseKRW), emphasized: true)

            Divider().padding(.vertical, 2)

            Row(label: "국세 20%", value: Fmt.krwString(s.nationalTaxKRW))
            Row(label: "지방소득세 2%", value: Fmt.krwString(s.localTaxKRW))
            Row(label: "합계", value: Fmt.krwString(s.totalTaxKRW), tone: .accent, emphasized: true)

            if s.abandonedTransferCostKRW > 0 {
                Divider().padding(.vertical, 2)
                Row(label: "전송으로 사라진 취득가 (공제 안 함)",
                    value: Fmt.krwString(s.abandonedTransferCostKRW), tone: .warning,
                    help: "거래소 간 전송에서 없어진 수량의 취득가입니다. 과다 공제를 피하려고 경비에 넣지 않았습니다 — 세금이 조금 커지는 쪽입니다.")
            }
            if s.netIncomeKRW <= s.basicDeductionKRW {
                Text("소득이 기본공제 이하라 낼 세금이 없습니다.")
                    .font(Theme.caption).foregroundStyle(Theme.positive)
            }
        }
    }

    private func statusPill(_ c: CalculationResult) -> some View {
        Group {
            switch c.verification.status {
            case "passed": Pill(text: "검증 통과", tone: .positive, systemImage: "checkmark")
            case "passedWithWarnings": Pill(text: "확인할 점 있음", tone: .warning, systemImage: "exclamationmark")
            default: Pill(text: "검증 실패 · 내려받기 잠김", tone: .danger, systemImage: "lock.fill")
            }
        }
    }

    // MARK: 검증

    private func verificationCard(_ c: CalculationResult) -> some View {
        let issues = c.verification.issues
        let criticals = issues.filter { $0.severity == "critical" }
        let warnings = issues.filter { $0.severity != "critical" }
        return Card(title: "검증 결과", systemImage: "checkmark.shield") {
            if issues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                    Text("모든 검사를 통과했습니다.").font(Theme.body)
                }
            } else {
                HStack(spacing: Theme.gap) {
                    if !criticals.isEmpty { Pill(text: "막힘 \(criticals.count)", tone: .danger) }
                    if !warnings.isEmpty { Pill(text: "확인 \(warnings.count)", tone: .warning) }
                }
                ForEach(Array((criticals + warnings).prefix(12).enumerated()), id: \.offset) { _, issue in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(issue.severity == "critical" ? Theme.danger : Theme.warning)
                            .frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.message).font(Theme.body)
                                .fixedSize(horizontal: false, vertical: true)
                            if let ctx = issue.context, !ctx.isEmpty {
                                Text(ctx).font(Theme.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if issues.count > 12 {
                    Text("외 \(issues.count - 12)건").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 자산별

    private func assetBreakdownCard(_ c: CalculationResult) -> some View {
        let byAsset = Dictionary(grouping: c.summary.disposals, by: { $0.asset.code })
        return Card(title: "자산별 실현손익", systemImage: "chart.bar") {
            TableHeader(columns: [("자산", 60, .leading), ("건수", 50, .trailing),
                                  ("양도가액", 120, .trailing), ("손익", nil, .trailing)])
            ForEach(byAsset.keys.sorted(), id: \.self) { code in
                let rows = byAsset[code] ?? []
                let pnl = rows.reduce(Decimal(0)) { $0 + $1.pnlKRW }
                let proceeds = rows.reduce(Decimal(0)) { $0 + $1.proceedsKRW }
                HStack(spacing: Theme.gap) {
                    Text(code).font(Theme.body.weight(.medium)).frame(width: 60, alignment: .leading)
                    Text("\(rows.count)").frame(width: 50, alignment: .trailing)
                    Text(Fmt.krwString(proceeds)).frame(width: 120, alignment: .trailing)
                    Text(Fmt.krwSigned(pnl))
                        .foregroundStyle(Theme.pnlColor(pnl))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(Theme.mono)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: 건별

    private func disposalsCard(_ c: CalculationResult) -> some View {
        let all = c.summary.disposals.sorted { $0.timestamp < $1.timestamp }
        let shown = showAllDisposals ? all : Array(all.prefix(15))
        return Card(title: "건별 내역 (\(all.count)건)", systemImage: "list.number") {
            TableHeader(columns: [("날짜", 84, .leading), ("자산", 52, .leading), ("수량", 96, .trailing),
                                  ("양도가액", 108, .trailing), ("취득가액", 108, .trailing), ("손익", nil, .trailing)])
            ForEach(Array(shown.enumerated()), id: \.offset) { _, d in
                HStack(spacing: Theme.gap) {
                    Text(Fmt.date(d.timestamp)).frame(width: 84, alignment: .leading)
                    Text(d.asset.code).frame(width: 52, alignment: .leading)
                    Text(Fmt.qtyString(d.quantity)).frame(width: 96, alignment: .trailing)
                    Text(Fmt.krwString(d.proceedsKRW)).frame(width: 108, alignment: .trailing)
                    Text(Fmt.krwString(d.costKRW)).frame(width: 108, alignment: .trailing)
                    Text(Fmt.krwSigned(d.pnlKRW))
                        .foregroundStyle(Theme.pnlColor(d.pnlKRW))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(Theme.mono)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
            }
            if all.count > 15 {
                Button(showAllDisposals ? "접기" : "\(all.count - 15)건 더 보기") {
                    showAllDisposals.toggle()
                }
                .buttonStyle(.link).font(Theme.caption)
            }
        }
    }

    // MARK: 의제취득가

    private func deemedCard(_ c: CalculationResult) -> some View {
        let s = c.summary
        return Card(
            title: "과세 시작 전 보유분 취득가",
            systemImage: "clock.arrow.circlepath",
            footnote: "2027-01-01 전부터 갖고 있던 코인은 «실제 산 값» 과 «2026-12-31 시가» 중 큰 쪽을 취득가로 봅니다."
        ) {
            TableHeader(columns: [("자산", 56, .leading), ("수량", 96, .trailing), ("실제 취득가", 100, .trailing),
                                  ("시가", 100, .trailing), ("적용", 100, .trailing), ("사유", 70, .trailing)])
            ForEach(Array(s.deemed.enumerated()), id: \.offset) { _, d in
                HStack(spacing: Theme.gap) {
                    Text(d.asset.code).frame(width: 56, alignment: .leading)
                    Text(Fmt.qtyString(d.quantity)).frame(width: 96, alignment: .trailing)
                    Text(Fmt.unitPriceString(d.bookUnitKRW)).frame(width: 100, alignment: .trailing)
                    Text(d.marketUnitKRW.map { Fmt.unitPriceString($0) } ?? "—").frame(width: 100, alignment: .trailing)
                    Text(Fmt.unitPriceString(d.deemedUnitKRW))
                        .fontWeight(.semibold).frame(width: 100, alignment: .trailing)
                    Text(d.reason == "market" ? "시가" : (d.reason == "actual" ? "실제" : d.reason))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                .font(Theme.mono)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
            }
            Row(label: "합계", value: Fmt.krwString(s.totalDeemedCostKRW), emphasized: true)

            if let alt = s.deemedAlternative {
                Divider()
                let diff = alt.totalTaxKRW - s.totalTaxKRW
                VStack(alignment: .leading, spacing: 4) {
                    Text("다른 방식(\(alt.basisLabel))으로 계산하면")
                        .font(Theme.caption.weight(.semibold))
                    Text("소득 \(Fmt.krwString(alt.netIncomeKRW)) · 세액 \(Fmt.krwString(alt.totalTaxKRW))")
                        .font(Theme.mono).foregroundStyle(.secondary)
                    if diff != 0 {
                        Text("세액이 \(Fmt.krwSigned(diff)) 달라집니다. 어느 쪽이 맞는지는 확정된 해석이 없습니다 (세무 확인 TQ-01).")
                            .font(Theme.caption).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 환율

    private func fxCard(_ c: CalculationResult) -> some View {
        Card(
            title: "적용 환율",
            systemImage: "dollarsign.arrow.circlepath",
            footnote: "고시가 없는 날(휴일 등)은 국세청 서삼46015-11986 취지에 따라 직전 고시일 환율을 쓰고 그 날짜를 함께 남깁니다."
        ) {
            ForEach(Array(c.summary.fxSources.prefix(12).enumerated()), id: \.offset) { _, note in
                Text(note).font(Theme.mono).foregroundStyle(.secondary)
            }
            if c.summary.fxSources.count > 12 {
                Text("외 \(c.summary.fxSources.count - 12)일").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 고지

    private func noticesCard(_ c: CalculationResult) -> some View {
        Card(title: "반드시 확인하세요", systemImage: "exclamationmark.bubble") {
            ForEach(Array(c.summary.disclaimers.enumerated()), id: \.offset) { _, d in
                bullet(d, tone: .neutral)
            }
            Divider()
            ForEach(Array(TaxCopy.notices.enumerated()), id: \.offset) { _, n in
                bullet(n, tone: .neutral)
            }
            Divider()
            let high = TaxOpenQuestions.needsConfirmation.filter { $0.weight == .high }
            Text("세액에 크게 영향을 주는 미확정 항목 \(high.count)건")
                .font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.warning)
            ForEach(high) { q in
                bullet("[\(q.id)] \(q.title)", tone: .warning)
            }
            Button("세무 확인 화면에서 전체 보기") { env.section = .taxNotes }
                .buttonStyle(.link).font(Theme.caption)
        }
    }

    private func bullet(_ text: String, tone: Tone) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundStyle(.tertiary)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bannerIcon: String {
        switch messageTone {
        case .positive: return "checkmark.circle.fill"
        case .danger: return "xmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    // MARK: 동작

    /// 낡은 결과로는 내보내지 않는다
    private var canExport: Bool {
        guard !env.calculationStale else { return false }
        return env.lastCalculation?.verification.isExportAllowed ?? false
    }

    private func calculate() {
        guard let project = env.currentProject else { return }
        busy = true
        message = nil
        Task {
            do {
                let result = try await env.pipeline.calculate(project: project, taxYear: taxYear)
                env.lastCalculation = result
                env.calculationStale = false
                if result.verification.isExportAllowed {
                    set("계산했습니다.", .positive)
                } else {
                    set("검증에서 막힌 항목이 있어 신고자료를 만들 수 없습니다. 아래 «검증 결과» 를 확인하세요.", .danger)
                }
            } catch {
                set("계산하지 못했습니다 — \(error.localizedDescription)", .danger)
            }
            busy = false
        }
    }

    private func exportCSV() {
        guard let s = env.lastCalculation?.summary else { return }
        do {
            let text = try ReportCSVExporter.exportCSV(s)
            guard let url = save(name: "cointax-\(s.taxYear).csv", type: .commaSeparatedText) else { return }
            try text.write(to: url, atomically: true, encoding: .utf8)
            set("저장했습니다 — \(url.lastPathComponent)", .positive)
        } catch {
            set(error.localizedDescription, .danger)
        }
    }

    private func exportPDF() {
        guard let s = env.lastCalculation?.summary else { return }
        do {
            let data = try ReportPDFExporter.exportPDF(s)
            guard let url = save(name: "cointax-\(s.taxYear).pdf", type: .pdf) else { return }
            try data.write(to: url)
            set("저장했습니다 — \(url.lastPathComponent)", .positive)
        } catch {
            set(error.localizedDescription, .danger)
        }
    }

    private func save(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func set(_ text: String, _ tone: Tone) {
        message = text
        messageTone = tone
    }
}
