import Foundation

struct TransferMatchCandidate: Identifiable, Sendable {
    var id: String { "\(fromEventID.raw)-\(toEventID.raw)" }
    var fromEventID: EventID
    var toEventID: EventID
    var withdrawnQty: Decimal
    var receivedQty: Decimal
    var score: Double
    var note: String
}

struct TransferMatchingEngine {
    var accountsByID: [AccountID: Account]
    var windowHours: Double = 72
    var minScore: Double = 0.35
    /// 후보로 제시할 최대 손실 비율. 이 안이면 점수를 깎아서라도 보여준다.
    /// (고신뢰 창은 IMPLEMENTATION §7 의 1%. 그 밖은 「확인 필요」로 표시)
    var maxLostRatioForSuggestion: Decimal = Decimal(string: "0.5")!

    func suggest(events: [LedgerEvent], existing: [TransferLink]) -> [TransferMatchCandidate] {
        let linkedFrom = Set(existing.filter { $0.status == .confirmed || $0.status == .suggested }.map(\.fromEventID))
        let linkedTo = Set(existing.filter { $0.status == .confirmed || $0.status == .suggested }.map(\.toEventID))
        // 거부한 쌍은 다시 제안하지 않는다 (리뷰 2-4)
        let rejectedPairs = Set(
            existing.filter { $0.status == .rejected }.map { "\($0.fromEventID.raw)|\($0.toEventID.raw)" }
        )

        let withdrawals = events.filter {
            $0.type == .withdrawal && !$0.baseAsset.isKRW && !linkedFrom.contains($0.id)
        }
        let deposits = events.filter {
            $0.type == .deposit && !$0.baseAsset.isKRW && !linkedTo.contains($0.id)
        }

        var scored: [TransferMatchCandidate] = []
        let window: TimeInterval = windowHours * 3600

        for w in withdrawals {
            for d in deposits {
                if rejectedPairs.contains("\(w.id.raw)|\(d.id.raw)") { continue }
                if d.accountID == w.accountID { continue }
                if d.baseAsset != w.baseAsset { continue }
                let dt = abs(d.timestamp.timeIntervalSince(w.timestamp))
                if dt > window { continue }
                let wQty = Money.abs(w.quantity)
                let dQty = Money.abs(d.quantity)
                guard wQty > 0, dQty > 0 else { continue }
                if dQty > wQty * Decimal(string: "1.0001")! { continue }
                let lost = wQty - dQty
                // 거래소 반올림 차이로 입금이 미세하게 클 수 있다 → 음수 손실도 아주 작으면 허용
                if lost < -Money.qtyEpsilon { continue }

                // IMPLEMENTATION §7 의 고신뢰 창: abs(out)−abs(in) <= max(abs(out)*1%, fee, 1e-6)
                let confidentLost = max(
                    wQty * Decimal(string: "0.01")!,
                    w.feeAmount.map { Money.abs($0) } ?? 0,
                    Decimal(string: "0.000001")!
                )
                // 소액 전송은 네트워크 수수료가 1%를 훌쩍 넘는다 (예: 10 USDT 전송에 1 USDT 수수료 = 10%).
                // 이 구간을 후보에서 통째로 빼면 미매칭이 되어 **취득원가가 소멸하고 세금이 과대**해진다.
                // 그래서 넓은 창까지 후보로 제시하되 점수를 크게 깎고 손실률을 표시해 사용자가 판단하게 한다.
                if lost > wQty * maxLostRatioForSuggestion { continue }
                let lowConfidence = lost > confidentLost

                var score = 0.0
                score += 1.0 - min(dt / window, 1) * 0.5
                let lostRatio = (wQty == 0) ? 1.0 : NSDecimalNumber(decimal: lost / wQty).doubleValue
                score += (1 - lostRatio) * 0.3
                if lowConfidence { score -= 0.3 }

                let wVenue = accountsByID[w.accountID]?.venueKind
                let dVenue = accountsByID[d.accountID]?.venueKind
                if wVenue == .domestic && dVenue == .overseas { score += 0.15 }
                if dVenue == .domestic && wVenue == .overseas { score += 0.15 }

                if let hint = w.counterpartyHint {
                    let ex = accountsByID[d.accountID]?.exchangeCode.rawValue
                    if let ex, hint.lowercased().contains(ex) || (hint == "binance" && ex == "binance") {
                        score += 0.2
                    }
                }
                if let wh = w.txidHash, let dh = d.txidHash, wh == dh { score += 0.5 }
                if let wa = w.addressHash, let da = d.addressHash, wa == da { score += 0.5 }

                guard score >= minScore else { continue }
                scored.append(TransferMatchCandidate(
                    fromEventID: w.id,
                    toEventID: d.id,
                    withdrawnQty: wQty,
                    receivedQty: dQty,
                    score: score,
                    note: lowConfidence
                        ? String(format: "dt=%.1fh 손실 %@ (%.1f%%) — 수수료 확인 필요", dt / 3600, Money.decimalString(lost), lostRatio * 100)
                        : String(format: "dt=%.1fh 손실 %@", dt / 3600, Money.decimalString(lost))
                ))
            }
        }

        // 1:1 배정. 출금별로 최선을 고르기만 하면 같은 입금이 두 출금에 제안되고,
        // 사용자가 둘 다 확정하면 원가가 이중 계상된다 (리뷰 1-6).
        // 점수 높은 순으로 확정하며 이미 쓴 출금·입금은 제외한다.
        var usedWithdrawals: Set<EventID> = []
        var usedDeposits: Set<EventID> = []
        var result: [TransferMatchCandidate] = []
        for cand in scored.sorted(by: {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.id < $1.id  // 동점 시 결정적 순서
        }) {
            guard !usedWithdrawals.contains(cand.fromEventID), !usedDeposits.contains(cand.toEventID) else { continue }
            usedWithdrawals.insert(cand.fromEventID)
            usedDeposits.insert(cand.toEventID)
            result.append(cand)
        }
        return result
    }
}
