import SwiftUI
import AppKit

/// 세무 확인이 필요하거나 법령 개정 시 다시 봐야 하는 항목 목록.
///
/// 앱이 지금 쓰는 가정을 사용자가 직접 볼 수 있게 하고,
/// 세무사에게 그대로 읽어 물어볼 수 있는 문장을 함께 제공한다.
struct TaxOpenQuestionsView: View {
    @State private var filter: Filter = .needsConfirmation
    @State private var expanded: Set<String> = []
    @State private var copied: String?

    enum Filter: String, CaseIterable, Identifiable {
        case needsConfirmation, watchLegislation, confirmed, all
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
        let list: [TaxOpenQuestion]
        switch filter {
        case .all: list = TaxOpenQuestions.all
        case .needsConfirmation: list = TaxOpenQuestions.needsConfirmation
        case .watchLegislation: list = TaxOpenQuestions.watchLegislation
        case .confirmed: list = TaxOpenQuestions.confirmed
        }
        // 세액 영향이 큰 것부터
        return list.sorted { weightRank($0.weight) < weightRank($1.weight) }
    }

    private func weightRank(_ w: TaxOpenQuestion.Weight) -> Int {
        switch w {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    var body: some View {
        Page(title: "세무 확인", subtitle: "확정된 해석이 없어 앱이 가정을 두고 계산한 항목입니다") {
            Button {
                copyAll()
            } label: {
                Label(copied == "all" ? "복사됨" : "전체 복사", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        } content: {
            Card {
                Text("아래 항목은 법령·국세청 안내에 명확한 답이 없습니다. 앱은 **세금이 과소 신고되지 않는 쪽**으로 가정했습니다. 신고 전에 세무사에게 확인하시고, 답이 달라지면 설정이나 계산이 바뀔 수 있습니다.")
                    .font(Theme.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.gap) {
                    StatTile(label: "확인 필요", value: "\(TaxOpenQuestions.needsConfirmation.count)건", tone: .warning)
                    StatTile(label: "세액 영향 큼",
                             value: "\(TaxOpenQuestions.all.filter { $0.weight == .high }.count)건", tone: .danger)
                    StatTile(label: "개정 감시", value: "\(TaxOpenQuestions.watchLegislation.count)건")
                    StatTile(label: "근거 확인됨", value: "\(TaxOpenQuestions.confirmed.count)건", tone: .positive)
                }
            }

            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 400)

            ForEach(items) { q in questionCard(q) }

            Text(TaxCopy.notTaxAdvice)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func questionCard(_ q: TaxOpenQuestion) -> some View {
        let isOpen = expanded.contains(q.id)
        return Card {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isOpen { expanded.remove(q.id) } else { expanded.insert(q.id) }
                }
            } label: {
                HStack(alignment: .top, spacing: Theme.gap) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text(q.id).font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Pill(text: q.kind.label, tone: kindTone(q.kind))
                            if q.weight == .high { Pill(text: q.weight.label, tone: .danger) }
                        }
                        Text(q.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Divider()
                section("지금 앱이 쓰는 가정", q.currentAssumption, tone: .accent)
                section("세무사에게 물어볼 것", q.whatToAsk, tone: .warning, copyable: q)
                section("답이 달라지면", q.impact, tone: .neutral)
                if let basis = q.basis { section("근거", basis, tone: .neutral, mono: true) }
                if let sp = q.switchPoint { section("바꿀 곳", sp, tone: .neutral, mono: true) }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ text: String, tone: Tone, mono: Bool = false, copyable: TaxOpenQuestion? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
                if let q = copyable {
                    Button {
                        copy(q.whatToAsk, id: q.id)
                    } label: {
                        Image(systemName: copied == q.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("질문 문장 복사")
                }
            }
            Text(.init(text))
                .font(mono ? Theme.mono : Theme.body)
                .foregroundStyle(mono ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kindTone(_ k: TaxOpenQuestion.Kind) -> Tone {
        switch k {
        case .needsConfirmation: return .warning
        case .watchLegislation: return .accent
        case .confirmed: return .positive
        }
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = id
        Task { try? await Task.sleep(for: .seconds(2)); if copied == id { copied = nil } }
    }

    private func copyAll() {
        let text = items.map { q in
            """
            [\(q.id)] \(q.title)
            현재 가정: \(q.currentAssumption.replacingOccurrences(of: "\n", with: " "))
            질문: \(q.whatToAsk.replacingOccurrences(of: "\n", with: " "))
            """
        }.joined(separator: "\n\n")
        copy(text, id: "all")
    }
}
