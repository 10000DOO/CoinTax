import XCTest
import SwiftData
@testable import CoinTax

/// **같은 거래ID가 다른 수량으로 다시 들어왔을 때** 사용자가 알 수 있는가 (5차 감사).
///
/// 기간이 겹치는 export 를 다시 가져오면 같은 거래가 또 들어온다. 내용이 똑같으면 건너뛰는 게 맞다.
/// 그런데 **같은 거래ID인데 수량이 다르면** 이야기가 다르다 — 한쪽 파일이 그 주문의 일부만
/// 담고 있다는 뜻이고, 앱이 어느 쪽을 들고 있는지에 따라 취득가액·양도가액이 달라진다.
/// 조용히 건너뛰면 사용자는 **어느 숫자로 신고하는지 모른 채** 넘어간다.
@MainActor
final class SameTradeIDDivergenceTests: XCTestCase {

    private func makeProject() throws -> (ModelContext, ProjectEntity) {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let project = try ProjectService(modelContext: ctx).createProject(name: "divergence")
        return (ctx, project)
    }

    /// OKX Trading History — `Order id` 가 그대로 거래ID(`externalID`)가 된다.
    private func okxTrading(orderID: String, amount: String, balanceChange: String) -> String {
        """
        UID:000,Account Type:Main,Time Zone:UTC+0
        id,Order id,Time,Trade Type,Symbol,Action,Amount,Trading Unit,Filled Price,PnL,Fee,Fee Unit,Position Change,Position Balance,Balance Change,Balance,Balance Unit
        90000000000000000001,\(orderID),2027-06-02 12:00:00,Spot,BTC-USDT,Buy,\(amount),BTC,50000,0,0,USDT,0,0,\(balanceChange),\(balanceChange),BTC
        90000000000000000002,\(orderID),2027-06-02 12:00:00,Spot,BTC-USDT,Sell,500,USDT,50000,0,0,USDT,0,0,-500,1000,USDT
        """
    }

    func testSameOrderIDWithDifferentQuantityIsReported() throws {
        let (ctx, project) = try makeProject()
        let acc = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "okx" })
        let svc = ImportService(modelContext: ctx)

        // 1차: 그 주문이 0.01 만 체결된 상태로 잘린 export
        let first = try svc.importText(
            okxTrading(orderID: "ord-1", amount: "0.01", balanceChange: "0.01"),
            fileName: "OKX Trading History (1).csv", project: project, account: acc
        )
        XCTAssertEqual(first.inserted, 1)

        // 2차: 같은 주문이 0.05 로 다 체결된 export
        let second = try svc.importText(
            okxTrading(orderID: "ord-1", amount: "0.05", balanceChange: "0.05"),
            fileName: "OKX Trading History (2).csv", project: project, account: acc
        )

        // 같은 거래를 두 번 세면 안 된다 — 그건 맞다
        XCTAssertEqual(second.inserted, 0, "같은 거래ID를 두 번 담으면 수량이 두 배가 된다")

        // 다만 **수량이 다르다는 사실**은 반드시 알려야 한다.
        let told = second.parseResult.warnings.contains { $0.contains("ord-1") }
        XCTAssertTrue(
            told,
            """
            같은 거래ID가 다른 수량으로 들어왔는데 알리지 않았다.
            받은 안내: \(second.parseResult.warnings)
            """
        )
    }

    /// 내용까지 완전히 같은 재-import 는 **조용히** 건너뛰는 게 맞다 (오탐 방지)
    func testIdenticalReimportStaysQuiet() throws {
        let (ctx, project) = try makeProject()
        let acc = try XCTUnwrap(project.accounts.first { $0.exchangeCode == "okx" })
        let svc = ImportService(modelContext: ctx)

        let csv = okxTrading(orderID: "ord-2", amount: "0.01", balanceChange: "0.01")
        _ = try svc.importText(csv, fileName: "OKX Trading History (a).csv", project: project, account: acc)
        // 바이트가 똑같으면 **파일 해시**에서 먼저 걸린다. 거래 내용은 같고 파일만 다른 상황을 만든다.
        let again = try svc.importText(csv + "\n", fileName: "OKX Trading History (b).csv", project: project, account: acc)

        XCTAssertEqual(again.inserted, 0)
        XCTAssertFalse(
            again.parseResult.warnings.contains { $0.contains("다른 수량") },
            "내용이 같은데 「다른 수량」으로 잘못 알렸다: \(again.parseResult.warnings)"
        )
    }
}
