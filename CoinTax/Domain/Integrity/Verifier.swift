import Foundation

struct VerifierInput: Sendable {
    var summary: TaxYearSummary
    var replay: ReplayResult
    var policies: PolicyBundle
    var events: [LedgerEvent]
    /// Second independent aggregate for V-RE-01
    var summaryRerun: TaxYearSummary?
}

enum Verifier {
    static func verify(_ input: VerifierInput) -> VerificationReport {
        var issues: [VerificationIssue] = []
        let s = input.summary
        let r = input.replay
        let p = input.policies

        // V-RE-01 determinism
        if let s2 = input.summaryRerun {
            if s.netIncomeKRW != s2.netIncomeKRW || s.totalTaxKRW != s2.totalTaxKRW {
                issues.append(.init(id: "V-RE-01", severity: "critical", message: "동일 입력 재계산 결과 불일치", context: nil))
            }
        }

        // V-TAX-01 sum(pnl) - extra == netIncome
        let pnlSum = s.disposals.reduce(Decimal(0)) { $0 + $1.pnlKRW } - r.extraDeductible
        if Money.abs(pnlSum - s.netIncomeKRW) > 1 {
            issues.append(.init(id: "V-TAX-01", severity: "critical", message: "손익 합계와 소득 불일치", context: "pnl=\(pnlSum) income=\(s.netIncomeKRW)"))
        }

        // V-TAX-02 taxBase
        let expectedBase = max(0, s.netIncomeKRW - s.basicDeductionKRW)
        if s.taxBaseKRW != expectedBase {
            issues.append(.init(id: "V-TAX-02", severity: "critical", message: "과세표준 불일치", context: nil))
        }

        // V-TAX-03/04 rates
        let expectedNational = p.rounding.roundKRW(s.taxBaseKRW * p.taxRate.nationalRate)
        let expectedLocal = p.rounding.roundKRW(s.taxBaseKRW * p.taxRate.localRate)
        if s.nationalTaxKRW != expectedNational {
            issues.append(.init(id: "V-TAX-03", severity: "critical", message: "국세 세율 검증 실패", context: nil))
        }
        if s.localTaxKRW != expectedLocal {
            issues.append(.init(id: "V-TAX-04", severity: "critical", message: "지방세 세율 검증 실패", context: nil))
        }

        // V-COST-02 transfer ratio
        for d in r.transferCostDetails {
            let expected = d.outboundCostKRW * d.ratio
            if Money.abs(expected - d.transferredCostKRW) > 1 {
                issues.append(.init(id: "V-COST-02", severity: "critical", message: "전송 이전 원가 비율 불일치", context: d.linkID.raw.uuidString))
            }
        }

        // V-COST-03 abandoned not in deductible
        if r.extraDeductible != 0 && p.transferCost.id == "abandon_lost_cost" {
            issues.append(.init(id: "V-COST-03", severity: "critical", message: "소실 원가가 필요경비에 포함됨", context: nil))
        }
        if s.abandonedTransferCostKRW != r.abandonedTotal && Money.abs(s.abandonedTransferCostKRW - r.abandonedTotal) > 1 {
            issues.append(.init(id: "V-COST-03", severity: "warning", message: "소실 원가 합계 불일치", context: nil))
        }
        // abandoned must not be inside totalCosts as deductible path
        // check: for abandon policy, deductible from transfers is 0
        for d in r.transferCostDetails {
            if d.deductibleExpenseKRW != 0 && p.transferCost.id == "abandon_lost_cost" {
                issues.append(.init(id: "V-COST-03", severity: "critical", message: "전송 소실 필요경비 금지 위반", context: nil))
            }
        }

        // V-DEM-02
        for d in r.deemedPositions {
            if let m = d.marketUnitKRW {
                let expected = max(d.bookUnitKRW, m)
                if d.deemedUnitKRW != expected {
                    issues.append(.init(id: "V-DEM-02", severity: "critical", message: "의제 단가 max 위반", context: d.asset.code))
                }
            }
        }

        // V-QTY-02 no negative qty in holdings
        for row in r.holdings.rows {
            if row.quantity < 0 {
                issues.append(.init(id: "V-QTY-02", severity: "critical", message: "음수 보유 수량", context: row.asset.code))
            }
        }

        // V-FX-01
        if !r.missingFXDays.isEmpty {
            issues.append(.init(id: "V-FX-01", severity: "critical", message: "환율 누락", context: r.missingFXDays.joined(separator: ",")))
        }
        if input.events.contains(where: { $0.needsFX }) {
            issues.append(.init(id: "V-FX-01", severity: "critical", message: "needsFX 이벤트 잔존", context: nil))
        }

        // missing market with positive qty positions that should have been deemed
        if !r.missingMarketAssets.isEmpty {
            issues.append(.init(id: "V-DEM-02", severity: "critical", message: "의제 시가 누락", context: r.missingMarketAssets.map(\.code).joined(separator: ",")))
        }

        // policy id
        if s.policyBundleID != p.id {
            issues.append(.init(id: "V-RE-01", severity: "critical", message: "정책 번들 ID 불일치", context: nil))
        }

        let hasCritical = issues.contains { $0.severity == "critical" }
        let hasWarning = issues.contains { $0.severity == "warning" }
        let status: String
        if hasCritical {
            status = "failed"
        } else if hasWarning {
            status = "passedWithWarnings"
        } else {
            status = "passed"
        }

        return VerificationReport(
            runID: UUID(),
            status: status,
            issues: issues,
            calculatedAt: Date()
        )
    }
}
