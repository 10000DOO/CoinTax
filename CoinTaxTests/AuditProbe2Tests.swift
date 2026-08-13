import XCTest
import SwiftData
@testable import CoinTax

/// 감사 탐침 2차 — 저장·복원 · 다년도 · 개인지갑 · 극단값 · export 잠금.
final class AuditProbe2Tests: XCTestCase {

    private func replay(
        _ events: [LedgerEvent], accounts: [Account], links: [TransferLink] = [],
        fx: [String: Decimal] = [:], market: [String: Decimal] = [:]
    ) throws -> ReplayResult {
        try CostBasisEngine(
            policies: .v1Default,
            accountsByID: Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            fxRates: fx, marketPrices: market
        ).replay(events: events, links: links)
    }

    private func summarize(_ r: ReplayResult, _ pid: ProjectID, _ year: Int) -> TaxYearSummary {
        TaxAggregator.aggregate(
            projectID: pid, disposals: r.disposals, taxYear: year,
            extraDeductible: r.extraDeductibleByYear[year] ?? 0,
            abandonedTransferCostKRW: r.abandonedByYear[year] ?? 0,
            deemed: r.deemedPositions, policies: .v1Default
        )
    }

    // MARK: - V4 저장·복원

    /// 숫자를 문자열로 저장했다가 되읽을 때 한 자리도 잃으면 안 된다.
    @MainActor
    func testProbe_V4_decimalRoundTripThroughStore() throws {
        let container = try CoinTaxModelContainer.make(inMemory: true)
        let ctx = ModelContext(container)
        let ps = ProjectService(modelContext: ctx)
        let project = try ps.createProject(name: "roundtrip")
        let acc = try XCTUnwrap(project.accounts.first)

        let samples: [Decimal] = [
            Decimal(string: "0.000000000000000001")!,
            Decimal(string: "123456789012345678.87654321")!,
            Decimal(string: "0.00000001")!,
            Decimal(string: "-0.30000003")!,
            Decimal(string: "99999999999999999999999999999")!,
            0
        ]
        for (i, v) in samples.enumerated() {
            var e = LedgerEvent(
                projectID: ProjectID(project.id), accountID: AccountID(acc.id),
                timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2),
                type: .buy, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
                quantity: v, quoteAmountKRW: v, feeAmount: v, feeAsset: AssetSymbol("KRW"),
                sourceKind: "probe", rawRef: "r\(i)",
                balanceAfter: v, quoteBalanceAfter: v
            )
            e.fingerprint = "fp\(i)"
            let entity = EntityMappers.makeEntity(from: e)
            entity.project = project
            project.events.append(entity)
            ctx.insert(entity)
        }
        try ctx.save()

