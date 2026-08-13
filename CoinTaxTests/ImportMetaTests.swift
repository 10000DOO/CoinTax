import XCTest
import SwiftData
@testable import CoinTax

/// 파일에서 **읽지 못해 버린 행**이 가져오기 직후 말고도 남는가 (5차 감사).
///
/// 「대상 아닌 행」(선물 등 `ignoredCount`)과 「읽지 못해 버린 행」(`errors`)은 성격이 전혀 다르다.
/// 앞은 일부러 뺀 것이고, 뒤는 **거래가 통째로 빠졌다는 뜻**이다.
/// 빗썸 확인서는 표 열이 밀리거나 페이지 경계에 걸리면 그 행을 버린다 —
/// 버린 사실이 가져오기 화면의 한 줄로 끝나면, 그 뒤로는 아무 흔적 없이 세액이 계산된다.
@MainActor
final class ImportMetaTests: XCTestCase {

    private func makeProject() throws -> (ModelContext, ProjectEntity) {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = try ProjectService(modelContext: ctx).createProject(name: "meta")
        return (ctx, project)
    }

    /// 빗썸 확인서 텍스트 — 두 번째 거래의 날짜가 달력에 없는 날이라 읽지 못한다
    private let bithumbText = """
    2027-03-01 10:00:00 BTC 매수 0.01 50000000 500000 -500250 지정가 0.01
    2027-13-45 11:00:00 BTC 매수 0.02 50000000 1000000 -1000500 지정가 0.03
    2027-03-03 12:00:00 BTC 매도 0.01 60000000 600000 599700 지정가 0.02
    """

    func testUnreadableRowsAreCountedAndPersisted() throws {
        let (ctx, project) = try makeProject()
        let acc = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })
        let svc = ImportService(modelContext: ctx)

        let outcome = try svc.importText(
            bithumbText, fileName: "확인서.txt", project: project, account: acc,
            parser: BithumbCertificatePDFParser()
        )
        XCTAssertEqual(outcome.inserted, 2, "읽은 행만 들어가야 한다")
        XCTAssertEqual(outcome.parseResult.errors.count, 1, "못 읽은 행이 오류로 남아야 한다")

        // 가져오기 직후 말고도 남는가 — 저장된 파일 기록에서 다시 읽을 수 있어야 한다
        let file = try XCTUnwrap(project.sourceFiles.first { $0.id == outcome.sourceFileID })
        let meta = ImportService.importMeta(file.metaJSON)
        XCTAssertEqual(meta.unreadable, 1, "읽지 못한 행 수가 파일 기록에 안 남았다 — 화면에서 다시 볼 방법이 없다")
        XCTAssertEqual(meta.excluded, 0, "「대상 아닌 행」과 섞이면 안 된다")
    }

    /// 멀쩡한 파일에서는 0 (오탐 방지)
    func testCleanFileHasNoUnreadableRows() throws {
        let (ctx, project) = try makeProject()
        let acc = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })
        let svc = ImportService(modelContext: ctx)

        let clean = """
        2027-03-01 10:00:00 BTC 매수 0.01 50000000 500000 -500250 지정가 0.01
        2027-03-03 12:00:00 BTC 매도 0.01 60000000 600000 599700 지정가 0
        """
        let outcome = try svc.importText(clean, fileName: "확인서2.txt", project: project, account: acc,
                                         parser: BithumbCertificatePDFParser())
        let file = try XCTUnwrap(project.sourceFiles.first { $0.id == outcome.sourceFileID })
        XCTAssertEqual(ImportService.importMeta(file.metaJSON).unreadable, 0)
    }

    /// 「대상 아닌 행」은 따로 센다 (OKX 미지원 Type)
    func testExcludedRowsAreCountedSeparately() throws {
        let (ctx, project) = try makeProject()
        let acc = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "okx" })
        let svc = ImportService(modelContext: ctx)

        let csv = """
        UID:000,Account Type:Main,Time Zone:UTC+0
        id,Time,Type,Amount,Before Balance,After Balance,Symbol
        1,2027-06-01 09:00:00,Deposit,100,0,100,USDT
        2,2027-06-02 09:00:00,금리수취,5,100,105,USDT
        """
        let outcome = try svc.importText(csv, fileName: "OKX Funding History.csv", project: project, account: acc)
        let file = try XCTUnwrap(project.sourceFiles.first { $0.id == outcome.sourceFileID })
        let meta = ImportService.importMeta(file.metaJSON)
        XCTAssertEqual(meta.excluded, 1)
        XCTAssertEqual(meta.unreadable, 0)
    }
}
