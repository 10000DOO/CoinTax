import Foundation

/// 의제취득가에서 「실제 취득가 vs 시가」 비교를 **어느 단위로** 하는지.
///
/// 세무 확인 대기 항목(TQ-01). 두 방식 모두 지원하고, 리포트에서 결과 차이를 함께 보여준다.
enum DeemedBasisMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 보유 전체 평균 취득단가와 시가를 비교 (기본).
    ///
    /// **「보수적」이라고 단정하면 안 된다.** 보유 전체로 보면 취득가가 건별 방식보다 작게 잡히는 게 맞지만,
    /// **일부만 판 해**에는 선입선출로 먼저 나가는 싼 매입 건에도 평균 단가가 붙어
    /// 그해 세금이 건별 방식보다 **작아질 수 있다** (무작위 시나리오 80개 중 10개에서 실제로 뒤집혔다).
    case positionAverage
    /// 매입 건(lot)별로 각각 시가와 비교 — 선입선출 계정에서만 의미가 있다
    case perLot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .positionAverage: return "보유 전체 평균으로 비교"
        case .perLot: return "매입 건별로 비교"
        }
    }

    var detail: String {
        switch self {
        case .positionAverage:
            return "자산별 평균 취득단가와 2027-01-01 0시 시가 중 큰 값을 씁니다. 보유 **전체**로 보면 취득가가 건별 방식보다 작게 잡힙니다. 다만 일부만 판 해에는 먼저 나가는 싼 매입 건에도 평균 단가가 붙어, 그해 세금이 오히려 건별 방식보다 작아질 수 있습니다."
        case .perLot:
            return "매입 건마다 그 단가와 시가 중 큰 값을 씁니다. 보유 **전체** 취득가는 평균 방식보다 크거나 같습니다. 다만 일부만 판 해에는 먼저 나가는 싼 매입 건이 싼 채로 남아 그해 세금이 더 나올 수 있습니다. 이동평균 계정(빗썸)은 매입 건 구분이 없어 평균 방식으로 동작합니다."
        }
    }

    var other: DeemedBasisMode {
        self == .positionAverage ? .perLot : .positionAverage
    }
}

protocol DeemedCostPolicy: Sendable {
    var id: String { get }
    var mode: DeemedBasisMode { get }
    func deemedUnit(bookUnit: Decimal, marketUnit: Decimal?) -> Decimal?
}

struct MaxBookMarketDeemedPolicy: DeemedCostPolicy {
    var mode: DeemedBasisMode

    init(mode: DeemedBasisMode = .positionAverage) {
        self.mode = mode
    }

    var id: String {
        switch mode {
        case .positionAverage: return "max_book_market_2026-12-31"
        case .perLot: return "max_lot_market_2026-12-31"
        }
    }

    func deemedUnit(bookUnit: Decimal, marketUnit: Decimal?) -> Decimal? {
        guard let market = marketUnit else { return nil }
        return max(bookUnit, market)
    }
}

enum DeemedPreferences {
    private static let key = "deemed.basisMode"

    /// 기본값은 평균 방식 (TQ-01 확인 전까지).
    /// 「보수적」이라고 부르지 않는다 — 보유 전체 취득가는 작게 잡히지만 **그해 세액 방향은 뒤집힐 수 있다**.
    static var basisMode: DeemedBasisMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let mode = DeemedBasisMode(rawValue: raw) else { return .positionAverage }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
