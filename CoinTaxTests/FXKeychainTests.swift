import XCTest
@testable import CoinTax

/// ECOS 인증키는 한 번 넣으면 계속 남아 있어야 하고, 저장에 실패하면 그 사실이 드러나야 한다.
///
/// 예전 구현은 `SecItemAdd` 의 결과를 버려서, 저장이 실패해도 화면에는 「저장됨」으로 보였다.
/// 그러면 다음 실행에 키가 사라지는데 사용자는 이유를 알 수 없다.
final class FXKeychainTests: XCTestCase {
    private var restore: String?

    override func setUp() {
        super.setUp()
        restore = FXKeychain.loadECOSKey()
    }

    override func tearDown() {
        FXKeychain.saveECOSKey(restore ?? "")
        super.tearDown()
    }

    func testSaveThenLoadRoundTrip() {
        let key = "TEST-\(UUID().uuidString.prefix(12))"
        let result = FXKeychain.saveECOSKey(key)
        XCTAssertFalse(result.isFailure, result.message)
        XCTAssertEqual(FXKeychain.loadECOSKey(), key, "다시 열었을 때 그대로 있어야 한다")
    }

    func testSaveTrimsWhitespace() {
        FXKeychain.saveECOSKey("  padded-key  \n")
        XCTAssertEqual(FXKeychain.loadECOSKey(), "padded-key", "붙여넣기로 들어온 공백·줄바꿈은 걸러낸다")
    }

    func testOverwriteReplacesPreviousKey() {
        FXKeychain.saveECOSKey("first-key")
        FXKeychain.saveECOSKey("second-key")
        XCTAssertEqual(FXKeychain.loadECOSKey(), "second-key", "항목이 중복 저장되면 안 된다")
    }

    func testClearRemovesKey() {
        FXKeychain.saveECOSKey("to-be-cleared")
        let result = FXKeychain.clearECOSKey()
        XCTAssertEqual(result, .cleared)
        XCTAssertNil(FXKeychain.loadECOSKey())
    }

    /// 빈 값 저장은 「지움」이지 「실패」가 아니다.
    func testEmptyKeyIsCleared() {
        XCTAssertEqual(FXKeychain.saveECOSKey(""), .cleared)
        XCTAssertEqual(FXKeychain.saveECOSKey("   "), .cleared)
    }

    /// 화면에는 전체 키를 다시 보여줄 이유가 없다.
    func testMaskedKeyHidesMiddle() {
        FXKeychain.saveECOSKey("ABCD1234567890WXYZ")
        let mask = FXKeychain.maskedECOSKey()
        XCTAssertEqual(mask, "ABCD…WXYZ")
        XCTAssertFalse(mask?.contains("1234567890") ?? true)
    }

    func testMaskedKeyIsNilWhenAbsent() {
        FXKeychain.clearECOSKey()
        XCTAssertNil(FXKeychain.maskedECOSKey())
    }
}