        for (i, v) in samples.enumerated() {
            let entity = try XCTUnwrap(project.events.first { $0.rawRef == "r\(i)" })
            let back = EntityMappers.event(entity, projectID: ProjectID(project.id))
            XCTAssertEqual(back.quantity, v, "수량 왕복 손실 (\(Money.decimalString(v)))")
            XCTAssertEqual(back.quoteAmountKRW, v, "금액 왕복 손실")
            XCTAssertEqual(back.balanceAfter, v, "잔고 왕복 손실")
        }
    }

    /// 계산 스냅샷은 JSON 으로 저장된다 — 되읽었을 때 세액이 같아야 한다.
    func testProbe_V4_summaryJSONRoundTrip() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        let deposit = LedgerEvent(projectID: pid, accountID: acc.id,
                                  timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2),
                                  type: .deposit, baseAsset: AssetSymbol("USDT"), quantity: 10_000,
                                  sourceKind: "p", rawRef: "s0")
        let buy = LedgerEvent(projectID: pid, accountID: acc.id,
                              timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 3),
                              type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
                              quantity: 1, quoteAmount: 1_000, sourceKind: "p", rawRef: "s1")
        let sell = LedgerEvent(projectID: pid, accountID: acc.id,
                               timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 3),
                               type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("USDT"),
                               quantity: -1, quoteAmount: 9_999, sourceKind: "p", rawRef: "s2")
        let fx = ["2027-01-02": Decimal(string: "1383.7")!, "2027-01-03": Decimal(string: "1383.7")!,
                  "2027-02-03": Decimal(string: "1391.3")!]
        let r = try replay([deposit, buy, sell], accounts: [acc], fx: fx)
        let s = summarize(r, pid, 2027)

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(TaxYearSummary.self, from: data)
        XCTAssertEqual(back.netIncomeKRW, s.netIncomeKRW, "JSON 왕복에서 소득금액이 달라졌다")
        XCTAssertEqual(back.totalTaxKRW, s.totalTaxKRW)
        XCTAssertEqual(back.totalProceedsKRW, s.totalProceedsKRW)
        XCTAssertEqual(back.disposals.map(\.pnlKRW), s.disposals.map(\.pnlKRW))
    }

    /// 저장소를 닫았다 다시 열어도 값이 남아 있어야 한다 (디스크 경로).
    @MainActor
    func testProbe_V4_reopenOnDiskStore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cointax-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.sqlite")
        let schema = Schema([ProjectEntity.self, AccountEntity.self, SourceFileEntity.self,
                             LedgerEventEntity.self, TransferLinkEntity.self, FXRateEntity.self,
                             MarketPriceEntity.self, SnapshotEntity.self])

        let qty = Decimal(string: "0.123456789012345678")!
        do {
            let c = try ModelContainer(for: schema, configurations: [ModelConfiguration(url: storeURL)])
            let ctx = ModelContext(c)
            let p = try ProjectService(modelContext: ctx).createProject(name: "disk")
            let acc = try XCTUnwrap(p.accounts.first)
            var e = LedgerEvent(projectID: ProjectID(p.id), accountID: AccountID(acc.id),
                                timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2),
                                type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                                quantity: qty, quoteAmountKRW: 1_000, sourceKind: "p", rawRef: "s1",
                                balanceAfter: qty)
            e.fingerprint = "fp-disk"
            let entity = EntityMappers.makeEntity(from: e)
            entity.project = p
            p.events.append(entity)
            ctx.insert(entity)
            try ctx.save()
        }
        let c2 = try ModelContainer(for: schema, configurations: [ModelConfiguration(url: storeURL)])
        let ctx2 = ModelContext(c2)
        let projects = try ctx2.fetch(FetchDescriptor<ProjectEntity>())
        let p2 = try XCTUnwrap(projects.first)
        let e2 = try XCTUnwrap(p2.events.first)
        let back = EntityMappers.event(e2, projectID: ProjectID(p2.id))
        XCTAssertEqual(back.quantity, qty, "재실행 후 수량이 달라졌다")
        XCTAssertEqual(back.balanceAfter, qty)
        XCTAssertEqual(back.lostForever, false)
    }

    // MARK: - 다년도 · 손실만 난 해

    /// 2027 손실 · 2028 이익 — 손실이 다음 해로 넘어가면 안 된다 (03-tax-rules §1: 이월공제 없음)
    func testProbe_multiYearNoLossCarryForward() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .bithumb, projectID: pid)
        func buy(_ m: Int, _ y: Int, _ qty: Decimal, _ krw: Decimal, _ ref: String) -> LedgerEvent {
            LedgerEvent(projectID: pid, accountID: acc.id, timestamp: TaxTime.dateKST(year: y, month: m, day: 1),
                        type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                        quantity: qty, quoteAmountKRW: krw, sourceKind: "p", rawRef: ref)
        }
        func sell(_ m: Int, _ y: Int, _ qty: Decimal, _ krw: Decimal, _ ref: String) -> LedgerEvent {
            LedgerEvent(projectID: pid, accountID: acc.id, timestamp: TaxTime.dateKST(year: y, month: m, day: 2),
                        type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                        quantity: -qty, quoteAmountKRW: krw, sourceKind: "p", rawRef: ref)
        }
        // 2027: 1억에 사서 5천만에 판다 → −5천만
        // 2028: 5천만에 사서 1억에 판다 → +5천만
        let events = [buy(1, 2027, 1, 100_000_000, "a"), sell(2, 2027, 1, 50_000_000, "b"),
                      buy(1, 2028, 1, 50_000_000, "c"), sell(2, 2028, 1, 100_000_000, "d")]
        let r = try replay(events, accounts: [acc])
        let s27 = summarize(r, pid, 2027)
        let s28 = summarize(r, pid, 2028)
        print("PROBE 다년도: 2027 소득=\(Money.decimalString(s27.netIncomeKRW)) 세액=\(Money.decimalString(s27.totalTaxKRW)) / 2028 소득=\(Money.decimalString(s28.netIncomeKRW)) 세액=\(Money.decimalString(s28.totalTaxKRW))")
        XCTAssertEqual(s27.netIncomeKRW, -50_000_000)
        XCTAssertEqual(s27.totalTaxKRW, 0, "손실만 난 해는 세액 0")
        XCTAssertEqual(s28.netIncomeKRW, 50_000_000, "전 해 손실이 넘어오면 안 된다")
        XCTAssertEqual(s28.taxBaseKRW, 47_500_000)
        XCTAssertEqual(s28.totalTaxKRW, 9_500_000 + 950_000)
        XCTAssertEqual(s27.disposals.count, 1, "다른 해 처분이 섞이면 안 된다")
        XCTAssertEqual(s28.disposals.count, 1)
    }

    // MARK: - 개인지갑이 과세 시작을 걸칠 때

    /// 2026 에 거래소 → 개인지갑, 2027 에 지갑 → 거래소, 그 뒤 매도.
    /// 지갑에 있던 수량도 의제취득가를 받아야 한다.
    func testProbe_walletAcrossTaxStart() throws {
        let pid = ProjectID()
        let bithumb = Account.defaults(for: .bithumb, projectID: pid)
        var wallet = Account.defaults(for: .wallet, projectID: pid)
        wallet.costMethod = .fifo

        let buy = LedgerEvent(projectID: pid, accountID: bithumb.id,
                              timestamp: TaxTime.dateKST(year: 2026, month: 5, day: 1),
                              type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                              quantity: 1, quoteAmountKRW: 40_000_000, sourceKind: "p", rawRef: "s1")
        let out = LedgerEvent(projectID: pid, accountID: bithumb.id,
                              timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
                              type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
                              sourceKind: "p", rawRef: "s2")
        let into = LedgerEvent(projectID: pid, accountID: wallet.id,
                               timestamp: TaxTime.dateKST(year: 2026, month: 6, day: 1),
                               type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
                               sourceKind: MatchingService.walletSourceKind, rawRef: "wallet:1")
        let back = LedgerEvent(projectID: pid, accountID: wallet.id,
                               timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
                               type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
                               sourceKind: MatchingService.walletSourceKind, rawRef: "wallet-out:2")
        let arrive = LedgerEvent(projectID: pid, accountID: bithumb.id,
                                 timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1),
                                 type: .deposit, baseAsset: AssetSymbol("BTC"), quantity: 1,
                                 sourceKind: "p", rawRef: "s3")
        let sell = LedgerEvent(projectID: pid, accountID: bithumb.id,
                               timestamp: TaxTime.dateKST(year: 2027, month: 3, day: 1),
                               type: .sell, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
                               quantity: -1, quoteAmountKRW: 90_000_000, sourceKind: "p", rawRef: "s4")
        let links = [
            TransferLink(id: LinkID(), projectID: pid, fromEventID: out.id, toEventID: into.id,
                         status: .confirmed, withdrawnQty: 1, receivedQty: 1),
            TransferLink(id: LinkID(), projectID: pid, fromEventID: back.id, toEventID: arrive.id,
                         status: .confirmed, withdrawnQty: 1, receivedQty: 1)
        ]
        let r = try replay([buy, out, into, back, arrive, sell], accounts: [bithumb, wallet],
                           links: links, market: ["BTC": 60_000_000])
        let dem = r.deemedPositions.first { $0.asset.code == "BTC" }
        let d = r.disposals.first { $0.timestamp >= TaxTime.taxStartDate }
        print("PROBE 지갑: 의제 \(dem.map { "\(Money.decimalString($0.deemedUnitKRW)) (\($0.reason))" } ?? "없음") · 처분원가 \(d.map { Money.decimalString($0.costKRW) } ?? "없음")")
        XCTAssertEqual(dem?.deemedUnitKRW, 60_000_000, "지갑에 있던 코인도 의제취득가를 받아야 한다")
        XCTAssertEqual(d?.costKRW, 60_000_000, "지갑을 거쳐 돌아온 코인의 취득가는 의제취득가")
        XCTAssertEqual(d?.pnlKRW, 30_000_000)
    }

    // MARK: - 극단값

    /// 소수 18자리 수량으로도 원장이 닫혀야 한다 (ETH 계열 토큰은 18자리다)
    func testProbe_eighteenDecimalQuantities() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        let q = Decimal(string: "0.123456789012345678")!
        let buy = LedgerEvent(projectID: pid, accountID: acc.id,
                              timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2),
                              type: .buy, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
                              quantity: q, quoteAmountKRW: 1_000_000, sourceKind: "p", rawRef: "s1")
        let sell = LedgerEvent(projectID: pid, accountID: acc.id,
                               timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 2),
                               type: .sell, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
                               quantity: -q, quoteAmountKRW: 2_000_000, sourceKind: "p", rawRef: "s2")
        let r = try replay([buy, sell], accounts: [acc])
        let s = summarize(r, pid, 2027)
        let report = Verifier.verify(VerifierInput(summary: s, replay: r, policies: .v1Default,
                                                   events: [buy, sell], summaryRerun: s))
        let crit = report.issues.filter { $0.severity == "critical" }
        print("PROBE 18자리: 소득=\(Money.decimalString(s.netIncomeKRW)) critical=\(crit.map(\.id))")
        XCTAssertEqual(s.netIncomeKRW, 1_000_000)
        XCTAssertTrue(crit.isEmpty, crit.map(\.message).joined(separator: " / "))
        XCTAssertTrue(r.holdings.rows.isEmpty, "전량 처분 후 잔량이 남으면 안 된다")
    }

    /// 수량 0 인 거래가 섞여도 계산이 깨지면 안 된다
    func testProbe_zeroQuantityEvents() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        let zeroBuy = LedgerEvent(projectID: pid, accountID: acc.id,
                                  timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 2),
                                  type: .buy, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
                                  quantity: 0, quoteAmountKRW: 0, sourceKind: "p", rawRef: "s1")
        let zeroSell = LedgerEvent(projectID: pid, accountID: acc.id,
                                   timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 3),
                                   type: .sell, baseAsset: AssetSymbol("XYZ"), quoteAsset: AssetSymbol("KRW"),
                                   quantity: 0, quoteAmountKRW: 0, sourceKind: "p", rawRef: "s2")
        let r = try replay([zeroBuy, zeroSell], accounts: [acc])
        let s = summarize(r, pid, 2027)
        let report = Verifier.verify(VerifierInput(summary: s, replay: r, policies: .v1Default,
                                                   events: [zeroBuy, zeroSell], summaryRerun: s))
        let crit = report.issues.filter { $0.severity == "critical" }
        print("PROBE 수량0: 처분 \(s.disposals.count)건 · critical=\(crit.map { "\($0.id):\($0.message)" })")
        XCTAssertTrue(crit.isEmpty, "수량 0 거래로 Critical 이 나면 안 된다")
    }

    // MARK: - export 잠금

    func testProbe_exportLockedWhenCritical() throws {
        var s = TaxYearSummary(
            projectID: ProjectID(), taxYear: 2027, status: .blocked, policyBundleID: "cointax-v2.0",
            totalProceedsKRW: 0, totalCostsKRW: 0, netIncomeKRW: 0, basicDeductionKRW: 2_500_000,
            taxBaseKRW: 0, nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
            abandonedTransferCostKRW: 0, disposals: [], deemed: [],
            disclaimers: TaxCopy.all, calculatedAt: Date(), verification: nil
        )
        s.verification = VerificationReport(runID: UUID(), status: "failed", issues: [], calculatedAt: Date())
        XCTAssertThrowsError(try ReportCSVExporter.exportCSV(s), "Critical 인데 CSV 가 나갔다")
        XCTAssertThrowsError(try ReportPDFExporter.exportPDF(s), "Critical 인데 PDF 가 나갔다")

        s.verification = nil
        XCTAssertThrowsError(try ReportCSVExporter.exportCSV(s), "검증 전인데 CSV 가 나갔다")
    }

    /// 고지 4종·주의사항·세무확인 항목이 PDF 에 전부 실려야 한다
    func testProbe_pdfContainsAllRequiredNotices() throws {
        var s = TaxYearSummary(
            projectID: ProjectID(), taxYear: 2027, status: .draft, policyBundleID: "cointax-v2.0",
            totalProceedsKRW: 1_000, totalCostsKRW: 500, netIncomeKRW: 500, basicDeductionKRW: 2_500_000,
            taxBaseKRW: 0, nationalTaxKRW: 0, localTaxKRW: 0, totalTaxKRW: 0,
            abandonedTransferCostKRW: 0, disposals: [], deemed: [],
            disclaimers: TaxCopy.all, calculatedAt: Date(), verification: nil
        )
        s.verification = VerificationReport(runID: UUID(), status: "passed", issues: [], calculatedAt: Date())
        let data = try ReportPDFExporter.exportPDF(s)
        let text = PDFTextProbe.text(data)
        var missing: [String] = []
        for d in TaxCopy.all where !PDFTextProbe.contains(text, d) { missing.append("고지: " + String(d.prefix(20))) }
        for n in TaxCopy.notices where !PDFTextProbe.contains(text, n) { missing.append("주의: " + String(n.prefix(20))) }
        for q in TaxOpenQuestions.all where !PDFTextProbe.contains(text, q.id) { missing.append("세무확인 " + q.id) }
        print("PROBE PDF: 페이지 텍스트 \(text.count)자 · 누락 \(missing.count)건")
        XCTAssertTrue(missing.isEmpty, "PDF 에서 빠진 항목: " + missing.joined(separator: ", "))
    }
}

import PDFKit

private enum PDFTextProbe {
    static func text(_ data: Data) -> String {
        guard let doc = PDFDocument(data: data) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount { out += doc.page(at: i)?.string ?? "" }
        return out
    }
    /// PDF 는 줄바꿈으로 쪼개지므로 공백·개행을 지우고 비교한다
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        func flat(_ s: String) -> String {
            s.components(separatedBy: .whitespacesAndNewlines).joined()
        }
        return flat(haystack).contains(flat(needle))
    }
}

