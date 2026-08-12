import Foundation

enum TaxAggregator {
    static func aggregate(
        projectID: ProjectID,
        disposals: [DisposalRecord],
        taxYear: Int,
        extraDeductible: Decimal,
        abandonedTransferCostKRW: Decimal,
        deemed: [DeemedPosition],
        policies: PolicyBundle,
        status: SummaryStatus = .draft
    ) -> TaxYearSummary {
        let tTax = TaxTime.taxStartDate
        // 과세 시작(2027) 이전 연도를 고르면 「그때도 이 규정이 있었다면」을 보는 예상 계산이다.
        // 실제 신고 대상이 아니므로 과세 시작일 컷오프를 걸지 않는다 — 걸면 늘 0건이라
        // 2027년이 오기 전에는 자기 손익을 볼 방법이 없다.
        let preview = taxYear < TaxTime.taxStartYear
        let ds = disposals.filter {
            TaxTime.calendarYearKST($0.timestamp) == taxYear && (preview || $0.timestamp >= tTax)
        }
        let proceeds = ds.reduce(Decimal(0)) { $0 + $1.proceedsKRW }
        let costSum = ds.reduce(Decimal(0)) { $0 + $1.costKRW + $1.feesKRW } + extraDeductible
        let income = ds.reduce(Decimal(0)) { $0 + $1.pnlKRW } - extraDeductible
        let tax = policies.taxRate.compute(incomeKRW: income, rounding: policies.rounding)

        return TaxYearSummary(
            projectID: projectID,
            taxYear: taxYear,
            status: status,
            policyBundleID: policies.id,
            totalProceedsKRW: proceeds,
            totalCostsKRW: costSum,
            netIncomeKRW: income,
            basicDeductionKRW: tax.basicDeductionKRW,
            taxBaseKRW: tax.taxBaseKRW,
            nationalTaxKRW: tax.nationalTaxKRW,
            localTaxKRW: tax.localTaxKRW,
            totalTaxKRW: tax.totalTaxKRW,
            abandonedTransferCostKRW: abandonedTransferCostKRW,
            extraDeductibleKRW: extraDeductible,
            disposals: ds,
            deemed: deemed,
            disclaimers: policies.disclaimers,
            calculatedAt: Date(),
            verification: nil
        )
    }
}
