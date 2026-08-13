import Foundation

/// 취득가액을 증명하지 못할 때 **판 금액의 일정 비율**을 필요경비로 쓰는 길.
///
/// > `[법]` 소득세법 §37⑥ (2024-12-31 신설 · 2027-01-01 시행)
/// > 제1항제3호에도 불구하고 대통령령으로 정하는 사유로 **2027년 1월 1일 이후 취득하는**
/// > 가상자산의 실제 취득가액을 확인하기 곤란한 경우에는 해당 가상자산과 **같은 종류의
/// > 가상자산 전체**의 양도에 따른 필요경비를 그 가상자산 전체의 **총양도가액**에
/// > 100분의 50 이하의 범위에서 대통령령으로 정하는 비율을 곱한 금액으로 **할 수 있다.**
/// > 이 경우 **부대비용은 필요경비에 산입하지 아니한다.**
///
/// > `[영]` §88④1 — 가상자산사업자를 통하지 않고 취득한 경우로서 장부나 그 밖의 증명서류에
/// > 의하여 실제취득가액을 확인할 수 없는 경우
/// > `[영]` §88⑤ — "대통령령으로 정하는 비율"이란 **100분의 50**을 말한다.
///
/// 세 가지를 지켜야 한다.
///
/// 1. **의무가 아니라 선택**이다("할 수 있다"). 유리한 쪽을 고르는 길이므로 앱이 멋대로 켜지 않는다.
/// 2. **자산(종류)별 일괄**이다. 그 종류 코인 한 건만 증빙이 없어도, 켜면 그 해 **그 종류 처분 전체**에 걸린다.
/// 3. **부대비용을 못 뺀다.** 수수료를 따로 더 빼면 조문 후단을 어긴다.
///
/// **요건과 효과의 범위가 어긋난다** — 요건은 「2027 이후 취득분의 확인 곤란」인데 효과는
/// 「같은 종류 전체」다. 2026년 이전 보유분(§37⑤ 의제취득가 트랙)까지 휩쓸리는지 조문이
/// 답하지 않는다 (백서 U-24). 그래서 앱은 단정하지 않고 **사용자가 켜고 끄며 두 값을 비교**하게 한다.
protocol ProxyExpensePolicy: Sendable {
    var id: String { get }
    /// 총양도가액에 곱할 비율
    var ratio: Decimal { get }
    /// 이 방식을 적용할 자산 (종류별 on/off)
    var enabledAssets: Set<String> { get }
    func isEnabled(_ asset: AssetSymbol) -> Bool
    /// 그 자산의 **총양도가액**에 대한 필요경비
    func necessaryExpense(totalProceedsKRW: Decimal) -> Decimal
}

extension ProxyExpensePolicy {
    func isEnabled(_ asset: AssetSymbol) -> Bool { enabledAssets.contains(asset.code) }
    func necessaryExpense(totalProceedsKRW: Decimal) -> Decimal { totalProceedsKRW * ratio }
}

struct StatutoryProxyExpensePolicy: ProxyExpensePolicy {
    /// `[영]` §88⑤ — 100분의 50
    let ratio: Decimal = Decimal(string: "0.5")!
    var enabledAssets: Set<String>

    init(enabledAssets: Set<String> = []) {
        self.enabledAssets = enabledAssets
    }

    var id: String {
        enabledAssets.isEmpty
            ? "proxy_expense_off"
            : "proxy_expense_50_\(enabledAssets.sorted().joined(separator: "-"))"
    }
}

enum ProxyExpensePreferences {
    private static let key = "proxyExpense.assets"

    /// 사용자가 「취득가 증명 불가」로 표시한 자산 코드
    static var enabledAssets: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: key) }
    }
}
