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
                    GroupBox("요약") {
                        LabeledContent("정책", value: s.policyBundleID)
                        LabeledContent("상태", value: s.status.rawValue)
                        LabeledContent("검증", value: c.verification.status)
                        LabeledContent("소득", value: Money.decimalString(s.netIncomeKRW))
                        LabeledContent("과세표준", value: Money.decimalString(s.taxBaseKRW))
                        LabeledContent("국세", value: Money.decimalString(s.nationalTaxKRW))
                        LabeledContent("지방세", value: Money.decimalString(s.localTaxKRW))
                        LabeledContent("합계 세액", value: Money.decimalString(s.totalTaxKRW))
                        LabeledContent("전송 소실 원가(참고)", value: Money.decimalString(s.abandonedTransferCostKRW))
                    }
                    GroupBox("의제 취득가") {
                        if s.deemed.isEmpty {
                            Text("해당 없음")
                        } else {
                            ForEach(Array(s.deemed.enumerated()), id: \.offset) { _, d in
                                Text("\(d.asset.code) qty=\(Money.decimalString(d.quantity)) unit=\(Money.decimalString(d.deemedUnitKRW)) (\(d.reason))")
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
                    GroupBox("고지") {
                        ForEach(s.disclaimers, id: \.self) { d in
                            Text("• \(d)")
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
}
