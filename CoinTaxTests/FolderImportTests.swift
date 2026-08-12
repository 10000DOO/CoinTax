import XCTest
@testable import CoinTax

/// 폴더를 통째로 넣을 때 하위 파일이 빠지거나 엉뚱한 파일이 딸려 들어가지 않는지.
final class FolderImportTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderImportTests-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("거래내역/바이낸스", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["a.csv", ".DS_Store", "note.json", "b.XLSX", "확인서.pdf"] {
            try Data().write(to: nested.appendingPathComponent(name))
        }
        try Data().write(to: root.appendingPathComponent("top.csv"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFolderExpandsRecursivelyAndFiltersNoise() {
        let names = ImportService.expandToImportableFiles(root).map { $0.lastPathComponent }
        XCTAssertEqual(Set(names), ["a.csv", "b.XLSX", "확인서.pdf", "top.csv"])
    }

    func testSingleFilePassesThrough() {
        let file = root.appendingPathComponent("top.csv")
        XCTAssertEqual(ImportService.expandToImportableFiles(file), [file])
    }

    /// 넣을 게 하나도 없는 폴더는 빈 배열 — 화면이 "넣을 파일이 없습니다"를 띄우는 근거.
    func testEmptyFolderYieldsNothing() throws {
        let empty = root.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("balances.json"))
        XCTAssertTrue(ImportService.expandToImportableFiles(empty).isEmpty)
    }
}
