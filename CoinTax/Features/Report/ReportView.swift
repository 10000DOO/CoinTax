import SwiftUI

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
                        .disabled(!(env.lastCalculation?.verification.isExportAllowed ?? false))
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

                    GroupBox("의제 취득가") {
                        if s.deemed.isEmpty {
                            Text("해당 없음")
                        } else {
                            ForEach(Array(s.deemed.enumerated()), id: \.offset) { _, d in
                                Text("\(d.asset.code) qty=\(Money.decimalString(d.quantity)) 장부=\(Money.decimalString(d.bookUnitKRW)) 시가=\(d.marketUnitKRW.map { Money.decimalString($0) } ?? "-") 의제=\(Money.decimalString(d.deemedUnitKRW)) (\(d.reason))")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                    GroupBox("검증 이슈") {
                        if c.verification.issues.isEmpty {
                            Text("없음")
                        } else {
                            ForEach(c.verification.issues) { issue in
                                Text("[\(issue.severity)] \(issue.id): \(issue.message)")
                                    .foregroundStyle(issue.severity == "critical" ? .red : .primary)
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

    private func runCalc() {
        guard let project = env.currentProject else { return }
        do {
            let result = try env.pipeline.calculate(project: project, taxYear: taxYear)
            env.lastCalculation = result
            message = "계산 완료 — \(result.verification.status)"
        } catch {
            message = "계산 오류: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        guard let s = env.lastCalculation?.summary else { return }
        do {
            exportText = try ReportCSVExporter.exportCSV(s)
            message = "CSV 생성 완료"
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
