import Foundation
import CryptoKit

enum Fingerprint {
    static func make(for event: LedgerEvent, parserID: String) -> String {
        if let ext = event.externalID, !ext.isEmpty {
            return "\(event.accountID.raw.uuidString)|\(parserID)|ext|\(ext)"
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        let ts = iso.string(from: event.timestamp)
        let tsFallback = isoBasic.string(from: event.timestamp)
        let payload = [
            ts.isEmpty ? tsFallback : ts,
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

    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
