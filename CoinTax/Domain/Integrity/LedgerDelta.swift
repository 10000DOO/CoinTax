import Foundation

/// 「이 거래로 어느 자산이 얼마나 늘고 줄었는가」를 정하는 **규칙 한 벌**.
///
/// 원가 엔진·검증기·잔고 대조가 각자 이 규칙을 다시 쓰면, 셋이 사이좋게 같은 실수를 하고
/// 아무도 못 잡는다. 실제로 그런 일이 있었다 — 매도 수수료 규칙이 엔진과 검증기에 따로 적혀 있었고,
/// 둘 다 틀린 채로 서로를 통과시켰다 (`docs/audit-2026-08-12-logic.md` A-03).
/// 그래서 규칙은 여기 한 곳에만 둔다.
enum LedgerDelta {
    struct Change: Equatable, Sendable {
        var asset: AssetSymbol
        var delta: Decimal
    }

    /// 수수료가 **수수료 자산 장부의 수량을 별도로 줄이는가**.
    ///
    /// - 원화 수수료: 장부와 무관 (금액일 뿐)
    /// - 매수의 기초자산 수수료: 받는 수량에서 이미 차감했다 → 다시 빼지 않는다
    /// - 매도의 기초자산 수수료: 체결 수량과 **별도로** 빠진다 → 뺀다
    ///   (원본이 이미 순액인 판본 `quantityIsNetOfFee` 만 예외)
    /// - 그 밖의 코인 수수료(USDT·BNB…): 항상 뺀다
    static func feeReducesBook(_ e: LedgerEvent, feeAsset fa: AssetSymbol) -> Bool {
        guard e.type == .buy || e.type == .sell, !fa.isKRW else { return false }
        guard fa == e.baseAsset else { return true }
        if e.type == .buy { return false }
        return !e.quantityIsNetOfFee
    }

    /// 출금 수수료가 **원금과 별도로** 같은 자산에서 더 빠지는 수량 (바이낸스 Withdraw 의 `Fee` 열).
    ///
    /// - 수수료 자산이 비어 있으면 **보내는 코인**으로 본다. 출금 수수료는 네트워크 수수료라
    ///   거의 언제나 보내는 코인으로 낸다.
    /// - **다른 자산(원화·제3코인)으로 적혀 있으면 이 코인 수량은 줄지 않는다.**
    ///   예전에는 엔진의 「연결 안 된 출금」 갈래만 이 조건을 빠뜨려, 원화 1,500원짜리 수수료가
    ///   코인 1,500개를 처분했다 (감사 D4-1 — D-1 과 같은 「수수료 자산 넘겨짚기」의 마지막 한 곳).
    ///   규칙을 여기 한 곳에 두고 엔진이 그대로 쓰게 한다.
    static func withdrawalFeeQuantity(_ e: LedgerEvent) -> Decimal? {
        guard e.type == .withdrawal, !e.quantityIsNetOfFee else { return nil }
        guard let fee = e.feeAmount, fee > 0 else { return nil }
        guard e.feeAsset == nil || e.feeAsset == e.baseAsset else { return nil }
        return Money.abs(fee)
    }

    /// **원가 장부 기준** 변화.
    ///
    /// 계정 안의 지갑 이동(`transferInternal`)은 계정×자산 단일 장부라 총수량이 변하지 않는다.
    static func bookChanges(for e: LedgerEvent) -> [Change] {
        core(e)
    }

    /// **거래소 명세서 기준** 변화.
    ///
    /// 거래소가 주는 파일은 서브계정 하나(OKX 의 펀딩 계정 / 트레이딩 계정)를 보여준다.
    /// 그 안에서는 내부 이동도 잔고를 움직이므로 장부 기준과 다르다.
    /// 잔고 열 대조(V-BAL)는 이쪽을 써야 한다.
    static func statementChanges(for e: LedgerEvent) -> [Change] {
        if e.type == .transferInternal {
            guard !e.baseAsset.isKRW, e.quantity != 0 else { return [] }
            return [Change(asset: e.baseAsset, delta: e.quantity)]
        }
        return core(e)
    }

    private static func core(_ e: LedgerEvent) -> [Change] {
        guard e.type != .ignored else { return [] }
        var out: [Change] = []
        let qty = Money.abs(e.quantity)

        switch e.type {
        case .buy:
            var net = qty
            // base 자산 수수료는 받는 수량에서 깎인다. 원본이 이미 순액이면 다시 빼지 않는다.
            if !e.quantityIsNetOfFee, let fa = e.feeAsset, fa == e.baseAsset, let fee = e.feeAmount {
                net = max(0, qty - Money.abs(fee))
            }
            out.append(Change(asset: e.baseAsset, delta: net))
        case .sell:
            out.append(Change(asset: e.baseAsset, delta: -qty))
        case .deposit, .income:
            out.append(Change(asset: e.baseAsset, delta: qty))
        case .withdrawal:
            out.append(Change(asset: e.baseAsset, delta: -qty))
            if let feeQty = withdrawalFeeQuantity(e) {
                out.append(Change(asset: e.baseAsset, delta: -feeQty))
            }
        case .transferInternal, .fee, .fiatDeposit, .fiatWithdraw, .other, .ignored:
            break
        }

        // 코인↔코인 매매의 견적자산 leg — 매수는 나가고 매도는 들어온다
        if let quote = e.quoteAsset, let quoteQty = e.cryptoQuoteQuantity {
            out.append(Change(asset: quote, delta: e.type == .buy ? -quoteQty : quoteQty))
        }
        // 코인으로 낸 수수료
        if let fa = e.feeAsset, let fee = e.feeAmount, fee != 0, feeReducesBook(e, feeAsset: fa) {
            out.append(Change(asset: fa, delta: -Money.abs(fee)))
        }
        return out.filter { !$0.asset.isKRW }
    }
}
