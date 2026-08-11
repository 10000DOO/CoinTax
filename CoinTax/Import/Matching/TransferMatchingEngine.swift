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

    func suggest(events: [LedgerEvent], existing: [TransferLink]) -> [TransferMatchCandidate] {
        let linkedFrom = Set(existing.filter { $0.status == .confirmed || $0.status == .suggested }.map(\.fromEventID))
        let linkedTo = Set(existing.filter { $0.status == .confirmed || $0.status == .suggested }.map(\.toEventID))

        let withdrawals = events.filter {
            $0.type == .withdrawal && !$0.baseAsset.isKRW && !linkedFrom.contains($0.id)
        }
        let deposits = events.filter {
            $0.type == .deposit && !$0.baseAsset.isKRW && !linkedTo.contains($0.id)
        }

        var candidates: [TransferMatchCandidate] = []
        let window: TimeInterval = windowHours * 3600

        for w in withdrawals {
            var best: TransferMatchCandidate?
            for d in deposits {
                if d.accountID == w.accountID { continue }
                if d.baseAsset != w.baseAsset { continue }
                let dt = abs(d.timestamp.timeIntervalSince(w.timestamp))
                if dt > window { continue }
                let wQty = Money.abs(w.quantity)
                let dQty = Money.abs(d.quantity)
                if dQty > wQty * Decimal(string: "1.0001")! { continue }
                let lost = wQty - dQty
                if lost < 0 { continue }
                // IMPLEMENTATION §7: abs(out)−abs(in) <= max(abs(out)*0.01, 1e-6) (fee 별도 반영)
                let maxLost = max(
                    wQty * Decimal(string: "0.01")!,
                    w.feeAmount.map { Money.abs($0) } ?? 0,
                    Decimal(string: "0.000001")!
                )
                if lost > maxLost { continue }

                var score = 0.0
                score += 1.0 - min(dt / window, 1) * 0.5
                let lostRatio = (wQty == 0) ? 1.0 : NSDecimalNumber(decimal: lost / wQty).doubleValue
                score += (1 - lostRatio) * 0.3

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

                let cand = TransferMatchCandidate(
                    fromEventID: w.id,
                    toEventID: d.id,
                    withdrawnQty: wQty,
                    receivedQty: dQty,
                    score: score,
                    note: String(format: "dt=%.1fh lost=%@", dt / 3600, Money.decimalString(lost))
                )
                if best == nil || cand.score > best!.score {
                    best = cand
                }
            }
            if let best, best.score >= minScore {
                candidates.append(best)
            }
        }
        return candidates.sorted { $0.score > $1.score }
    }
}
