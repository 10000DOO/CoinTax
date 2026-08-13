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
        // ── `[법]` §37⑥ 필요경비 의제 50% ─────────────────────────────
        //
        // 켠 자산은 그 해 **그 종류 처분 전체**의 필요경비를 「총양도가액 × 50%」로 바꾼다.
        // 조문 후단대로 **부대비용은 산입하지 않는다.**
        //
        // 총액만 바꾸고 건별 기록을 그대로 두면 리포트의 표가 합계와 안 맞고, 검증기의
        // 독립 재합산(V-RE-02)·건별 손익(V-COST-06)이 정상 계산을 Critical 로 막는다.
        // 그래서 건별 값도 **양도가액 비율대로** 다시 쓴다.
        var rows = ds
        let proxy = policies.proxyExpense
        if !proxy.enabledAssets.isEmpty {
            let byAsset = Dictionary(grouping: rows.indices, by: { rows[$0].asset.code })
            for code in byAsset.keys.sorted() where proxy.isEnabled(AssetSymbol(code)) {
                let idxs = byAsset[code]!
                let totalProceeds = idxs.reduce(Decimal(0)) { $0 + rows[$1].proceedsKRW }
                let totalExpense = proxy.necessaryExpense(totalProceedsKRW: totalProceeds)
                guard totalProceeds > 0 else { continue }
                for i in idxs {
                    // 곱셈을 먼저, 나눗셈을 마지막에 — 자릿수가 긴 값에서 합계가 어긋나지 않게
                    let share = totalExpense * rows[i].proceedsKRW / totalProceeds
                    rows[i].costKRW = share
                    rows[i].feesKRW = 0
                    rows[i].pnlKRW = rows[i].proceedsKRW - share
                }
            }
        }

        let proceeds = rows.reduce(Decimal(0)) { $0 + $1.proceedsKRW }
        let costSum = rows.reduce(Decimal(0)) { $0 + $1.costKRW + $1.feesKRW } + extraDeductible
        let income = rows.reduce(Decimal(0)) { $0 + $1.pnlKRW } - extraDeductible
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
            disposals: rows,
            deemed: deemed,
            disclaimers: policies.disclaimers,
            calculatedAt: Date(),
            verification: nil
        )
    }
}
