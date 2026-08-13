import Foundation

struct PolicyBundle: Sendable {
    var id: String
    var transferCost: any TransferCostPolicy
    var costMethodResolver: any CostMethodResolver
    var deemed: any DeemedCostPolicy
    var taxRate: any TaxRatePolicy
    var rounding: any RoundingPolicy
    var fxAssumption: any FXAssumptionPolicy
    /// `[법]` §37⑥ 필요경비 의제 50% — 기본은 꺼짐 (「할 수 있다」이므로 사용자 선택)
    var proxyExpense: any ProxyExpensePolicy
    var disclaimers: [String]

    static var v1Default: PolicyBundle {
        PolicyBundle(
            // v2.0: 원가법을 거주자별 총평균법으로 교체 (시행령 §88①). 계산 결과가 v1 과 다르다
            id: "cointax-v2.0",
            transferCost: AbandonLostCostPolicy(),
            costMethodResolver: TotalAverageResolver(),
            deemed: MaxBookMarketDeemedPolicy(),
            taxRate: KROtherIncomeTaxRatePolicy(),
            rounding: StatutoryKRWRoundingPolicy(),
            fxAssumption: USDTEqualsUSDAssumption(),
            proxyExpense: StatutoryProxyExpensePolicy(),
            disclaimers: TaxCopy.all
        )
    }

    /// 사용자 설정을 반영한 **현재** 정책 번들.
    ///
    /// 정책은 여기 한 곳에서만 만든다. 화면과 계산 파이프라인이 각자 사본을 들고 있으면
    /// 설정 변경이 한쪽에만 반영돼 표시와 계산이 어긋난다.
    ///
    /// 기본값이 아닌 선택을 하면 **번들 id 에 표시**한다 — 과거 스냅샷과 구분되어야
    /// 나중에 "이 숫자는 어느 정책으로 계산했나"를 답할 수 있다 (design/04-policies §1).
    static var current: PolicyBundle {
        var bundle = v1Default
        // 필요경비 의제 50% 를 켠 자산이 있으면 **번들 id 를 바꾼다** — 같은 자료라도
        // 다른 필요경비로 계산한 숫자이므로 과거 스냅샷과 구분되어야 한다
        let proxyAssets = ProxyExpensePreferences.enabledAssets
        if !proxyAssets.isEmpty {
            let p = StatutoryProxyExpensePolicy(enabledAssets: proxyAssets)
            bundle.proxyExpense = p
            bundle.id = "\(v1Default.id)+\(p.id)"
        }
        let mode = DeemedPreferences.basisMode
        bundle.deemed = MaxBookMarketDeemedPolicy(mode: mode)
        if mode != .positionAverage {
            bundle.id = "\(v1Default.id)+deemed_\(mode.rawValue)"
        }
        return bundle
    }
}
