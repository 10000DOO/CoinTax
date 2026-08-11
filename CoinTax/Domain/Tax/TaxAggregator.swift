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
        let ds = disposals.filter {
            TaxTime.calendarYearKST($0.timestamp) == taxYear && $0.timestamp >= tTax
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
            disposals: ds,
            deemed: deemed,
            disclaimers: policies.disclaimers,
            calculatedAt: Date(),
            verification: nil
        )
    }
}
