import Foundation

enum CSVUtil {
    static func parseLines(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    current.append(field)
                    field = ""
                case "\n":
                    current.append(field)
                    field = ""
                    if current.count > 1 || !(current.first?.isEmpty ?? true) {
                        rows.append(current)
                    }
                    current = []
                case "\r":
                    break
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        current.append(field)
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
