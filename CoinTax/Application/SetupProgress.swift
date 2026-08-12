import Foundation
import SwiftData

/// 「지금 뭘 해야 하지?」에 답하기 위한 상태.
///
/// 이 앱은 순서가 있는 도구다 — 파일을 넣고 · 전송을 잇고 · 환율과 시가를 채워야 비로소
/// 세액이 나온다. 화면마다 흩어져 있으면 사용자는 어디가 막혔는지 알 수 없다.
/// 홈 화면이 이 값을 그대로 체크리스트로 그린다.
@MainActor
struct SetupProgress {
    struct Step: Identifiable {
        enum State { case done, needsAction, waiting }
        let id: Int
        let title: String
        let detail: String
        let state: State
        let section: AppSection?
        let actionTitle: String?
    }

    var steps: [Step] = []
    var missingFXDays: [String] = []
    var missingMarketAssets: [String] = []
    var pendingCandidates: Int = 0

    var doneCount: Int { steps.filter { $0.state == .done }.count }
    var total: Int { steps.count }
    /// 지금 손대야 할 첫 단계
    var nextStep: Step? { steps.first { $0.state == .needsAction } ?? steps.first { $0.state == .waiting } }

    /// 시가 저장 키 (`MarketPriceEntity.asOf`). 표시 문구는 `TaxCopy.deemedAsOfLabel` 을 쓴다 —
    /// 법령 기준 시점은 2027-01-01 0시이고 이 키와 같은 순간이다.
    static let deemedAsOf = "2026-12-31"

    static func evaluate(env: AppEnvironment) -> SetupProgress {
        var p = SetupProgress()
        guard let project = env.currentProject else {
            p.steps = [Step(id: 1, title: "프로젝트 만들기", detail: "먼저 프로젝트를 하나 만드세요.",
                            state: .needsAction, section: .home, actionTitle: nil)]
            return p
        }

        // 1. 프로젝트
        p.steps.append(Step(
            id: 1,
            title: "프로젝트 만들기",
            detail: "\(project.name) · 거래소 \(project.accounts.count)곳",
            state: .done, section: nil, actionTitle: nil
        ))

        // 2. 원본 가져오기
        let fileCount = project.sourceFiles.count
        let eventCount = project.events.count
        p.steps.append(Step(
            id: 2,
            title: "거래소 파일 가져오기",
            detail: fileCount == 0
                ? "빗썸 거래내역 확인서(PDF)와 해외 거래소 CSV를 넣으세요."
                : "파일 \(fileCount)개 · 거래 \(eventCount)건",
            state: fileCount == 0 ? .needsAction : .done,
            section: .importFiles,
            actionTitle: fileCount == 0 ? "가져오기" : "추가"
        ))

        guard fileCount > 0 else {
            p.steps.append(contentsOf: waitingTail(from: 3))
            return p
        }

        // 3. 전송 연결
        let confirmed = project.links.filter { $0.status == LinkStatus.confirmed.rawValue }.count
        let candidates = env.matchingService.suggest(for: project)
        p.pendingCandidates = candidates.count
        let unmatched = unmatchedTransferCount(project)
        p.steps.append(Step(
            id: 3,
            title: "거래소 간 전송 연결",
            detail: candidates.isEmpty
                ? (confirmed > 0 ? "\(confirmed)건 연결됨" + (unmatched > 0 ? " · 미연결 \(unmatched)건" : "")
                                 : "연결할 전송이 없습니다.")
                : "연결 안 된 후보 \(candidates.count)건이 있습니다. 연결하지 않으면 취득원가가 사라져 세금이 커집니다.",
            state: candidates.isEmpty ? .done : .needsAction,
            section: .matching,
            actionTitle: candidates.isEmpty ? "보기" : "확인"
        ))

        // 4. 환율
        let events = env.projectService.domainEvents(for: project)
        p.missingFXDays = env.fxService.missingDays(for: events, project: project)
        let hasKey = FXKeychain.loadECOSKey() != nil
        p.steps.append(Step(
            id: 4,
            title: "환율 채우기",
            detail: p.missingFXDays.isEmpty
                ? "해외 거래 환산에 필요한 환율이 모두 있습니다."
                : "\(p.missingFXDays.count)일 부족" + (hasKey ? " · 계산할 때 자동으로 받아옵니다." : " · 한국은행 인증키를 넣으면 자동으로 채웁니다."),
            state: p.missingFXDays.isEmpty ? .done : .needsAction,
            section: .settings,
            actionTitle: p.missingFXDays.isEmpty ? nil : "설정 열기"
        ))

        // 5. 의제취득가용 시가 (2027-01-01 0시)
        let needed = assetsNeedingMarketPrice(project: project, env: env)
        p.missingMarketAssets = needed
        p.steps.append(Step(
            id: 5,
            title: "\(TaxCopy.deemedAsOfLabel) 입력",
            detail: needed.isEmpty
                ? "과세 시작 전 보유분의 의제취득가를 정할 수 있습니다."
                : "\(needed.joined(separator: ", ")) 가격이 필요합니다. 과세 시작(2027-01-01) 전부터 갖고 있던 코인은 이 가격과 실제 취득가 중 **큰 쪽**을 취득가로 씁니다. \(TaxCopy.deemedAsOfDetail)",
            state: needed.isEmpty ? .done : .needsAction,
            section: .settings,
            actionTitle: needed.isEmpty ? nil : "입력하기"
        ))

        // 6. 계산
        let calc = env.lastCalculation
        let stale = env.calculationStale
        let state: Step.State
        let detail: String
        if calc == nil {
            state = .needsAction
            detail = "지금까지 넣은 자료로 예상 세액을 계산합니다."
        } else if stale {
            state = .needsAction
            detail = "자료가 바뀌었습니다 — 다시 계산해야 최신 숫자가 됩니다."
        } else if calc?.verification.isExportAllowed == true {
            state = .done
            detail = "계산 완료 · 신고자료를 내려받을 수 있습니다."
        } else {
            state = .needsAction
            detail = "검증에서 막힌 항목이 있어 신고자료를 만들 수 없습니다."
        }
        p.steps.append(Step(id: 6, title: "계산하고 신고자료 받기", detail: detail,
                            state: state, section: .report, actionTitle: "리포트"))
        return p
    }

