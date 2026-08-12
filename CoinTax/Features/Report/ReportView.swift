import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ReportView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var taxYear: Int = 2027
    @State private var message = ""
    @State private var exportText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("리포트")
                    .font(.largeTitle.bold())
                HStack {
                    Stepper("과세연도 \(taxYear)", value: $taxYear, in: 2027...2035)
                    Button("계산") { runCalc() }
                    Button("CSV 내보내기") { exportCSV() }
                        .disabled(!canExport)
                    Button("PDF 내보내기") { exportPDF() }
                        .disabled(!canExport)
                }
                if env.calculationStale {
                    Text("가져온 자료나 전송 연결이 바뀌었습니다 — 재계산 전까지 아래 숫자는 낡은 결과이고 내보내기가 잠깁니다.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if let c = env.lastCalculation {
                    let s = c.summary
                    verificationBadge(c.verification.status)

                    GroupBox("과세연도 요약") {
                        LabeledContent("PolicyBundle", value: s.policyBundleID)
                        LabeledContent("상태", value: s.status.rawValue)
                        LabeledContent("검증", value: c.verification.status)
                        Divider()
                        LabeledContent("총수입(양도가)", value: Money.decimalString(s.totalProceedsKRW) + " 원")
                        LabeledContent("필요경비(원가+수수료)", value: Money.decimalString(s.totalCostsKRW) + " 원")
                        LabeledContent("소득금액", value: Money.decimalString(s.netIncomeKRW) + " 원")
                        LabeledContent("기본공제", value: Money.decimalString(s.basicDeductionKRW) + " 원")
                        LabeledContent("과세표준", value: Money.decimalString(s.taxBaseKRW) + " 원")
                        LabeledContent("국세(20%)", value: Money.decimalString(s.nationalTaxKRW) + " 원")
                        LabeledContent("지방세(2%)", value: Money.decimalString(s.localTaxKRW) + " 원")
                        LabeledContent("예상 세액 합계", value: Money.decimalString(s.totalTaxKRW) + " 원")
                        LabeledContent("전송 소실 원가(참고·비공제)", value: Money.decimalString(s.abandonedTransferCostKRW) + " 원")
                    }

                    GroupBox("자산별 실현손익 집계") {
                        let byAsset = Dictionary(grouping: s.disposals, by: { $0.asset.code })
                        if byAsset.isEmpty {
                            Text("해당 없음").foregroundStyle(.secondary)
                        } else {
                            ForEach(byAsset.keys.sorted(), id: \.self) { code in
                                let rows = byAsset[code] ?? []
                                let pnl = rows.reduce(Decimal(0)) { $0 + $1.pnlKRW }
                                let proceeds = rows.reduce(Decimal(0)) { $0 + $1.proceedsKRW }
                                Text("\(code): \(rows.count)건  양도 \(Money.decimalString(proceeds))  PnL \(Money.decimalString(pnl))")
                                    .font(.caption.monospaced())
                            }
                        }
                    }

                    GroupBox("실현손익 건별 (\(s.disposals.count))") {
                        if s.disposals.isEmpty {
                            Text("해당 연도 과세 처분 없음")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(s.disposals.enumerated()), id: \.offset) { _, d in
                                HStack {
                                    Text(d.asset.code).frame(width: 50, alignment: .leading)
                                    Text(Money.decimalString(d.quantity)).frame(width: 70, alignment: .trailing)
                                    Text("양도 \(Money.decimalString(d.proceedsKRW))")
                                    Text("원가 \(Money.decimalString(d.costKRW))")
                                    Text("PnL \(Money.decimalString(d.pnlKRW))")
                                        .foregroundStyle(d.pnlKRW >= 0 ? Color.primary : Color.red)
                                }
                                .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }

                    GroupBox("의제 취득가 (\(DeemedBasisMode(rawValue: s.deemedBasisMode)?.label ?? s.deemedBasisMode))") {
                        if s.deemed.isEmpty {
                            Text("해당 없음")
                        } else {
                            ForEach(Array(s.deemed.enumerated()), id: \.offset) { _, d in
                                Text("\(d.asset.code) qty=\(Money.decimalString(d.quantity)) 장부=\(Money.decimalString(d.bookUnitKRW)) 시가=\(d.marketUnitKRW.map { Money.decimalString($0) } ?? "-") 의제=\(Money.decimalString(d.deemedUnitKRW)) (\(d.reason), lot \(d.lotCount))")
                                    .font(.caption.monospaced())
                            }
                            LabeledContent("의제 취득가 합계", value: Money.decimalString(Money.roundKRW(s.totalDeemedCostKRW)) + " 원")
                            if let alt = s.deemedAlternative {
                                Divider()
                                Text("다른 방식(\(alt.basisLabel))으로 계산하면")
                                    .font(.caption.weight(.semibold))
                                Text("의제 취득가 \(Money.decimalString(Money.roundKRW(alt.totalDeemedCostKRW))) · 소득 \(Money.decimalString(Money.roundKRW(alt.netIncomeKRW))) · 예상 세액 \(Money.decimalString(Money.roundKRW(alt.totalTaxKRW))) 원")
                                    .font(.caption.monospaced())
                                let diff = alt.totalTaxKRW - s.totalTaxKRW
                                if diff != 0 {
                                    Text("→ 세액 차이 \(Money.decimalString(Money.roundKRW(diff))) 원. 어느 방식이 맞는지는 세무 확인 대기 항목입니다 (세무 확인 화면 TQ-01).")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    if !s.fxSources.isEmpty {
                        GroupBox("적용 환율 출처") {
                            ForEach(Array(s.fxSources.enumerated()), id: \.offset) { _, note in
                                Text(note).font(.caption.monospaced())
                            }
                            Text("휴일·미고시일은 국세청 서삼46015-11986 취지에 따라 직전 고시일 환율을 적용하고 그 고시일을 함께 기록합니다.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("검증 이슈") {
                        if c.verification.issues.isEmpty {
                            Text("없음")
                        } else {
                            // 같은 검증 ID가 여러 건 나올 수 있어 offset 을 식별자로 쓴다 (리뷰 4-6)
                            ForEach(Array(c.verification.issues.enumerated()), id: \.offset) { _, issue in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("[\(issue.severity)] \(issue.id): \(issue.message)")
                                        .foregroundStyle(issue.severity == "critical" ? .red : .primary)
                                    if let ctx = issue.context, !ctx.isEmpty {
                                        Text(ctx).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                    GroupBox("고지 (필수 4종)") {
                        ForEach(Array(s.disclaimers.enumerated()), id: \.offset) { i, d in
                            Text("\(i + 1). \(d)")
                                .font(.caption)
                                .padding(.bottom, 2)
                        }
                    }
                    GroupBox("세무 확인이 필요한 항목 (\(TaxOpenQuestions.needsConfirmation.count)건)") {
                        Text("아래 항목은 확정된 해석이 없어 앱이 가정을 두고 계산했습니다. 신고 전 「세무 확인」 화면에서 내용을 확인하세요.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(TaxOpenQuestions.needsConfirmation.filter { $0.weight == .high }) { q in
                            Text("• [\(q.id)] \(q.title)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text("그 외 \(TaxOpenQuestions.all.count - TaxOpenQuestions.needsConfirmation.filter { $0.weight == .high }.count)건은 「세무 확인」 화면에 있습니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    GroupBox("주의사항") {
                        ForEach(Array(TaxCopy.notices.enumerated()), id: \.offset) { _, n in
                            Text("• \(n)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                        }
                    }
                }
                if !message.isEmpty {
                    Text(message).foregroundStyle(.secondary)
                }
                if let exportText {
                    GroupBox("Export 미리보기") {
                        Text(exportText).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .padding()
        }
        .onAppear {
            taxYear = env.currentProject?.defaultTaxYear ?? 2027
        }
    }

    /// 낡은 결과로는 내보내지 않는다
    private var canExport: Bool {
        guard !env.calculationStale else { return false }
        return env.lastCalculation?.verification.isExportAllowed ?? false
    }

    private func runCalc() {
        guard let project = env.currentProject else { return }
        message = "계산 중… (환율 자동 조회 포함)"
        Task {
            do {
                let result = try await env.pipeline.calculate(project: project, taxYear: taxYear)
                env.lastCalculation = result
                env.calculationStale = false
                message = "계산 완료 — \(result.verification.status)"
            } catch {
                message = "계산 오류: \(error.localizedDescription)"
            }
        }
    }

    private func exportCSV() {
        guard let s = env.lastCalculation?.summary else { return }
        do {
            exportText = try ReportCSVExporter.exportCSV(s)
            message = "CSV 생성 완료"
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "cointax-\(s.taxYear).csv"
            if panel.runModal() == .OK, let url = panel.url {
                try exportText?.write(to: url, atomically: true, encoding: .utf8)
                message = "CSV 저장: \(url.lastPathComponent)"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func exportPDF() {
        guard let s = env.lastCalculation?.summary else { return }
        do {
            let data = try ReportPDFExporter.exportPDF(s)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "cointax-\(s.taxYear).pdf"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                message = "PDF 저장: \(url.lastPathComponent)"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    @ViewBuilder
    private func verificationBadge(_ status: String) -> some View {
        let color: Color = {
            switch status {
            case "passed": return .green
            case "passedWithWarnings": return .orange
            default: return .red
            }
        }()
        let label: String = {
            switch status {
            case "passed": return "검증 통과"
            case "passedWithWarnings": return "검증 통과(경고)"
            default: return "검증 실패 — export 잠금"
            }
        }()
        Text(label)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}
