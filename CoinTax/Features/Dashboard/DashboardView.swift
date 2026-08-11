import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var message = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("대시보드")
                    .font(.largeTitle.bold())
                if let p = env.currentProject {
                    GroupBox("프로젝트") {
                        LabeledContent("이름", value: p.name)
                        LabeledContent("기본 과세연도", value: "\(p.defaultTaxYear)")
                        LabeledContent("계정", value: "\(p.accounts.count)개")
                        LabeledContent("이벤트", value: "\(p.events.count)건")
                        LabeledContent("전송 링크(확정)", value: "\(p.links.filter { $0.status == LinkStatus.confirmed.rawValue }.count)건")
                        LabeledContent("원본 파일", value: "\(p.sourceFiles.count)개")
                    }

                    let missingFX = env.fxService.missingDays(
                        for: env.projectService.domainEvents(for: p),
                        project: p
                    )
                    if !missingFX.isEmpty {
                        GroupBox("환율 누락") {
                            Text(missingFX.joined(separator: ", "))
                                .foregroundStyle(.orange)
                            Text("설정 화면에서 수동 입력 후 리포트에서 재계산하세요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("지금 계산 (기본 연도)") { runCalc(project: p) }
                        if !message.isEmpty {
                            Text(message).foregroundStyle(.secondary)
                        }
                    }
                }

                if let c = env.lastCalculation {
                    GroupBox("최근 계산") {
                        LabeledContent("연도", value: "\(c.summary.taxYear)")
                        LabeledContent("검증", value: c.verification.status)
                        LabeledContent("소득", value: Money.decimalString(c.summary.netIncomeKRW))
                        LabeledContent("예상 세액", value: Money.decimalString(c.summary.totalTaxKRW))
                        LabeledContent("보유 행", value: "\(c.replay.holdings.rows.count)")
                        LabeledContent("소실 원가(참고)", value: Money.decimalString(c.summary.abandonedTransferCostKRW))
                    }
                }

                GroupBox("정책") {
                    LabeledContent("PolicyBundle", value: env.policies.id)
                    Text(TaxCopy.notTaxAdvice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func runCalc(project: ProjectEntity) {
        do {
            let result = try env.pipeline.calculate(project: project, taxYear: project.defaultTaxYear)
            env.lastCalculation = result
            message = "계산 완료 — \(result.verification.status)"
        } catch {
            message = error.localizedDescription
        }
    }
}
