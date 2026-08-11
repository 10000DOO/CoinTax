import Foundation

struct TaxComputation: Equatable, Sendable {
    var incomeKRW: Decimal
    var basicDeductionKRW: Decimal
    var taxBaseKRW: Decimal
    var nationalTaxKRW: Decimal
    var localTaxKRW: Decimal
    var totalTaxKRW: Decimal
}

protocol TaxRatePolicy: Sendable {
    var id: String { get }
    var basicDeductionKRW: Decimal { get }
    var nationalRate: Decimal { get }
    var localRate: Decimal { get }
    func compute(incomeKRW: Decimal, rounding: RoundingPolicy) -> TaxComputation
}

struct KROtherIncomeTaxRatePolicy: TaxRatePolicy {
    let id = "kr_other_20_2_deduct_2_5m"
    let basicDeductionKRW: Decimal = 2_500_000
    let nationalRate: Decimal = Decimal(string: "0.20")!
    let localRate: Decimal = Decimal(string: "0.02")!

    func compute(incomeKRW: Decimal, rounding: RoundingPolicy) -> TaxComputation {
        let taxBase = max(0, incomeKRW - basicDeductionKRW)
        let national = rounding.roundKRW(taxBase * nationalRate)
        let local = rounding.roundKRW(taxBase * localRate)
        return TaxComputation(
            incomeKRW: incomeKRW,
            basicDeductionKRW: basicDeductionKRW,
            taxBaseKRW: taxBase,
            nationalTaxKRW: national,
            localTaxKRW: local,
            totalTaxKRW: national + local
        )
    }
}
