import Foundation
import SwiftData

struct CalculationResult: Sendable {
    var summary: TaxYearSummary
    var replay: ReplayResult
    var verification: VerificationReport
}

@MainActor
final class CalculationPipeline {
    private let modelContext: ModelContext
    var policies: PolicyBundle = .v1Default

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var fxService: FXService?

    func calculate(project: ProjectEntity, taxYear: Int) async throws -> CalculationResult {
        let ps = ProjectService(modelContext: modelContext)
        let accounts = ps.domainAccounts(for: project)
        let events = ps.domainEvents(for: project)
        let links = ps.domainLinks(for: project)
        let fxSvc = fxService ?? FXService(modelContext: modelContext)
        // 자동 환율(기본): 계산 전 누락일 채움
        _ = try await fxSvc.ensureRatesForCalculation(events: events, project: project)
        let fx = fxSvc.ratesMap(for: project)

        var market: [String: Decimal] = [:]
        for m in project.marketPrices where m.asOf == "2026-12-31" {
            if let p = Decimal(string: m.priceKRW) {
                market[m.asset.uppercased()] = p
            }
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: accountsByID,
            fxRates: fx,
            marketPrices: market
        )

        let replay = try engine.replay(events: events, links: links)
        var summary = TaxAggregator.aggregate(
            projectID: ProjectID(project.id),
            disposals: replay.disposals,
            taxYear: taxYear,
            extraDeductible: replay.extraDeductible,
            abandonedTransferCostKRW: replay.abandonedTotal,
            deemed: replay.deemedPositions,
            policies: policies
        )

        // determinism re-run
        let replay2 = try engine.replay(events: events, links: links)
        let summary2 = TaxAggregator.aggregate(
            projectID: ProjectID(project.id),
            disposals: replay2.disposals,
            taxYear: taxYear,
            extraDeductible: replay2.extraDeductible,
            abandonedTransferCostKRW: replay2.abandonedTotal,
            deemed: replay2.deemedPositions,
            policies: policies
        )

        // block if missing market for holdings at deemed that had qty
        var blocked = false
        if !replay.missingMarketAssets.isEmpty {
            // only block if there were pre-tax positions needing market
            blocked = true
        }
        if !replay.missingFXDays.isEmpty {
            blocked = true
        }

        let verification = Verifier.verify(VerifierInput(
            summary: summary,
            replay: replay,
            policies: policies,
            events: events,
            summaryRerun: summary2
        ))

        if verification.status == "failed" || blocked {
            summary.status = .blocked
        } else if verification.status == "passedWithWarnings" {
            summary.status = .verified
        } else {
            summary.status = .verified
        }
        summary.verification = verification

        // persist snapshot
        if let data = try? JSONEncoder().encode(summary),
           let json = String(data: data, encoding: .utf8) {
            let snap = SnapshotEntity(
                taxYear: taxYear,
                status: summary.status.rawValue,
                policyBundleID: policies.id,
                payloadJSON: json
            )
            snap.project = project
            project.snapshots.append(snap)
            modelContext.insert(snap)
            project.lastPolicyBundleID = policies.id
            try? modelContext.save()
        }

        return CalculationResult(summary: summary, replay: replay, verification: verification)
    }
}
