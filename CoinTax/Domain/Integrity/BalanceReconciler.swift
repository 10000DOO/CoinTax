import Foundation

/// 거래소가 원본에 **직접 찍어준 잔고**와 우리 계산을 매 거래마다 맞춰 본다 (V-BAL).
///
/// ## 왜 필요한가
///
/// 지금까지의 검증은 전부 **우리 코드가 우리 코드를 검사**하는 구조였다.
/// 엔진과 검증기를 같은 생각으로 짜면 둘이 같은 실수를 하고 서로를 통과시킨다.
/// 실제로 그렇게 새어 나간 결함이 여러 건이다 (`docs/audit-2026-08-12-logic.md`).
///
/// 거래소가 찍어준 잔고는 **우리 코드 밖에서 온 값**이라 그 고리를 끊는다.
/// 파싱이 밀렸든, 거래가 빠졌든, 수량 규칙(순액/총액·수수료)을 잘못 이해했든,
/// 그 순간부터 잔고가 어긋나므로 즉시 드러난다.
///
/// ## 계정이 아니라 「명세서」 단위로 본다
///
/// 거래소 파일은 **서브계정 하나**의 명세서다. OKX 는 펀딩 계정과 트레이딩 계정의 잔고를
/// 각각 다른 파일에 찍어 주는데, 앱은 둘을 한 계정으로 합쳐 관리한다.
/// 그래서 대조는 계정이 아니라 `(계정, 원본 종류, 자산)` 단위로 한다.
enum BalanceReconciler {
    enum Kind: String, Sendable {
        /// 자료가 시작되기 전에 이미 갖고 있던 수량 (취득원가를 알 수 없다)
        case openingBalance
        /// 중간부터 어긋남 — 파싱·수량 규칙·누락 중 하나
        case drift
    }

    struct Finding: Sendable {
        var kind: Kind
        var accountID: AccountID
        var asset: AssetSymbol
        var sourceKind: String
        /// 거래소가 찍은 값 (openingBalance 면 추정한 개시 수량)
        var exchangeValue: Decimal
        /// 우리가 계산한 값
        var computedValue: Decimal
        var at: Date
        var rawRef: String?

        var difference: Decimal { exchangeValue - computedValue }
    }

    /// 한 명세서·한 자산에서 보고할 최대 어긋남 건수.
    /// 한 번 어긋나면 이후 전부 어긋나므로, 처음 몇 건만 보여 주고 나머지는 소음이다.
    static let maxDriftsPerStream = 3

    static func reconcile(events: [LedgerEvent]) -> [Finding] {
        var findings: [Finding] = []

        // (계정, 원본 종류) = 명세서 하나
        let streams = Dictionary(grouping: events.filter { $0.type != .ignored }) {
            "\($0.accountID.raw.uuidString)|\($0.sourceKind)"
        }

        for key in streams.keys.sorted() {
            guard let group = streams[key] else { continue }
            let sorted = group.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                let a = $0.rawRef ?? ""
                let b = $1.rawRef ?? ""
                if a != b { return a < b }
                return $0.id.raw.uuidString < $1.id.raw.uuidString
            }
            var running: [String: Decimal] = [:]
            var established: Set<String> = []
            var driftCount: [String: Int] = [:]

            for e in sorted {
                for change in LedgerDelta.statementChanges(for: e) {
                    running[change.asset.code, default: 0] += change.delta
                }
                // 이 행에 찍힌 잔고들
                var printed: [(asset: AssetSymbol, value: Decimal)] = []
                if let b = e.balanceAfter, !e.baseAsset.isKRW {
                    printed.append((e.baseAsset, b))
                }
                if let qb = e.quoteBalanceAfter, let q = e.quoteAsset, !q.isKRW {
                    printed.append((q, qb))
                }

                for (asset, value) in printed {
                    let code = asset.code
                    let computed = running[code] ?? 0
                    if !established.contains(code) {
                        established.insert(code)
                        let opening = value - computed
                        // 자료 시작 전 보유분. 취득원가를 알 수 없으므로 반드시 알려야 한다.
                        if !Money.isDustShortfall(Money.abs(opening), of: max(Money.abs(value), 1)) {
                            findings.append(Finding(
                                kind: .openingBalance,
                                accountID: e.accountID, asset: asset, sourceKind: e.sourceKind,
                                exchangeValue: opening, computedValue: 0,
                                at: e.timestamp, rawRef: e.rawRef
                            ))
                        }
                        running[code] = value
                        continue
                    }
                    let diff = value - computed
                    guard !Money.isDustShortfall(Money.abs(diff), of: max(Money.abs(value), 1)) else { continue }
                    let n = driftCount[code, default: 0]
                    if n < maxDriftsPerStream {
                        findings.append(Finding(
                            kind: .drift,
                            accountID: e.accountID, asset: asset, sourceKind: e.sourceKind,
                            exchangeValue: value, computedValue: computed,
                            at: e.timestamp, rawRef: e.rawRef
                        ))
                    }
                    driftCount[code] = n + 1
                    // 한 번 어긋나면 이후 전부 어긋난다 → 기준을 거래소 값으로 되맞춰
                    // **끊어진 지점들**을 각각 보여 준다 (같은 오차를 수백 번 반복하지 않게).
                    running[code] = value
                }
            }
        }
        return findings.sorted {
            if $0.at != $1.at { return $0.at < $1.at }
            return $0.asset.code < $1.asset.code
        }
    }

    /// 잔고 열이 있는 원본이 하나라도 있었는지. 없으면 이 검사는 「돌지 않았다」고 알려야 한다.
    static func hasAnyPrintedBalance(_ events: [LedgerEvent]) -> Bool {
        events.contains { $0.balanceAfter != nil || $0.quoteBalanceAfter != nil }
    }

    /// 잔고 열이 **하나도 없어서 외부 대조를 못 받은** 원본 종류.
    ///
    /// 「하나라도 잔고가 있으면 조용」하게 두면, 빗썸(잔고 있음)과 바이낸스(잔고 없음)를 함께 넣은
    /// 사용자는 **바이낸스가 안 덮였다는 사실을 모른다.** 이 앱에서 잔고 대조는 유일하게
    /// 앱 밖에서 온 정답지이므로, 어디까지 덮였는지는 사용자가 알아야 한다.
    /// 대조 단위와 같은 `(계정, 원본 종류)` 로 보고, 사용자에게는 **원본 종류**로 알린다.
    static func sourcesWithoutPrintedBalance(_ events: [LedgerEvent]) -> [String] {
        var covered: Set<String> = []
        var seen: Set<String> = []
        for e in events where e.type != .ignored {
            seen.insert(e.sourceKind)
            if e.balanceAfter != nil || e.quoteBalanceAfter != nil { covered.insert(e.sourceKind) }
        }
        return seen.subtracting(covered).sorted()
    }
}
