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

    /// 끝수는 **반올림이 아니라 버림**이다 (국고금 관리법 §47 · 지방세기본법 §59).
    /// 과세표준은 1원 미만, 납부할 세액은 10원 미만을 버린다.
    /// 국세와 지방세는 별개의 징수금이라 **각각** 절사한다 — 합계를 절사하면 국세청 계산과 어긋난다.
    func compute(incomeKRW: Decimal, rounding: RoundingPolicy) -> TaxComputation {
        let taxBase = rounding.floorTaxBaseKRW(max(0, incomeKRW - basicDeductionKRW))
        let national = rounding.floorPayableKRW(taxBase * nationalRate)
        let local = rounding.floorPayableKRW(taxBase * localRate)
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
