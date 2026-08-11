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

/// Optional remote stub — always empty (offline default).
struct RemoteFXClientStub: FXClient {
    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        [:]
    }
}
