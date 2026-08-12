import Foundation

/// 한국은행 ECOS Open API — 주요국 통화 대원화환율 일별 (USD = 0000001).
/// 통계표: 731Y001, 주기 D.
/// 문서: https://ecos.bok.or.kr/api/
struct ECOSFXClient: FXClient {
    var apiKey: String
    var session: URLSession = .shared

    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [:] }
        let sorted = days.sorted()
        guard let first = sorted.first, let last = sorted.last else { return [:] }

        // 휴일 롤백용으로 시작일 전 14일 버퍼
        let start = shiftDay(first, by: -14) ?? first
        let end = last
        let startCompact = start.replacingOccurrences(of: "-", with: "")
        let endCompact = end.replacingOccurrences(of: "-", with: "")

        // /api/StatisticSearch/{key}/json/kr/1/10000/{stat}/D/{start}/{end}/{item}
        let path = "https://ecos.bok.or.kr/api/StatisticSearch/\(key)/json/kr/1/10000/731Y001/D/\(startCompact)/\(endCompact)/0000001"
        guard let url = URL(string: path) else { return [:] }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        return try parseECOS(data: data)
    }

    private func parseECOS(data: Data) throws -> [String: Decimal] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        // Error shape: { "RESULT": { "CODE": "...", "MESSAGE": "..." } }
        if let result = obj["RESULT"] as? [String: Any],
           let code = result["CODE"] as? String,
           code != "INFO-000" {
            // invalid key etc.
            return [:]
        }
        let root = (obj["StatisticSearch"] as? [String: Any]) ?? obj
        let rows = (root["row"] as? [[String: Any]]) ?? []
        var map: [String: Decimal] = [:]
        for row in rows {
            let time = (row["TIME"] as? String) ?? ""
            let value = (row["DATA_VALUE"] as? String) ?? (row["DATA_VALUE"] as? NSNumber)?.stringValue ?? ""
            guard time.count >= 8, let rate = Money.parseDecimal(value), rate > 0 else { continue }
            let day = "\(time.prefix(4))-\(time.dropFirst(4).prefix(2))-\(time.suffix(2))"
            map[day] = rate
        }
        return map
    }

    private func shiftDay(_ day: String, by delta: Int) -> String? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TaxTime.seoul
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        guard let nd = Calendar(identifier: .gregorian).date(byAdding: .day, value: delta, to: d) else { return nil }
        return f.string(from: nd)
    }
}

/// 키 없이 동작하는 일별 공개 시세 폴백 (**공식 기준환율 아님** — source 태깅).
/// https://github.com/fawazahmed0/currency-api
///
/// ⚠️ 이 클라이언트는 **요청한 날짜에 값이 있을 때만** 반환한다.
/// 과거로 되짚어 찾은 값을 요청일 키로 돌려주면, 휴일 대체 사실이 사라지고
/// 장부에 "그 날 고시된 환율"로 잘못 기록된다(리뷰 1-4).
/// 되짚기는 `FXHolidayPolicy` 한 곳에서만 수행하고 실제 고시일을 함께 남긴다.
struct PublicUSDKRWClient: FXClient {
    var session: URLSession = .shared
    /// 한 번의 자동 채우기에서 보낼 최대 요청 수 (요청 폭주 방지 — 리뷰 6-3)
    var maxRequests: Int = 90

    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        // 병렬 제한: 순차 (rate limit 완화)
        for day in days.sorted().prefix(maxRequests) {
            if let rate = try await fetchOne(day: day) {
                out[day] = rate
            }
        }
        return out
    }

    private func fetchOne(day: String) async throws -> Decimal? {
        let urls = [
            URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(day)/v1/currencies/usd.min.json"),
            URL(string: "https://\(day).currency-api.pages.dev/v1/currencies/usd.min.json")
        ].compactMap { $0 }
        for url in urls {
            if let rate = try? await getKRW(from: url) {
                return rate
            }
        }
        return nil
    }

    private func getKRW(from url: URL) async throws -> Decimal? {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // { "usd": { "krw": 1350.12 } }
        if let usd = obj["usd"] as? [String: Any] {
            if let n = usd["krw"] as? Double {
                return Decimal(string: String(n))
            }
            if let s = usd["krw"] as? String, let d = Money.parseDecimal(s) {
                return d
            }
            if let n = usd["krw"] as? NSNumber {
                return Decimal(string: n.stringValue)
            }
        }
        return nil
    }
}

/// ECOS 우선, 없으면 공개 폴백. 날짜별 병합.
///
/// **되짚기(휴일 대체)를 하지 않는다.** 고시가 있는 날짜만 그대로 반환하고,
/// 미고시일 처리는 `FXHolidayPolicy`가 실제 고시일을 남기며 담당한다(리뷰 1-4).
struct CompositeFXClient: FXClient {
    var ecosKeyProvider: @Sendable () -> String? = { FXKeychain.loadECOSKey() }
    /// 공개 시세 폴백 허용 여부. 기본은 설정값(기본 false)을 따른다 — TQ-05
    var allowPublicFallback: @Sendable () -> Bool = { FXPreferences.allowPublicFallback }

    /// 조회 결과에 대한 진단 (UI 안내용)
    enum Outcome: String, Sendable {
        case ok                 // ECOS 로 채움
        case noKey              // 인증키 없음 → 발급 안내 필요
        case keyRejected        // 키가 있는데 응답이 비어 있음 → 키 확인 필요
        case publicFallbackUsed // 공개 시세로 채움 (기준환율 아님)
    }

    /// 마지막 조회의 진단을 받아가는 콜백
    var onOutcome: (@Sendable (Outcome) -> Void)? = nil

    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        let key = ecosKeyProvider()
        let hasKey = (key?.isEmpty == false)

        if hasKey, let key {
            let ecos = try await ECOSFXClient(apiKey: key).fetchUSD_KRW(days: days)
            for (k, v) in ecos { result[k] = v }
            onOutcome?(ecos.isEmpty ? .keyRejected : .ok)
        } else {
            onOutcome?(.noKey)
        }

        let missing = days.filter { result[$0] == nil }
        guard !missing.isEmpty, allowPublicFallback() else { return result }

        let pub = try await PublicUSDKRWClient().fetchUSD_KRW(days: missing)
        for (k, v) in pub where result[k] == nil {
            result[k] = v
        }
        if !pub.isEmpty { onOutcome?(.publicFallbackUsed) }
        return result
    }
}
