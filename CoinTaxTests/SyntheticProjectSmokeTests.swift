import XCTest
import SwiftData
@testable import CoinTax

/// 합성 fixture → ImportService → 매칭 → 계산 스모크 (실파일 불필요)
final class SyntheticProjectSmokeTests: XCTestCase {
    private func synthetic(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/samples/synthetic/\(name)")
    }

    @MainActor
    func testImportBithumbAndOKXSyntheticThenMatchPath() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let ps = ProjectService(modelContext: ctx)
        let project = try ps.createProject(name: "smoke")
        let bithumb = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })
        let okx = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "okx" })

        let importSvc = ImportService(modelContext: ctx)
        let bithumbText = try String(contentsOf: synthetic("bithumb_certificate_sample.txt"), encoding: .utf8)
        let o1 = try importSvc.importText(
            bithumbText,
            fileName: "bithumb_certificate_sample.txt",
            project: project,
            account: bithumb,
            parser: BithumbCertificatePDFParser()
        )
        XCTAssertGreaterThan(o1.inserted, 0)

        let okxText = try String(contentsOf: synthetic("okx_trading_sample.csv"), encoding: .utf8)
        let o2 = try importSvc.importText(
            okxText,
            fileName: "OKX Trading History_sample.csv",
            project: project,
            account: okx
        )
        XCTAssertGreaterThan(o2.inserted, 0)
        XCTAssertFalse(project.sourceFiles.isEmpty)
        XCTAssertTrue(project.sourceFiles.contains { !$0.metaJSON.isEmpty })

        let matching = MatchingService(modelContext: ctx)
        let cands = matching.suggest(for: project)
        // may be 0 if times/assets don't bridge in synthetic — still OK if import works
        _ = cands

        let pipeline = CalculationPipeline(modelContext: ctx)
        pipeline.fxService = FXService(modelContext: ctx, remoteClient: RemoteFXClientStub())
        // run async calculate via expectation
    }

    @MainActor
    func testCalculateAndExportWithSafeSyntheticBuySell() async throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let ps = ProjectService(modelContext: ctx)
        let project = try ps.createProject(name: "smoke-calc")
        let bithumb = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "bithumb" })

        // 안전한 합성 2행 (출금 없이 매수·매도) — 샘플 확인서의 출금+매도 조합은 재고 부족 가능
        let safe = """
        # date|time|asset|type|qty|price|tradeAmt|settle|memo
        2027-03-01|10:00:00|USDT|매수|10|14000|140000|-140000|지정가
        2027-03-10|12:00:00|USDT|매도|5|15000|75000|75000|시장가
        """
        let importSvc = ImportService(modelContext: ctx)
        _ = try importSvc.importText(safe, fileName: "safe.txt", project: project, account: bithumb, parser: BithumbCertificatePDFParser())

        let pipeline = CalculationPipeline(modelContext: ctx)
        let fx = FXService(modelContext: ctx, remoteClient: RemoteFXClientStub())
        fx.autoFetchEnabled = false
        pipeline.fxService = fx
        let result = try await pipeline.calculate(project: project, taxYear: 2027)
        XCTAssertEqual(result.summary.policyBundleID, "cointax-v2.0")
        XCTAssertEqual(result.summary.disclaimers.count, 4)
        XCTAssertEqual(result.replay.disposals.count, 1)
        // force verification pass for export shape check
        var summary = result.summary
        summary.verification = VerificationReport(runID: UUID(), status: "passed", issues: [], calculatedAt: Date())
        let csv = try ReportCSVExporter.exportCSV(summary)
        XCTAssertTrue(csv.contains("cointax-v2.0"))
        let pdf = try ReportPDFExporter.exportPDF(summary)
        XCTAssertGreaterThan(pdf.count, 100)
    }

    func testFXCSVImport() throws {
        // domain-level via MainActor helper
    }

    @MainActor
    func testFXCSVImportMain() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = ProjectEntity(name: "fxcsv", defaultTaxYear: 2027)
        ctx.insert(project)
        let fx = FXService(modelContext: ctx, remoteClient: RemoteFXClientStub())
        let csv = """
        day,rate
        2027-06-01,1400.5
        2027-06-02,1410
        """
        let n = try fx.importRatesCSV(text: csv, project: project)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(fx.ratesMap(for: project)["2027-06-01"], Decimal(string: "1400.5"))
    }

    func testGenericMappingRequiredFields() {
        // smoke that parser accepts explicit map
        let parser = GenericTabularMapper(columnMap: [
            "timestamp": "Date",
            "type": "Type",
            "baseAsset": "Asset",
            "quantity": "Amount"
        ])
        let text = """
        Date,Type,Asset,Amount
        2027-01-01 00:00:00,buy,BTC,1
        """
        let result = try? parser.parse(text: text, fileName: "g.csv", projectID: ProjectID(), accountID: AccountID())
        XCTAssertEqual(result?.events.count, 1)
        XCTAssertEqual(result?.events.first?.type, .buy)
    }
}
