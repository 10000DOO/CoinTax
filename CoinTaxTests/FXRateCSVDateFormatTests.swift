import XCTest
import SwiftData
@testable import CoinTax

/// 환율 CSV 의 **날짜 표기가 다르면** 어떻게 되는가 (5차 감사).
///
/// 환율표는 은행·중개사에서 받아 온다. 그 파일의 날짜는 `2027-01-05` 만 있는 게 아니라
/// `2027/01/05`·`2027.01.05`·`20270105` 로도 나온다.
/// 저장 키는 `yyyy-MM-dd` 하나뿐이므로, 표기가 다르면 **저장은 되는데 아무도 못 찾는다.**
/// 그러면 그 날 환율은 없는 것이 되고, 휴일 대체 규칙이 **최대 14일 전 환율**을 대신 쓴다 —
/// 사용자는 「직전 고시일 적용」이라는 안내만 보고 자기가 넣은 값이 무시된 줄 모른다.
@MainActor
final class FXRateCSVDateFormatTests: XCTestCase {

    private func makeProject() throws -> (ModelContext, ProjectEntity) {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = try ProjectService(modelContext: ctx).createProject(name: "fx")
        return (ctx, project)
    }

    func testSlashAndDotAndCompactDatesAreStored() throws {
        let (ctx, project) = try makeProject()
        let fx = FXService(modelContext: ctx)

        let csv = """
        date,rate
        2027-01-04,1300
        2027/01/05,1400
        2027.01.06,1500
        20270107,1600
        """
        let n = try fx.importRatesCSV(text: csv, project: project)
        XCTAssertEqual(n, 4, "가져왔다고 센 건수")

        let map = fx.ratesMap(for: project)
        XCTAssertEqual(map["2027-01-04"], 1300)
        XCTAssertEqual(map["2027-01-05"], 1400, "슬래시 표기가 저장 키로 정규화되지 않았다")
        XCTAssertEqual(map["2027-01-06"], 1500, "점 표기가 저장 키로 정규화되지 않았다")
        XCTAssertEqual(map["2027-01-07"], 1600, "구분자 없는 표기가 저장 키로 정규화되지 않았다")
    }

    /// 가장 위험한 결과 — 내가 넣은 그날 환율이 무시되고 **며칠 전 환율**이 쓰인다.
    func testWrongFormatSilentlyFallsBackToAnOlderRate() throws {
        let (ctx, project) = try makeProject()
        let fx = FXService(modelContext: ctx)

        // 1/2 는 표준 표기(저장됨), 1/5 는 슬래시 표기
        let csv = """
        date,rate
        2027-01-02,1300
        2027/01/05,1400
        """
        _ = try fx.importRatesCSV(text: csv, project: project)

        let resolved = try XCTUnwrap(fx.resolveRate(eventDay: "2027-01-05", project: project))
        XCTAssertEqual(resolved.rate, 1400, "그날 넣은 환율이 아니라 다른 날 환율이 쓰였다")
        XCTAssertFalse(resolved.usedPreviousPublished, "그날 환율이 있는데 직전 고시일로 대체했다")
    }

    /// 손으로 넣는 칸도 같은 문제가 있었다 — 저장 키 정규화는 `setRate` 한 곳에서 한다.
    func testManualEntryIsNormalizedOrRejected() throws {
        let (ctx, project) = try makeProject()
        let fx = FXService(modelContext: ctx)

        try fx.setRate(day: "2027/03/02", rate: 1350, project: project)
        XCTAssertEqual(fx.ratesMap(for: project)["2027-03-02"], 1350, "손으로 넣은 슬래시 날짜가 정규화되지 않았다")

        // 알아볼 수 없는 표기는 **조용히 저장하면 안 된다** — 저장되면 영영 안 쓰이는 값이 된다
        XCTAssertThrowsError(try fx.setRate(day: "03/02/2027", rate: 9999, project: project))
        // 두 자리 연도는 `yyyy-MM-dd` 로도 파싱에 성공해 **서기 27년**이 된다 — 반드시 거부해야 한다
        XCTAssertThrowsError(try fx.setRate(day: "27-03-02", rate: 9999, project: project),
                             "두 자리 연도가 서기 27년으로 저장됐다 — 그 환율은 영영 안 쓰인다")
        XCTAssertEqual(fx.ratesMap(for: project).count, 1)
        XCTAssertNil(fx.ratesMap(for: project).keys.first { $0.hasPrefix("00") })
    }

    /// 국내 은행·중개사 환율표는 **CP949** 인 경우가 흔하다 — 파일 경로로 넣어도 읽혀야 한다.
    ///
    /// 회차 3 에서 인코딩 폴백을 고쳤는데, 환율 CSV 만 화면에서 UTF-8 로 강제 읽고 있어
    /// **이 갈래만 남아 있었다** (회차 27).
    func testCP949RateFileIsImportedFromURL() throws {
        let (ctx, project) = try makeProject()
        let fx = FXService(modelContext: ctx)

        // "date,rate\n2027-02-03,1380\n" 를 CP949 로 (ASCII 라 바이트는 같지만 한글 헤더를 섞는다)
        let text = "날짜,환율\n2027-02-03,1380\n"
        let cp949 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
        )
        let data = try XCTUnwrap(text.data(using: cp949))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rates-\(UUID().uuidString).csv")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let n = try fx.importRatesCSV(url: url, project: project)
        XCTAssertEqual(n, 1, "국내 인코딩 환율표를 읽지 못했다")
        XCTAssertEqual(fx.ratesMap(for: project)["2027-02-03"], 1380)
    }

    /// 날짜로 볼 수 없는 줄은 **가져온 것으로 세면 안 된다** (「N일 가져왔습니다」가 거짓말이 된다)
    func testUnparseableDatesAreNotCounted() throws {
        let (ctx, project) = try makeProject()
        let fx = FXService(modelContext: ctx)

        let csv = """
        date,rate
        2027-01-08,1700
        not-a-date,1800
        """
        let n = try fx.importRatesCSV(text: csv, project: project)
        XCTAssertEqual(n, 1, "읽지 못한 줄까지 가져온 것으로 셌다")
        XCTAssertEqual(fx.ratesMap(for: project)["2027-01-08"], 1700)
    }
}
