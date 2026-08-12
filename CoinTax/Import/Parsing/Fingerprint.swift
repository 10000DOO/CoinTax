import Foundation
import CryptoKit

enum Fingerprint {
    static func make(for event: LedgerEvent, parserID: String) -> String {
        if let ext = event.externalID, !ext.isEmpty {
            return "\(event.accountID.raw.uuidString)|\(parserID)|ext|\(ext)"
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = [
            iso.string(from: event.timestamp),
            event.type.rawValue,
            event.baseAsset.code,
            Money.decimalString(event.quantity),
            event.price.map { Money.decimalString($0) } ?? "",
            event.quoteAmount.map { Money.decimalString($0) } ?? "",
            event.feeAmount.map { Money.decimalString($0) } ?? "",
            event.rawRef ?? ""
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(event.accountID.raw.uuidString)|\(parserID)|h|\(hex)"
    }

    /// **내용 기준** 식별자 — 원본에서 몇 번째 줄이었는지는 보지 않는다.
    ///
    /// `make(for:)` 는 `rawRef`(행 번호)를 포함하므로, 기간이 겹치는 export 를 다시 가져오면
    /// 같은 거래가 다른 행 번호를 달고 와서 중복으로 쌓인다.
    /// 거래ID가 없는 파일(바이낸스 Spot·빗썸 확인서·제네릭)에서 실제로 발생한다.
    /// - Note: `parserID` 는 **키에 넣지 않는다.** 같은 계정의 같은 거래라면
    ///   어떤 파서로 읽었든 같은 거래다. 넣으면 프리셋으로 한 번, 제네릭 매핑으로 한 번
    ///   가져왔을 때 중복이 걸러지지 않는다. (인자는 호출부 호환을 위해 유지)
    static func contentKey(for event: LedgerEvent, parserID: String = "") -> String {
        let account = event.accountID.raw.uuidString
        if let ext = event.externalID, !ext.isEmpty {
            return "\(account)|ext|\(ext)"
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = [
            iso.string(from: event.timestamp),
            event.type.rawValue,
            event.baseAsset.code,
            event.quoteAsset?.code ?? "",
            canonicalDecimal(event.quantity),
            event.price.map { canonicalDecimal($0) } ?? "",
            event.quoteAmount.map { canonicalDecimal($0) } ?? "",
            event.quoteAmountKRW.map { canonicalDecimal($0) } ?? "",
            event.feeAmount.map { canonicalDecimal($0) } ?? ""
        ].joined(separator: "|")
        return "\(account)|c|\(sha256Hex(payload))"
    }

    /// 소수 자릿수 표기 차이를 없앤 값.
    ///
    /// 거래소는 같은 수량을 export 판본에 따라 `0.01` 로도, `0.01000000` 으로도 쓴다.
    /// `Decimal` 은 자릿수를 그대로 보존하므로 문자열이 달라지고, 그러면 같은 거래가
    /// 다른 거래로 보여 중복 판정을 빠져나간다.
    static func canonicalDecimal(_ d: Decimal) -> String {
        var s = Money.decimalString(d)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// 파일 원본 바이트 해시. 이진 파일(PDF/XLSX)을 텍스트로 해석하면 손실이 생겨
    /// 파일 단위 중복 판정에 쓸 수 없다 (리뷰 4-3).
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
