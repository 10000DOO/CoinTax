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

    /// 테스트에서 특정 정책을 고정할 때만 설정한다.
    /// 평소에는 `PolicyBundle.current`(사용자 설정 반영)를 쓴다 — 사본을 들고 있으면
    /// 설정 변경이 파이프라인에만 반영돼 화면 표시와 어긋난다.
    var policiesOverride: PolicyBundle?

    var effectivePolicies: PolicyBundle { policiesOverride ?? .current }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var fxService: FXService?

    func calculate(project: ProjectEntity, taxYear: Int) async throws -> CalculationResult {
        // 계산 도중 설정이 바뀌어도 한 번의 계산 안에서는 같은 정책을 쓴다
        let policies = effectivePolicies
        let ps = ProjectService(modelContext: modelContext)
        let accounts = ps.domainAccounts(for: project)
        let events = ps.domainEvents(for: project)
        let links = ps.domainLinks(for: project)
        let fxSvc = fxService ?? FXService(modelContext: modelContext)
        // 자동 환율(기본): 계산 전 누락일 채움. 남은 누락일은 엔진이 Critical 이슈로 보고한다.
        let stillMissing = try await fxSvc.ensureRatesForCalculation(events: events, project: project)
        let fx = fxSvc.ratesMap(for: project)

        // 자산 코드는 장부 키와 **같은 정규화**를 거쳐야 한다.
        // `uppercased()` 만 하면 공백이 섞이거나 별칭 티커(XBT 등)를 쓴 입력이 장부 키와 어긋나
        // 시가가 있는데도 "시가 누락"으로 계산이 막힌다.
        var market: [String: Decimal] = [:]
        for m in project.marketPrices where m.asOf == "2026-12-31" {
            if let p = Decimal(string: m.priceKRW), p > 0 {
                market[AssetSymbol(m.asset).code] = p
            }
        }

        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let engine = CostBasisEngine(
            policies: policies,
            accountsByID: accountsByID,
            fxRates: fx,
            marketPrices: market
        )

        let replay = try engine.replay(events: events, links: links)
        // 전송 소실·추가 공제는 **그 해에 발생한 것만** 그 해 소득에 반영한다.
        // 전 기간 합계를 쓰면 다른 해 비용이 이 해 세액을 깎는다.
        var summary = TaxAggregator.aggregate(
            projectID: ProjectID(project.id),
            disposals: replay.disposals,
            taxYear: taxYear,
            extraDeductible: replay.extraDeductibleByYear[taxYear] ?? 0,
            abandonedTransferCostKRW: replay.abandonedByYear[taxYear] ?? 0,
            deemed: replay.deemedPositions,
            policies: policies
        )

        // determinism re-run
        let replay2 = try engine.replay(events: events, links: links)
        var summary2 = TaxAggregator.aggregate(
            projectID: ProjectID(project.id),
            disposals: replay2.disposals,
            taxYear: taxYear,
            extraDeductible: replay2.extraDeductibleByYear[taxYear] ?? 0,
            abandonedTransferCostKRW: replay2.abandonedByYear[taxYear] ?? 0,
            deemed: replay2.deemedPositions,
            policies: policies
        )

        summary.fxSources = replay.fxUsageNotes
        summary2.fxSources = replay2.fxUsageNotes
        summary.deemedBasisMode = policies.deemed.mode.rawValue
        summary2.deemedBasisMode = policies.deemed.mode.rawValue

        // TQ-01 미결: 다른 의제 산정 방식으로도 계산해 결과 차이를 함께 보여준다.
        // 의제 대상 포지션이 없으면 두 방식이 같으므로 건너뛴다.
        // lot 이 2개 이상인 선입선출 포지션이 있을 때만 두 방식의 결과가 갈린다.
        // 그렇지 않으면 계산을 한 번 더 돌릴 이유가 없다 (10만 건 재계산 예산 보호).
        let modesCanDiffer = replay.deemedPositions.contains { $0.lotCount > 1 }
            || replay.deemedPositions.contains { $0.marketUnitKRW != nil && $0.quantity > 0 && $0.lotCount == 1 && policies.deemed.mode == .positionAverage }
        if !replay.deemedPositions.isEmpty, modesCanDiffer {
            let otherMode = policies.deemed.mode.other
            var altPolicies = policies
            altPolicies.deemed = MaxBookMarketDeemedPolicy(mode: otherMode)
            var altEngine = engine
            altEngine.policies = altPolicies
            if let altReplay = try? altEngine.replay(events: events, links: links) {
                let altSummary = TaxAggregator.aggregate(
                    projectID: ProjectID(project.id),
                    disposals: altReplay.disposals,
                    taxYear: taxYear,
                    extraDeductible: altReplay.extraDeductibleByYear[taxYear] ?? 0,
                    abandonedTransferCostKRW: altReplay.abandonedByYear[taxYear] ?? 0,
                    deemed: altReplay.deemedPositions,
                    policies: altPolicies
                )
                summary.deemedAlternative = DeemedAlternative(
                    basisMode: otherMode.rawValue,
                    basisLabel: otherMode.label,
                    totalDeemedCostKRW: altSummary.totalDeemedCostKRW,
                    netIncomeKRW: altSummary.netIncomeKRW,
                    totalTaxKRW: altSummary.totalTaxKRW
                )
            }
        }

        // 전송 링크에 계산된 원가를 기록 (14-spec §1 "filled after calc") — 감사 추적용
        let detailByLink = Dictionary(replay.transferCostDetails.map { ($0.linkID.raw, $0) }, uniquingKeysWith: { a, _ in a })
        for entity in project.links {
            guard let detail = detailByLink[entity.id] else { continue }
            entity.transferredCostKRW = Money.decimalString(detail.transferredCostKRW)
            entity.abandonedCostKRW = Money.decimalString(detail.abandonedCostKRW)
        }

        var verification = Verifier.verify(VerifierInput(
            summary: summary,
            replay: replay,
            policies: policies,
            events: events,
            summaryRerun: summary2,
            links: links,
            fxPublished: fx
        ))

        // 자동 조회 후에도 못 채운 환율 날짜는 별도 이슈로 남긴다 (설정에서 자동을 끈 경우 포함)
        var extraIssues: [VerificationIssue] = []
        if !stillMissing.isEmpty {
            extraIssues.append(.init(
                id: "V-FX-01", severity: "critical",
                message: FXKeychain.loadECOSKey() == nil
                    ? "환율을 채우지 못한 날짜가 있습니다 — 설정에서 한국은행 ECOS 인증키를 등록하거나 수동 입력/CSV로 채우세요"
                    : "환율을 채우지 못한 날짜가 있습니다 — 설정에서 수동 입력 또는 CSV import 하세요",
                context: stillMissing.joined(separator: ",")
            ))
        }
        // TQ-05: 공개 시세는 외국환거래법상 기준환율이 아니다 → 섞였으면 반드시 드러낸다.
        // **실제 계산에 쓰인 고시일만** 본다. 저장돼 있어도 쓰이지 않은 날짜까지 경고하면
        // 정상 계산이 `draft` 로 내려가 오탐이 된다.
        let usedFXDays = Set(replay.fxResolutions.map(\.sourceDate))
        let publicDays = project.fxRates
            .filter { $0.source.contains("public") && usedFXDays.contains($0.day) }
            .map(\.day).sorted()
        if !publicDays.isEmpty {
            extraIssues.append(.init(
                id: "V-FX-02", severity: "warning",
                message: "공식 기준환율이 아닌 참고 시세가 \(publicDays.count)일 사용되었습니다 (한국은행 ECOS 인증키 등록을 권장)",
                context: publicDays.prefix(10).joined(separator: ",")
            ))
        }
        if !extraIssues.isEmpty {
            let merged = verification.issues + extraIssues
            let hasCritical = merged.contains { $0.severity == "critical" }
            verification = VerificationReport(
                runID: verification.runID,
                status: hasCritical ? "failed" : "passedWithWarnings",
                issues: merged,
                calculatedAt: verification.calculatedAt
            )
        }

        // 06-integrity §2.2: 경고만 있어도 `verified` 로 올리지 않는다. export 허용 여부는 별개.
        switch verification.status {
        case "passed":
            summary.status = .verified
        case "passedWithWarnings":
            summary.status = .draft
        default:
            summary.status = .blocked
        }
        summary.verification = verification

        persistSnapshot(summary, project: project, taxYear: taxYear, policyBundleID: policies.id)
        return CalculationResult(summary: summary, replay: replay, verification: verification)
    }

    /// 계산 스냅샷 보관 (최근 `snapshotHistoryLimit`개만 유지 — design/11-persistence §3)
    private static let snapshotHistoryLimit = 10

    private func persistSnapshot(_ summary: TaxYearSummary, project: ProjectEntity, taxYear: Int, policyBundleID: String) {
        guard let data = try? JSONEncoder().encode(summary),
              let json = String(data: data, encoding: .utf8) else { return }
        let snap = SnapshotEntity(
            taxYear: taxYear,
            status: summary.status.rawValue,
            policyBundleID: policyBundleID,
            payloadJSON: json
        )
        snap.project = project
        project.snapshots.append(snap)
        modelContext.insert(snap)
        project.lastPolicyBundleID = policyBundleID

        let ordered = project.snapshots.sorted { $0.calculatedAt > $1.calculatedAt }
        if ordered.count > Self.snapshotHistoryLimit {
            for old in ordered.dropFirst(Self.snapshotHistoryLimit) {
                project.snapshots.removeAll { $0 === old }
                modelContext.delete(old)
            }
        }
        do {
            try modelContext.save()
        } catch {
            // 스냅샷 저장 실패를 삼키면 재현 근거가 사라진다 — 계산 결과는 그대로 반환하고 기록만 남긴다.
            NSLog("CoinTax: 계산 스냅샷 저장 실패 — %@", String(describing: error))
        }
    }
}
