import XCTest
import SwiftData
@testable import CoinTax

final class FXClientTests: XCTestCase {
    func testAutoFetchDefaultOn() {
        UserDefaults.standard.removeObject(forKey: "fx.autoFetchEnabled")
        XCTAssertTrue(FXPreferences.autoFetchEnabled)
    }

    @MainActor
    func testManualPreservedWhenAutoFill() async throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = ProjectEntity(name: "fx-test", defaultTaxYear: 2027)
        ctx.insert(project)
        let fx = FXService(modelContext: ctx, remoteClient: FixedFXClient(rates: [
            "2027-06-01": 1400,
            "2027-06-02": 1410
        ]))
        fx.autoFetchEnabled = true
        try fx.setRate(day: "2027-06-01", rate: 9999, project: project, source: "manual")
        let filled = try await fx.fillMissingFromRemote(
            days: ["2027-06-01", "2027-06-02"],
            project: project
        )
        XCTAssertEqual(filled["2027-06-02"], 1410)
        XCTAssertNil(filled["2027-06-01"], "manual day should not be in filled map as overwritten")
        let rates = fx.ratesMap(for: project)
        XCTAssertEqual(rates["2027-06-01"], 9999)
        XCTAssertEqual(rates["2027-06-02"], 1410)
    }

    @MainActor
    func testAutoOffSkipsRemote() async throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = ProjectEntity(name: "fx-off", defaultTaxYear: 2027)
        ctx.insert(project)
        let fx = FXService(modelContext: ctx, remoteClient: FixedFXClient(rates: ["2027-01-01": 1300]))
        fx.autoFetchEnabled = false
        let filled = try await fx.fillMissingFromRemote(days: ["2027-01-01"], project: project)
        XCTAssertTrue(filled.isEmpty)
        let forced = try await fx.fillMissingFromRemote(days: ["2027-01-01"], project: project, force: true)
        XCTAssertEqual(forced["2027-01-01"], 1300)
    }
}

private struct FixedFXClient: FXClient {
    let rates: [String: Decimal]
    func fetchUSD_KRW(days: [String]) async throws -> [String: Decimal] {
        Dictionary(uniqueKeysWithValues: days.compactMap { d in rates[d].map { (d, $0) } })
    }
}
