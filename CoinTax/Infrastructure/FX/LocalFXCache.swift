import Foundation

protocol FXClient: Sendable {
    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal]

    /// 이 클라이언트가 채운 값의 출처 태그.
    ///
    /// 리포트는 「외국환거래법상 기준환율(한국은행)」과 「참고 시세(공개 API)」를 구분해야 한다(TQ-05).
    /// **날짜별로** 알아야 한다 — 한 번의 조회에서 일부는 ECOS, 일부는 폴백일 수 있다.
    var sourceTag: String { get }

    /// 환율과 **날짜별 출처**를 함께 돌려준다.
    func fetchWithSources(days: [String]) async throws -> (rates: [String: Decimal], sources: [String: String])
}

extension FXClient {
    var sourceTag: String { "remote" }

    func fetchWithSources(days: [String]) async throws -> (rates: [String: Decimal], sources: [String: String]) {
        let rates = try await fetchUSD_KRW(days: days)
        return (rates, rates.mapValues { _ in sourceTag })
    }
}

/// 테스트용 빈 클라이언트.
struct RemoteFXClientStub: FXClient {
    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        [:]
    }
}

enum FXPreferences {
    private static let autoKey = "fx.autoFetchEnabled"
    private static let publicFallbackKey = "fx.allowPublicFallback"

    /// 기본값 true — 자동 환율 조회가 기본, 수동은 옵션.
    static var autoFetchEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    /// 공개 시세 폴백 허용 여부. **기본값 false**.
    ///
    /// 무료 공개 시세는 외국환거래법상 기준환율이 아니다(TQ-05).
    /// 한국은행 ECOS 인증키를 쓰는 것이 원칙이고, 폴백을 켜면 그 값을 「참고 시세」로 구분해 표시한다.
    static var allowPublicFallback: Bool {
        get { UserDefaults.standard.bool(forKey: publicFallbackKey) }
        set { UserDefaults.standard.set(newValue, forKey: publicFallbackKey) }
    }
}
