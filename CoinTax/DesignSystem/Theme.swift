import SwiftUI

/// 화면 전체가 같은 규칙을 쓰도록 모아둔 값들.
///
/// 화면마다 여백·모서리·색을 따로 정하면 만들 때는 편하지만 쌓이면 «각자 다른 앱» 처럼 보인다.
/// 새 화면을 만들 때는 여기 있는 값만 쓴다.
enum Theme {

    // MARK: 간격 — 4의 배수로만 움직인다

    /// 한 덩어리 안에서 붙는 요소 사이
    static let gapTight: CGFloat = 6
    /// 카드 안 항목 사이
    static let gap: CGFloat = 12
    /// 카드와 카드 사이
    static let gapCard: CGFloat = 16
    /// 섹션과 섹션 사이
    static let gapSection: CGFloat = 28
    /// 화면 바깥 여백
    static let pagePadding: CGFloat = 24
    /// 카드 안쪽 여백
    static let cardPadding: CGFloat = 18

    // MARK: 모서리

    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
    static let radiusPill: CGFloat = 999

    // MARK: 색 — 의미로 부른다 (파랑/초록이 아니라 accent/positive)

    static let pageBackground = Color(nsColor: .underPageBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    /// 카드 위에 한 겹 더 올릴 때 (표 머리글 등)
    static let subtleBackground = Color.primary.opacity(0.04)
    static let hairline = Color.primary.opacity(0.09)

    static let positive = Color(red: 0.10, green: 0.62, blue: 0.40)
    static let warning = Color(red: 0.87, green: 0.57, blue: 0.06)
    static let danger = Color(red: 0.84, green: 0.25, blue: 0.25)
    static let neutral = Color.secondary

    /// 손익 표시 — 국내 관례대로 이익 빨강 / 손실 파랑
    static func pnlColor(_ value: Decimal) -> Color {
        if value > 0 { return Color(red: 0.83, green: 0.24, blue: 0.28) }
        if value < 0 { return Color(red: 0.16, green: 0.42, blue: 0.84) }
        return .secondary
    }

    // MARK: 글자

    static let pageTitle = Font.system(size: 26, weight: .bold)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let cardTitle = Font.system(size: 14, weight: .semibold)
    /// 큰 숫자 — 자릿수가 흔들리지 않게 고정폭
    static let heroNumber = Font.system(size: 34, weight: .bold, design: .rounded).monospacedDigit()
    static let tileNumber = Font.system(size: 20, weight: .semibold).monospacedDigit()
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)
}

/// 상태를 색 하나로 통일해서 부른다.
enum Tone {
    case neutral, accent, positive, warning, danger

    var color: Color {
        switch self {
        case .neutral: return Theme.neutral
        case .accent: return .accentColor
        case .positive: return Theme.positive
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        }
    }
}
