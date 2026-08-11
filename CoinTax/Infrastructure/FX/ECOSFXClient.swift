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

/// 키 없이 동작하는 일별 공개 시세 폴백 (공식 기준환율 아님 — source 태깅).
/// https://github.com/fawazahmed0/currency-api
struct PublicUSDKRWClient: FXClient {
    var session: URLSession = .shared

    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        // 병렬 제한: 순차 (rate limit 완화)
        for day in days.sorted() {
            if let rate = try await fetchOne(day: day) {
                out[day] = rate
            }
        }
        return out
    }

    private func fetchOne(day: String) async throws -> Decimal? {
        // @latest for future dates falls back poorly — try exact day then previous days
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TaxTime.seoul
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TaxTime.seoul
        f.dateFormat = "yyyy-MM-dd"
        guard var date = f.date(from: day) else { return nil }

        for _ in 0..<10 {
            let dstr = f.string(from: date)
            let urls = [
                URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(dstr)/v1/currencies/usd.min.json"),
                URL(string: "https://\(dstr).currency-api.pages.dev/v1/currencies/usd.min.json")
            ].compactMap { $0 }

            for url in urls {
                if let rate = try? await getKRW(from: url) {
                    return rate
                }
            }
            date = cal.date(byAdding: .day, value: -1, to: date) ?? date
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
struct CompositeFXClient: FXClient {
    var ecosKeyProvider: @Sendable () -> String? = { FXKeychain.loadECOSKey() }

    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        if let key = ecosKeyProvider(), !key.isEmpty {
            let ecos = try await ECOSFXClient(apiKey: key).fetchUSD_KRW(days: days)
            for (k, v) in ecos { result[k] = v }
        }
        let missing = days.filter { result[$0] == nil }
        if !missing.isEmpty {
            let pub = try await PublicUSDKRWClient().fetchUSD_KRW(days: missing)
            for (k, v) in pub where result[k] == nil {
                result[k] = v
            }
        }
        // 휴일: 요청일은 있는데 값 없으면 직전 고시일로 채움 (ECOS 범위 내)
        if !result.isEmpty {
            for day in days where result[day] == nil {
                if let prev = nearestPrevious(day: day, in: result) {
                    result[day] = prev
                }
            }
        }
        return result
    }

    private func nearestPrevious(day: String, in map: [String: Decimal]) -> Decimal? {
        let keys = map.keys.sorted()
        let prev = keys.filter { $0 < day }.last
        return prev.flatMap { map[$0] }
    }
}
