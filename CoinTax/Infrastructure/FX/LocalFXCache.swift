import Foundation

/// In-memory FX day→rate cache (USD/KRW).
final class LocalFXCache: @unchecked Sendable {
    private var rates: [String: Decimal] = [:]
    private let lock = NSLock()

    func set(day: String, rate: Decimal) {
        lock.lock(); rates[day] = rate; lock.unlock()
    }

    func get(day: String) -> Decimal? {
        lock.lock(); defer { lock.unlock() }
        return rates[day]
    }

    func all() -> [String: Decimal] {
        lock.lock(); defer { lock.unlock() }
        return rates
    }
}

protocol FXClient: Sendable {
    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal]
}

/// 테스트용 빈 클라이언트.
struct RemoteFXClientStub: FXClient {
    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        [:]
    }
}

enum FXPreferences {
    private static let autoKey = "fx.autoFetchEnabled"

    /// 기본값 true — 자동 환율 조회가 기본, 수동은 옵션.
    static var autoFetchEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }
}
