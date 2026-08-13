import Foundation

protocol RoundingPolicy: Sendable {
    var id: String { get }
    /// 표시·대조용 1원 단위 반올림. **세액 산출에는 쓰지 않는다** (아래 두 함수를 쓴다).
    func roundKRW(_ value: Decimal) -> Decimal
    /// 과세표준의 1원 미만 버림
    func floorTaxBaseKRW(_ value: Decimal) -> Decimal
    /// 납부할 세액의 10원 미만 버림
    func floorPayableKRW(_ value: Decimal) -> Decimal
}

/// 국고금 관리법 제47조의 끝수 계산.
///
/// > ① 국고금의 수입 또는 지출에서 **10원 미만의 끝수**가 있을 때에는 그 끝수는 계산하지 아니한다.
/// > ② **국세의 과세표준액**을 산정할 때 **1원 미만**의 끝수가 있으면 이를 계산하지 아니한다.
///
/// 지방소득세도 같은 규칙이다 — 지방세기본법 §59 가 위 조문을 준용한다.
/// **국세와 지방세는 각각 별개의 징수금**이므로 따로 절사한다. 합쳐서 절사하면 안 된다.
///
/// 가상자산소득은 세액공제·감면이 없어 §64의3② 의 **결정세액이 곧 납부할 세액**이다.
/// 그래서 결정세액 단계에서 10원 절사를 적용한다.
struct StatutoryKRWRoundingPolicy: RoundingPolicy {
    let id = "statutory_krw_gfma_47"

    func roundKRW(_ value: Decimal) -> Decimal {
        Money.roundKRW(value)
    }

    func floorTaxBaseKRW(_ value: Decimal) -> Decimal {
        floor(value, unit: 1)
    }

    func floorPayableKRW(_ value: Decimal) -> Decimal {
        floor(value, unit: 10)
    }

    /// `unit` 배수로 내림. 자릿수가 넘쳐 유한하지 않은 값은 0 으로 접는다
    /// (검증기가 `V-NUM-01` 로 잡는다 — 여기서 조용히 통과시키면 세금 0원짜리 신고자료가 나간다).
    private func floor(_ value: Decimal, unit: Int) -> Decimal {
        guard value.isFinite else { return 0 }
        guard value > 0 else { return 0 }
        var scaled = value / Decimal(unit)
        var truncated = Decimal()
        NSDecimalRound(&truncated, &scaled, 0, .down)
        return truncated * Decimal(unit)
    }
}
