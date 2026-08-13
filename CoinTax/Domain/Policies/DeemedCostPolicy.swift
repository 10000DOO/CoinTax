import Foundation

/// 의제취득가에서 「실제 취득가 vs 시가」 비교를 **어느 단위로** 하는지.
///
/// 세무 확인 대기 항목(TQ-01). 두 방식 모두 지원하고, 리포트에서 결과 차이를 함께 보여준다.
/// 의제취득가에서 「실제 취득가 vs 시가」를 **어느 단위로** 비교하는지.
///
/// `[영]` 소득세법 시행령 §88① 이 거주자별 총평균법이 되면서 **매입 건(lot) 개념 자체가 사라졌다.**
/// 비교 대상은 자산별 거주자 단가 하나뿐이라 고를 여지가 없다 — 예전의 「매입 건별」 선택지는
/// 계산할 lot 이 존재하지 않아 성립하지 않는다 (작업문서 Q1 결정).
///
/// 저장된 과거 계산 스냅샷이 이 값을 문자열로 들고 있어 형(type)은 남긴다.
enum DeemedBasisMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 자산별 거주자 평균 취득단가와 2027-01-01 0시 시가를 비교
    case positionAverage

    var id: String { rawValue }

    var label: String { "거주자별 평균으로 비교" }

    var detail: String {
        "같은 종류 코인을 거래소·지갑 가리지 않고 하나로 묶은 평균 취득단가와 2027-01-01 0시 시가 중 큰 값을 씁니다 (소득세법 시행령 제88조제1항)."
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

    var id: String { "max_book_market_2026-12-31" }

    func deemedUnit(bookUnit: Decimal, marketUnit: Decimal?) -> Decimal? {
        guard let market = marketUnit else { return nil }
        return max(bookUnit, market)
    }
}

enum DeemedPreferences {
    private static let key = "deemed.basisMode"

    /// 총평균법에서는 고를 여지가 없다. 저장된 옛 값이 있어도 무시한다.
    static var basisMode: DeemedBasisMode {
        get { .positionAverage }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
