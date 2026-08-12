import Foundation
import Security

/// ECOS 인증키 등 민감값 — **Keychain 에만** 둔다.
///
/// Keychain 항목은 macOS 가 로그인 암호로 파생한 키로 암호화해 보관한다.
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 라서
/// ① 화면 잠금이 풀린 동안에만 읽히고 ② **이 Mac 밖으로 백업·동기화되지 않는다.**
/// 평문 파일이나 UserDefaults 에 두면 그냥 읽히므로 여기를 우회하지 말 것.
enum FXKeychain {
    private static let service = "com.10000DOO.CoinTax.fx"
    private static let account = "ecos-api-key"

    enum SaveResult: Equatable {
        case saved
        case cleared
        /// 저장에 실패했다. 조용히 넘기면 「저장됨」으로 보이지만 다음 실행에 사라진다.
        case failed(OSStatus)

        var isSuccess: Bool { self != .failed(0) && !isFailure }
        var isFailure: Bool { if case .failed = self { return true }; return false }

        var message: String {
            switch self {
            case .saved: return "이 Mac 의 키체인에 암호화해 저장했습니다."
            case .cleared: return "저장된 인증키를 지웠습니다."
            case .failed(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "코드 \(status)"
                return "키체인에 저장하지 못했습니다 (\(detail))"
            }
        }
    }

    @discardableResult
    static func saveECOSKey(_ key: String) -> SaveResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return .cleared }

        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrDescription as String] = "CoinTax 환율 조회용 한국은행 ECOS 인증키"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { return .failed(status) }

        // 다시 읽어 확인한다. 쓰기가 «성공» 해도 정책상 못 읽는 경우가 있어,
        // 실제로 되읽히는지까지 봐야 「저장됨」이라고 말할 수 있다.
        guard loadECOSKey() == trimmed else { return .failed(errSecItemNotFound) }
        return .saved
    }

    static func loadECOSKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    @discardableResult
    static func clearECOSKey() -> SaveResult {
        saveECOSKey("")
    }

    /// 화면에 보여줄 가림 표기 — `A1B2…9Z8Y`. 전체를 다시 보여줄 이유가 없다.
    static func maskedECOSKey() -> String? {
        guard let key = loadECOSKey() else { return nil }
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(4))…\(key.suffix(4))"
    }
}
