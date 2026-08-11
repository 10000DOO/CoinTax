import Foundation

struct PolicyBundle: Sendable {
    var id: String
    var transferCost: any TransferCostPolicy
    var costMethodResolver: any CostMethodResolver
    var deemed: any DeemedCostPolicy
    var taxRate: any TaxRatePolicy
    var rounding: any RoundingPolicy
    var fxAssumption: any FXAssumptionPolicy
    var disclaimers: [String]

    static var v1Default: PolicyBundle {
        PolicyBundle(
            id: "cointax-v1.0",
            transferCost: AbandonLostCostPolicy(),
            costMethodResolver: VASPMAElseFIFOResolver(),
            deemed: MaxBookMarketDeemedPolicy(),
            taxRate: KROtherIncomeTaxRatePolicy(),
            rounding: PlainKRWRoundingPolicy(),
            fxAssumption: USDTEqualsUSDAssumption(),
            disclaimers: TaxCopy.all
        )
    }
}
