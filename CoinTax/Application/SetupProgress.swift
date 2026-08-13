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
        // 상대 없는 **입금** 중 개인지갑이 덮을 수 있는 것도 남은 일이다.
        //
        // 예전에는 출금만 셌다. 그런데 개인지갑에서 되가져온 입금을 연결하지 않으면
        // **취득가 0원**이 되어 판 금액 전부가 이익으로 잡힌다 — 세금이 커지는 쪽이다.
        // 앱에 「개인지갑에서」 버튼이 있어 고칠 수 있는데, 체크리스트가 「완료」라고 하면 아무도 안 고친다.
        let receivable = walletReceivableCount(project, env: env)
        let leftovers = [
            unmatched > 0 ? "상대 없는 출금 \(unmatched)건 — 개인지갑으로 보낸 것이면 지정해 두세요 (안 하면 산 값이 사라집니다)" : nil,
            receivable > 0 ? "개인지갑에서 되가져온 것으로 보이는 입금 \(receivable)건 — 연결하지 않으면 취득가 0원이 되어 세금이 커집니다" : nil
        ].compactMap { $0 }
        p.steps.append(Step(
            id: 3,
            title: "거래소 간 전송 연결",
            detail: candidates.isEmpty
                ? (confirmed > 0 || !leftovers.isEmpty
                    ? ([confirmed > 0 ? "\(confirmed)건 연결됨" : nil].compactMap { $0 } + leftovers).joined(separator: " · ")
                    : "연결할 전송이 없습니다.")
                : "연결 안 된 후보 \(candidates.count)건이 있습니다. 연결하지 않으면 취득원가가 사라져 세금이 커집니다.",
            // 고칠 수 있는 일이 남아 있으면 「완료」로 두지 않는다 — 조용히 두면 산 값이 사라지거나 0원이 된 채 계산된다
            state: (candidates.isEmpty && unmatched == 0 && receivable == 0) ? .done : .needsAction,
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
        //
        // 그 시가는 2027-01-01 이 지나야 존재한다. 그전까지 「할 일」로 띄우면 사용자는
        // 있지도 않은 값을 찾아 헤매고 체크리스트는 영영 안 끝난다 — 차례가 아님으로 둔다.
        let needed = assetsNeedingMarketPrice(project: project, env: env)
        p.missingMarketAssets = needed
        let beforeTaxStart = TaxTime.isBeforeTaxStart()
        p.steps.append(Step(
            id: 5,
            title: "\(TaxCopy.deemedAsOfLabel) 입력",
            detail: needed.isEmpty
                ? "과세 시작 전 보유분의 의제취득가를 정할 수 있습니다."
                : beforeTaxStart
                    ? "2027-01-01 이 지나야 나오는 값입니다 (\(needed.joined(separator: ", "))). 그때까지는 실제 산 값으로 계산하며, 나중에 넣으면 취득가가 올라가 세금이 줄 수 있습니다."
                    : "\(needed.joined(separator: ", ")) 가격이 필요합니다. 과세 시작(2027-01-01) 전부터 갖고 있던 코인은 이 가격과 실제 취득가 중 **큰 쪽**을 취득가로 씁니다. \(TaxCopy.deemedAsOfDetail)",
            state: needed.isEmpty ? .done : (beforeTaxStart ? .waiting : .needsAction),
            section: .settings,
            actionTitle: (needed.isEmpty || beforeTaxStart) ? nil : "입력하기"
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
        // 어림잡을 때도 **수량 규칙 한 벌**(`LedgerDelta`)을 쓴다.
        //
        // 예전에는 기초자산(`baseAsset`)만 봤다. 그러면 **코인을 팔아서 받은 코인**(코인↔코인 매도의
        // 견적자산)이 목록에서 빠진다 — 그 코인은 기초자산으로 한 번도 안 나오기 때문이다.
        // 그래서 체크리스트는 「완료」인데 계산은 그 코인의 시가가 없어 막혔다.
        // 장부가 실제로 움직이는 자산을 그대로 물어보면 그 갈래가 생기지 않는다 (코인 수수료도 함께 덮인다).
        let cutoff = TaxTime.taxStartDate
        let pid = ProjectID(project.id)
        var candidates: Set<String> = []
        for entity in project.events where entity.timestamp < cutoff {
            for change in LedgerDelta.bookChanges(for: EntityMappers.event(entity, projectID: pid)) {
                candidates.insert(change.asset.code)
            }
        }
        return candidates.subtracting(have).sorted()
    }

    /// 상대 없는 입금 중 **개인지갑이 그 시점에 덮을 수 있는** 건수.
    /// 「전송 연결」 화면의 「개인지갑에서」 버튼이 뜨는 조건과 같아야 한다 —
    /// 화면에는 할 일이 보이는데 체크리스트만 「완료」이면 사용자가 그냥 지나친다.
    private static func walletReceivableCount(_ project: ProjectEntity, env: AppEnvironment) -> Int {
        let linkedTo = Set(project.links.filter { $0.status == LinkStatus.confirmed.rawValue }.map(\.toEventID))
        guard let wallet = project.accounts.first(where: { $0.exchangeCode == ExchangeCode.wallet.rawValue }) else {
            return 0
        }
        return project.events.filter { e in
            guard e.type == EventType.deposit.rawValue,
                  e.baseAsset.uppercased() != "KRW",
                  e.accountID != wallet.id,
                  !linkedTo.contains(e.id) else { return false }
            let qty = Money.abs(Decimal(string: e.quantity) ?? 0)
            guard qty > 0 else { return false }
            return env.matchingService.walletBalance(asset: e.baseAsset, at: e.timestamp, project: project) >= qty
        }.count
    }

    private static func unmatchedTransferCount(_ project: ProjectEntity) -> Int {
        let linkedFrom = Set(project.links.filter { $0.status == LinkStatus.confirmed.rawValue }.map(\.fromEventID))
        return project.events.filter {
            $0.type == EventType.withdrawal.rawValue
                && $0.baseAsset.uppercased() != "KRW"
                && !linkedFrom.contains($0.id)
                // 「잘못 보내 소멸」로 이미 판단한 건은 남은 할 일이 아니다
                && !$0.lostForever
        }.count
    }
}
