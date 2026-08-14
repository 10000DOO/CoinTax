import XCTest
@testable import CoinTax

/// 실데이터로 파서 결과의 **건수만** 확인한다 (수치·주소는 절대 찍지 않는다).
/// 실파일이 없는 환경에서는 조용히 건너뛴다.
final class Audit7RealDataProbe: XCTestCase {

    func test_트레조_실파일이_뒤집히지_않는가() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/samples/raw/Trezor Safe7/26-08-12")
        guard let files = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            throw XCTSkip("실파일 없음")
        }
        let csvs = files.filter { $0.pathExtension == "csv" }
        try XCTSkipIf(csvs.isEmpty, "실파일 없음")

        for f in csvs {
            let name = String(f.lastPathComponent.split(separator: "_")[0])
            let r = try TrezorSuiteCSVParser().parse(url: f, projectID: ProjectID(), accountID: AccountID())
            let dep = r.events.filter { $0.type == .deposit }.count
            let wd = r.events.filter { $0.type == .withdrawal }.count
            print("### \(name): 입금 \(dep)건 / 출금 \(wd)건")

            // 원본에서 「받음」으로 찍힌 행 수는 파서가 만든 입금 건수 **이하**여야 한다.
            // 받은 것이 출금으로 뒤집히면 이 관계가 깨진다 (7차 감사 D-2).
            let text = try CSVUtil.readText(url: f)
            let recvRows = CSVUtil.parseLines(CSVUtil.stripBOM(text)).dropFirst()
                .filter { $0.count > 3 && $0[3].trimmingCharacters(in: .whitespaces).uppercased() == "RECV" }
                .count
            XCTAssertGreaterThanOrEqual(dep, recvRows,
                "\(name): 원본 RECV \(recvRows)행보다 입금이 적다 — 받은 것이 출금으로 뒤집혔다")

            // 이 원장을 엔진에 태웠을 때 「보유보다 많은 출금」이 나오면 안 된다
            let wallet = Account.defaults(for: .wallet, projectID: ProjectID())
            let evs = r.events.map { e -> LedgerEvent in var c = e; c.accountID = wallet.id; return c }
            let rep = try CostBasisEngine(policies: .v1Default, accountsByID: [wallet.id: wallet],
                                          fxRates: [:], marketPrices: [:]).replay(events: evs, links: [])
            let overdraw = rep.issues.filter { $0.id == "V-QTY-02" && $0.severity == "critical" }
            XCTAssertTrue(overdraw.isEmpty, "\(name): 보유보다 많은 출금 \(overdraw.count)건")
        }
    }
}
