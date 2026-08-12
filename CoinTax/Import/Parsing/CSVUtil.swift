import Foundation

enum CSVUtil {
    /// 헤더 → 컬럼 인덱스.
    ///
    /// `Dictionary(uniqueKeysWithValues:)`는 키가 겹치면 프로세스를 종료시킨다.
    /// 빈 열이 둘 이상이거나 열 이름이 중복된 파일에서 앱이 죽는 원인이었다(리뷰 4-1).
    /// 여기서는 첫 번째 열을 채택하고 중복은 무시한다.
    static func headerIndex(_ header: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, raw) in header.enumerated() {
            let key = stripBOM(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if map[key] == nil { map[key] = i }
        }
        return map
    }

    /// 헤더 중복 목록 (경고 노출용)
    static func duplicateHeaders(_ header: [String]) -> [String] {
        var seen: Set<String> = []
        var dupes: [String] = []
        for raw in header {
            let key = stripBOM(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if seen.contains(key), !dupes.contains(key) { dupes.append(key) }
            seen.insert(key)
        }
        return dupes
    }

    /// 엑셀이 붙이는 바이트 순서 표식(BOM) 제거. 남겨두면 첫 열 이름이 달라져 헤더 검증이 실패한다(리뷰 2-3).
    static func stripBOM(_ s: String) -> String {
        var out = s
        while let first = out.unicodeScalars.first, first == "\u{FEFF}" {
            out.unicodeScalars.removeFirst()
        }
        return out
    }

    /// UTF-8 우선, 실패 시 국내 환경에서 흔한 인코딩으로 폴백해 텍스트를 읽는다.
    static func readText(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let candidates: [String.Encoding] = [.utf8, .utf16, .init(rawValue: 0x0422) /* CP949 */, .isoLatin1]
        for enc in candidates {
            if let s = String(data: data, encoding: enc), !s.isEmpty {
                return stripBOM(s)
            }
        }
        throw CoinTaxError.parseRow("텍스트 인코딩을 인식할 수 없습니다 (\(url.lastPathComponent))")
    }

    /// CSV 텍스트 → 행·필드 배열.
    ///
    /// **유니코드 스칼라 단위로 순회한다.** `Character` 로 순회하면 Swift 가 `"\r\n"` 을
    /// **한 개의 문자**로 묶어 버려 `case "\n"`·`case "\r"` 어디에도 걸리지 않고,
    /// 윈도우 줄바꿈 파일 전체가 한 행으로 읽힌다 (거래소 export 는 대부분 CRLF).
    static func parseLines(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let lf: Unicode.Scalar = "\n"
        let cr: Unicode.Scalar = "\r"
        let bom: Unicode.Scalar = "\u{FEFF}"

        // OKX 는 **줄마다** BOM 을 넣는다. 필드 선두에서 걷어내지 않으면 값·헤더가 오염된다.
        func pushField() {
            var f = field
            while let first = f.unicodeScalars.first, first == bom {
                f.unicodeScalars.removeFirst()
            }
            current.append(f)
            field = ""
        }
        func endRow() {
            pushField()
            if current.count > 1 || !(current.first?.isEmpty ?? true) {
                rows.append(current)
            }
            current = []
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        field.unicodeScalars.append(quote)
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case quote:
                    inQuotes = true
                case comma:
                    pushField()
                case lf:
                    endRow()
                case cr:
                    endRow()
                    // CRLF 는 한 번만 끊는다
                    if i + 1 < scalars.count && scalars[i + 1] == lf { i += 1 }
                default:
                    field.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        pushField()
        if current.count > 1 || !(current.first?.isEmpty ?? true) {
            rows.append(current)
        }
        return rows
    }

    static func dictRows(header: [String], dataRows: [[String]]) -> [[String: String]] {
        dataRows.map { row in
            var d: [String: String] = [:]
            for (idx, key) in header.enumerated() {
                d[key] = idx < row.count ? row[idx] : ""
            }
            return d
        }
    }

    static func parseTimezoneOffset(_ meta: String) -> TimeZone {
        // Time Zone:UTC+8 or UTC+08:00
        if let r = meta.range(of: #"UTC([+-]\d{1,2})(?::(\d{2}))?"#, options: .regularExpression) {
            let token = String(meta[r])
            let cleaned = token.replacingOccurrences(of: "UTC", with: "")
            let parts = cleaned.split(separator: ":")
            let hours = Int(parts[0]) ?? 0
            let minutes = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            let seconds = hours * 3600 + (hours >= 0 ? minutes * 60 : -minutes * 60)
            return TimeZone(secondsFromGMT: seconds) ?? TimeZone(secondsFromGMT: 0)!
        }
        return TimeZone(secondsFromGMT: 0)!
    }

    /// 파일명에 박힌 타임존 표기를 읽는다 — 예: `Binance-Spot-Trade-History-202608111215(UTC+9)-part1-of1.csv`
    ///
    /// 거래소 화면 export 는 **사용자가 고른 표시 타임존**으로 시각을 적고 그 사실을 파일명에만 남긴다.
    /// UTC 로 단정하면 최대 하루가 밀려 환율 적용일과 **과세연도 귀속**(2027-01-01 00:00 KST 경계)이 틀어진다.
    static func timeZoneFromFileName(_ fileName: String) -> TimeZone? {
        guard fileName.range(of: #"UTC[+-]\d"#, options: .regularExpression) != nil else { return nil }
        return parseTimezoneOffset(fileName)
    }

    /// 날짜 열 이름과 파일명에서 시각 해석 타임존을 정한다.
    ///
    /// - `Date(UTC+0)` 처럼 **열 이름에 타임존이 박혀 있으면** 그것이 가장 확실하다.
    /// - 그 외(`Time`)는 파일명의 `(UTC±H)` 표기를 쓴다.
    /// - 둘 다 없으면 UTC 로 두고 경고한다 — 하루 밀리면 환율 적용일과 과세연도가 달라진다.
    static func resolveExportTimeZone(dateKey: String, fileName: String, warnings: inout [String]) -> TimeZone {
        if dateKey.range(of: #"UTC[+-]\d"#, options: .regularExpression) != nil {
            return parseTimezoneOffset(dateKey)
        }
        if dateKey.contains("UTC") { return TimeZone(secondsFromGMT: 0)! }
        if let fromName = timeZoneFromFileName(fileName) { return fromName }
        warnings.append("'\(dateKey)' 열의 타임존을 알 수 없어 UTC 로 해석했습니다 — 시각이 밀리면 환율 적용일·과세연도가 달라집니다")
        return TimeZone(secondsFromGMT: 0)!
    }

    /// `0.1234XAUT` · `500.123456USDT` 처럼 숫자에 단위가 붙은 값을 분리한다.
    ///
    /// 바이낸스 거래내역 화면 CSV 는 `Executed`·`Amount`·`Fee` 를 이렇게 쓴다.
    /// `Pair`(`XAUTUSDT`)는 구분자가 없어 base/quote 를 쪼개기 모호하므로, 심볼은 이 접미사에서 얻는다.
    static func splitAmountUnit(_ raw: String) -> (amount: Decimal, unit: String?)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let unitStart = s.firstIndex { $0.isLetter }
        guard let unitStart else {
            return Money.parseDecimal(s).map { ($0, nil) }
        }
        let number = String(s[s.startIndex..<unitStart])
        let unit = String(s[unitStart...]).trimmingCharacters(in: .whitespaces)
        guard let amount = Money.parseDecimal(number) else { return nil }
        return (amount, unit.isEmpty ? nil : unit)
    }

    static func parseDate(_ string: String, timeZone: TimeZone, formats: [String]) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: string.trimmingCharacters(in: .whitespaces)) {
                return d
            }
        }
        return nil
    }
}