    private static func waitingTail(from start: Int) -> [Step] {
        let titles = [
            (3, "거래소 간 전송 연결", "국내 출금과 해외 입금을 이어 붙입니다."),
            (4, "환율 채우기", "해외 거래를 원화로 바꾸는 데 필요합니다."),
            (5, "\(TaxCopy.deemedAsOfLabel) 입력", "과세 시작 전 보유분의 취득가를 정합니다."),
            (6, "계산하고 신고자료 받기", "위 단계가 끝나면 예상 세액이 나옵니다.")
        ]
        return titles.filter { $0.0 >= start }.map {
            Step(id: $0.0, title: $0.1, detail: $0.2, state: .waiting, section: nil, actionTitle: nil)
        }
    }

    /// 계산을 한 번 돌렸으면 엔진이 알려준 목록이 정확하다.
    /// 아직이면 «과세 시작 전에 취득 기록이 있는 코인» 으로 어림잡는다.
    private static func assetsNeedingMarketPrice(project: ProjectEntity, env: AppEnvironment) -> [String] {
        let have = Set(
            project.marketPrices
                .filter { $0.asOf == deemedAsOf && (Decimal(string: $0.priceKRW) ?? 0) > 0 }
                .map { AssetSymbol($0.asset).code }
        )
        if let missing = env.lastCalculation?.replay.missingMarketAssets, !env.calculationStale {
            return missing.map(\.code).filter { !have.contains($0) }.sorted()
        }
        let cutoff = TaxTime.taxStartDate
        let candidates = Set(
            project.events
                .filter { $0.timestamp < cutoff }
                .map { AssetSymbol($0.baseAsset).code }
                .filter { $0 != "KRW" }
        )
        return candidates.subtracting(have).sorted()
    }

    private static func unmatchedTransferCount(_ project: ProjectEntity) -> Int {
        let linkedFrom = Set(project.links.filter { $0.status == LinkStatus.confirmed.rawValue }.map(\.fromEventID))
        return project.events.filter {
            $0.type == EventType.withdrawal.rawValue
                && $0.baseAsset.uppercased() != "KRW"
                && !linkedFrom.contains($0.id)
        }.count
    }
}
