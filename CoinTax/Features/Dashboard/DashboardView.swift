import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("대시보드")
                .font(.largeTitle.bold())
            if let p = env.currentProject {
                GroupBox("프로젝트") {
                    LabeledContent("이름", value: p.name)
                    LabeledContent("기본 과세연도", value: "\(p.defaultTaxYear)")
                    LabeledContent("계정", value: "\(p.accounts.count)개")
                    LabeledContent("이벤트", value: "\(p.events.count)건")
                    LabeledContent("전송 링크", value: "\(p.links.count)건")
                }
            }
            GroupBox("정책") {
                LabeledContent("PolicyBundle", value: env.policies.id)
                Text(TaxCopy.notTaxAdvice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
