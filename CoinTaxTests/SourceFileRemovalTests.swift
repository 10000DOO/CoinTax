import XCTest
import SwiftData
@testable import CoinTax

/// 잘못 넣은 파일을 되돌린다.
///
/// 거래만 남기고 파일만 지우면 출처를 알 수 없고, 거래만 지우고 링크를 두면
/// 엔진이 「확정 링크의 출금 거래가 계산 대상에 없습니다」로 계산을 막는다.
@MainActor
final class SourceFileRemovalTests: XCTestCase {

    private var ctx: ModelContext!
    private var project: ProjectEntity!
    private var svc: ImportService!

    override func setUpWithError() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        ctx = ModelContext(container)
        project = try ProjectService(modelContext: ctx).createProject(name: "removal")
        svc = ImportService(modelContext: ctx)
    }

    private func addFile(_ name: String) -> SourceFileEntity {
        let f = SourceFileEntity(fileName: name, format: "csv", parserID: "t", sha256: UUID().uuidString)
        f.project = project
        project.sourceFiles.append(f)
        ctx.insert(f)
        return f
    }

    @discardableResult
    private func addEvent(_ file: SourceFileEntity?, type: EventType, asset: String, qty: String,
                          account: AccountEntity, sourceKind: String = "t") -> LedgerEventEntity {
        let e = LedgerEventEntity(accountID: account.id, fingerprint: UUID().uuidString,
                                  timestamp: TaxTime.dateKST(year: 2026, month: 3, day: 1),
                                  type: type.rawValue, baseAsset: asset, quantity: qty, sourceKind: sourceKind)
        e.sourceFileID = file?.id
        e.project = project
        project.events.append(e)
        ctx.insert(e)
        return e
    }

    // MARK: 기본

    func testRemovesFileAndItsEvents() throws {
        let acc = try XCTUnwrap(project.accounts.first)
        let a = addFile("a.csv")
        let b = addFile("b.csv")
        addEvent(a, type: .buy, asset: "BTC", qty: "1", account: acc)
        addEvent(a, type: .buy, asset: "BTC", qty: "2", account: acc)
        addEvent(b, type: .buy, asset: "ETH", qty: "3", account: acc)
        try ctx.save()

        let removed = try svc.deleteSourceFile(a, project: project)
        XCTAssertEqual(removed.events, 2)
        XCTAssertEqual(removed.links, 0)
        XCTAssertEqual(project.sourceFiles.map(\.fileName), ["b.csv"])
        // 다른 파일의 거래는 건드리지 않는다
        XCTAssertEqual(project.events.count, 1)
        XCTAssertEqual(project.events.first?.baseAsset, "ETH")
    }

    /// 링크를 남기면 엔진이 계산을 막는다.
    func testRemovesLinksThatTouchTheFile() throws {
        let bithumb = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let out = addFile("out.csv")
        let inn = addFile("in.csv")
        let w = addEvent(out, type: .withdrawal, asset: "USDT", qty: "-100", account: bithumb)
        let d = addEvent(inn, type: .deposit, asset: "USDT", qty: "99", account: binance)
        let link = TransferLinkEntity(fromEventID: w.id, toEventID: d.id,
                                      status: LinkStatus.confirmed.rawValue,
                                      withdrawnQty: "100", receivedQty: "99")
        link.project = project
        project.links.append(link)
        ctx.insert(link)
        try ctx.save()

        let removed = try svc.deleteSourceFile(out, project: project)
        XCTAssertEqual(removed.events, 1)
        XCTAssertEqual(removed.links, 1)
        XCTAssertTrue(project.links.isEmpty, "상대를 잃은 링크가 남으면 계산이 막힌다")
        // 상대편 입금은 거래소에서 온 실제 기록이므로 남는다
        XCTAssertEqual(project.events.count, 1)
        XCTAssertEqual(project.events.first?.id, d.id)
    }

    /// 개인지갑 입고는 링크 때문에 생긴 짝이다 — 출금을 지우면 같이 지워야 한다.
    /// 남기면 어디서 왔는지 없는 자산이 보유 현황에 떠돈다.
    func testRemovesWalletCounterpartEvent() throws {
        let binance = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "binance" })
        let file = addFile("withdraw.csv")
        let w = addEvent(file, type: .withdrawal, asset: "BTC", qty: "-0.5", account: binance)
        try ctx.save()
        let wallet = try MatchingService(modelContext: ctx).moveToWallet(withdrawal: w, project: project)
        XCTAssertEqual(wallet.sourceKind, MatchingService.walletSourceKind)
        XCTAssertEqual(project.events.count, 2)

        let removed = try svc.deleteSourceFile(file, project: project)
        XCTAssertEqual(removed.events, 2, "출금 + 지갑 입고")
        XCTAssertEqual(removed.links, 1)
        XCTAssertTrue(project.events.isEmpty)
        XCTAssertTrue(project.links.isEmpty)
    }

    /// 뺀 파일은 다시 넣을 수 있어야 한다 — sha256 중복 판정이 살아 있으면 영영 못 넣는다.
    func testRemovedFileCanBeImportedAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("okx_funding.csv")
        try """
        UID:000,Account Type:Main,Time Zone:UTC+9
        id,Time,Type,Amount,Before Balance,After Balance,Symbol
        1,2026-01-02 10:00:00,Deposit,200,0,200,USDT
        """.write(to: url, atomically: true, encoding: .utf8)

        let okx = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "okx" })
        let first = try svc.importFile(url: url, project: project, account: okx)
        XCTAssertEqual(first.inserted, 1)
        // 같은 파일을 두 번 넣는 것은 여전히 막혀야 한다
        XCTAssertThrowsError(try svc.importFile(url: url, project: project, account: okx))

        let file = try XCTUnwrap(project.sourceFiles.first { $0.id == first.sourceFileID })
        try svc.deleteSourceFile(file, project: project)
        XCTAssertTrue(project.events.isEmpty)

        let again = try svc.importFile(url: url, project: project, account: okx)
        XCTAssertEqual(again.inserted, 1, "뺀 파일은 다시 넣을 수 있어야 한다")
    }
}
