import SwiftUI

/// 세무 확인이 필요하거나 법령 개정 시 다시 봐야 하는 항목 목록.
///
/// 앱이 지금 쓰는 가정을 사용자가 직접 볼 수 있게 하고,
/// 세무사에게 그대로 읽어 물어볼 수 있는 문장을 함께 제공한다.
struct TaxOpenQuestionsView: View {
    @State private var filter: Filter = .all
    @State private var expanded: Set<String> = []
    @State private var copied: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all, needsConfirmation, watchLegislation, confirmed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "전체"
            case .needsConfirmation: return "확인 필요"
            case .watchLegislation: return "개정 감시"
            case .confirmed: return "근거 확인됨"
            }
        }
    }

    private var items: [TaxOpenQuestion] {
        switch filter {
        case .all: return TaxOpenQuestions.all
        case .needsConfirmation: return TaxOpenQuestions.needsConfirmation
        case .watchLegislation: return TaxOpenQuestions.watchLegislation
        case .confirmed: return TaxOpenQuestions.confirmed
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                ForEach(items) { q in
                    card(q)
                }

                Text(TaxCopy.notTaxAdvice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("세무 확인")
                .font(.largeTitle.bold())
            Text("이 앱이 세금을 계산할 때 쓰는 가정 중, **확정된 해석이 없어 확인이 필요한 것**과 **법이 바뀌면 다시 봐야 하는 것**을 모았습니다.")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Label("확인 필요 \(TaxOpenQuestions.needsConfirmation.count)건", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
                Label("개정 감시 \(TaxOpenQuestions.watchLegislation.count)건", systemImage: "eye")
                    .foregroundStyle(.blue)
                Label("근거 확인됨 \(TaxOpenQuestions.confirmed.count)건", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
                Spacer()
                Button {
                    copyAll()
                } label: {
                    Label("전체 질문 복사", systemImage: "doc.on.doc")
                }
                .help("세무사에게 보낼 수 있도록 모든 질문을 클립보드에 복사합니다")
            }
            .font(.callout)
            if let copied {
                Text(copied)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func card(_ q: TaxOpenQuestion) -> some View {
        let isOpen = expanded.contains(q.id)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(q.id)
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(q.title)
                        .font(.headline)
                    Spacer()
                    badge(q.kind.label, color: kindColor(q.kind))
                    badge(q.weight.label, color: weightColor(q.weight))
                }

                labeled("지금 앱이 쓰는 가정", q.currentAssumption)

                if isOpen {
                    labeled("무엇을 물어봐야 하나", q.whatToAsk, mono: true)
                    labeled("결론이 바뀌면", q.impact)
                    if let basis = q.basis {
                        labeled("근거·참고", basis)
                    }
                    if let point = q.switchPoint {
                        labeled("바꿀 지점", point)
                    }
                }

                HStack {
                    Button(isOpen ? "접기" : "질문 문장 보기") {
                        if isOpen { expanded.remove(q.id) } else { expanded.insert(q.id) }
                    }
                    .buttonStyle(.borderless)
                    if isOpen {
                        Button("이 질문 복사") { copy(q) }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.caption)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func labeled(_ title: String, _ body: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(mono ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private func kindColor(_ k: TaxOpenQuestion.Kind) -> Color {
        switch k {
        case .needsConfirmation: return .orange
        case .watchLegislation: return .blue
        case .confirmed: return .green
        }
    }

    private func weightColor(_ w: TaxOpenQuestion.Weight) -> Color {
        switch w {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    private func copy(_ q: TaxOpenQuestion) {
        let text = """
        [\(q.id)] \(q.title)

        ● 질문
        \(q.whatToAsk)

        ● 현재 저희 쪽 가정
        \(q.currentAssumption)

        ● 결론이 바뀌면
        \(q.impact)
        """
        write(text, note: "\(q.id) 질문을 복사했습니다")
    }

    private func copyAll() {
        let body = TaxOpenQuestions.all.map { q in
            """
            [\(q.id)] \(q.title)
            질문: \(q.whatToAsk)
            현재 가정: \(q.currentAssumption)
            영향: \(q.impact)
            """
        }.joined(separator: "\n\n———\n\n")

        let text = """
        가상자산 기타소득 신고 준비 — 확인이 필요한 항목 \(TaxOpenQuestions.all.count)건

        \(body)
        """
        write(text, note: "\(TaxOpenQuestions.all.count)건 전체를 복사했습니다")
    }

    private func write(_ text: String, note: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = note
    }
}
