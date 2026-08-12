import SwiftUI

// MARK: - 페이지 뼈대

/// 모든 화면의 공통 틀 — 제목 · 부제 · 오른쪽 액션 · 스크롤 본문.
///
/// 화면마다 제목 크기와 여백을 따로 잡으면 화면을 옮길 때마다 레이아웃이 튄다.
struct Page<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapCard) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.pageTitle)
                        if let subtitle {
                            Text(subtitle)
                                .font(Theme.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: Theme.gapCard)
                    HStack(spacing: Theme.gapTight) { actions() }
                }
                .padding(.bottom, 2)

                content()
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.pageBackground)
    }
}

extension Page where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, actions: { EmptyView() }, content: content)
    }
}

/// 표처럼 **스스로 스크롤하는 것**을 담는 화면.
///
/// `Page` 는 바깥에 ScrollView 가 있어서 안에 `Table` 을 넣으면 스크롤이 두 겹이 된다
/// (휠을 굴리면 어느 쪽이 움직일지 예측할 수 없다). 그럴 땐 이걸 쓴다.
struct FullPage<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapCard) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.pageTitle)
                    if let subtitle {
                        Text(subtitle).font(Theme.body).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.gapCard)
                HStack(spacing: Theme.gapTight) { actions() }
            }
            content()
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.pageBackground)
    }
}

// MARK: - 카드

/// 내용 한 묶음. 제목은 없어도 된다.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(title).font(Theme.cardTitle)
                }
            }
            content()
            if let footnote {
                Text(footnote)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - 상태 표시

/// 짧은 상태 라벨. 색으로 의미를 전달한다.
struct Pill: View {
    let text: String
    var tone: Tone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.color.opacity(0.14), in: Capsule())
        .foregroundStyle(tone.color)
    }
}

/// 화면 맨 위에 붙는 안내·경고 줄.
struct Banner: View {
    let text: String
    var tone: Tone = .warning
    var systemImage: String = "exclamationmark.triangle.fill"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
                .font(.system(size: 13))
            Text(text)
                .font(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .foregroundStyle(tone.color)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall)
                .strokeBorder(tone.color.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - 숫자

/// 지표 하나. 큰 숫자 + 설명.
struct StatTile: View {
    let label: String
    let value: String
    var caption: String?
    var tone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(Theme.tileNumber)
                .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }
}

/// 「항목 ─ 값」 한 줄. 값은 자릿수가 흔들리지 않게 고정폭.
struct Row: View {
    let label: String
    let value: String
    var tone: Tone = .neutral
    var emphasized = false
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.gap) {
            HStack(spacing: 4) {
                Text(label)
                    .font(emphasized ? .system(size: 13, weight: .semibold) : Theme.body)
                    .foregroundStyle(emphasized ? Color.primary : .secondary)
                if let help {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help(help)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: emphasized ? 15 : 13, weight: emphasized ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
        }
    }
}

// MARK: - 빈 화면

/// 「아직 아무것도 없음」 상태. 무엇을 해야 하는지 같이 알려준다.
struct EmptyState: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.gap) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            if let message {
                Text(message)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 진행 단계

/// 「시작하기」 체크리스트의 한 줄.
struct StepRow: View {
    enum State { case done, action, waiting }

    let index: Int
    let title: String
    let detail: String
    let state: State
    var actionTitle: String?
    var action: (() -> Void)?

    private var tone: Tone {
        switch state {
        case .done: return .positive
        case .action: return .warning
        case .waiting: return .neutral
        }
    }

    private var icon: String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .action: return "exclamationmark.circle.fill"
        case .waiting: return "\(index).circle"
        }
    }

    var body: some View {
        HStack(spacing: Theme.gap) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(state == .waiting ? Color.secondary.opacity(0.6) : tone.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: state == .done ? .regular : .semibold))
                    .foregroundStyle(state == .done ? .secondary : .primary)
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - 표

/// 표 머리글 한 줄 (Table 을 쓰기 애매한 좁은 목록용).
struct TableHeader: View {
    let columns: [(String, CGFloat?, Alignment)]

    var body: some View {
        HStack(spacing: Theme.gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                Text(c.0)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: c.1, alignment: c.2)
                    .frame(maxWidth: c.1 == nil ? .infinity : nil, alignment: c.2)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 버튼

extension View {
    /// 화면의 «주 동작» 하나에만 쓴다. 여러 개면 무엇을 눌러야 할지 알 수 없다.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent).controlSize(.large)
    }
}
