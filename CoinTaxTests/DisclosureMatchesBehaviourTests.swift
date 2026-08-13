import XCTest
@testable import CoinTax

/// 앱이 신고자료에 싣는 **고지 문구**가 실제 계산과 맞는가 (5차 감사).
///
/// 이 문구들은 화면뿐 아니라 CSV·PDF 에도 그대로 실려 세무사에게 간다.
/// 4차 감사(D4-3)와 5차 감사 회차 17 에서 **문구가 코드와 어긋난 자리**가 실제로 나왔으므로,
/// 말과 동작을 짝지어 고정한다.
final class DisclosureMatchesBehaviourTests: XCTestCase {

    private func replay(_ events: [LedgerEvent], _ account: Account) throws -> ReplayResult {
        try CostBasisEngine(policies: .v1Default, accountsByID: [account.id: account],
                            fxRates: [:], marketPrices: [:])
            .replay(events: events, links: [])
    }

    /// 「에어드롭·수수료 리베이트·연결되지 않은 입금은 취득가 0원으로 처리됩니다」
    /// — 세 갈래가 모두 실제로 0원인가.
    func testZeroCostAcquisitionNoticeMatchesEngine() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        func event(_ type: EventType, _ month: Int, _ ref: String) -> LedgerEvent {
            LedgerEvent(
                projectID: pid, accountID: acc.id,
                timestamp: TaxTime.dateKST(year: 2027, month: month, day: 1, hour: 10),
                type: type, baseAsset: AssetSymbol("BTC"), quantity: 1,
                sourceKind: "disclosure", rawRef: ref
            )
        }
        // 에어드롭·리베이트(income) 1개 + 연결되지 않은 입금(deposit) 1개 → 2개 보유, 원가 0
        let r = try replay([event(.income, 1, "r1"), event(.deposit, 2, "r2")], acc)
        let row = try XCTUnwrap(r.holdings.rows.first { $0.asset.code == "BTC" })
        XCTAssertEqual(row.quantity, 2)
        XCTAssertEqual(row.totalCostKRW, 0, "고지는 「취득가 0원」이라고 하는데 실제 원가가 0이 아니다")

        // 그리고 사용자가 그 사실을 알 수 있어야 한다
        XCTAssertTrue(r.issues.contains { $0.id == "V-COST-01" }, "에어드롭 취득가 0원을 알리지 않았다")
        XCTAssertTrue(r.issues.contains { $0.id == "V-QTY-04" }, "연결 안 된 입금 취득가 0원을 알리지 않았다")
        XCTAssertTrue(TaxCopy.zeroCostAcquisition.contains("0원"))
    }

    /// 「연결되지 않은 출금의 취득원가는 소멸 처리됩니다(세액이 커지는 방향)」
    func testUnmatchedWithdrawalNoticeMatchesEngine() throws {
        let pid = ProjectID()
        let acc = Account.defaults(for: .binance, projectID: pid)
        let buy = LedgerEvent(
            projectID: pid, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 1, day: 1, hour: 10),
            type: .buy, baseAsset: AssetSymbol("BTC"), quoteAsset: AssetSymbol("KRW"),
            quantity: 1, quoteAmountKRW: 50_000_000, sourceKind: "disclosure", rawRef: "r1"
        )
        let out = LedgerEvent(
            projectID: pid, accountID: acc.id,
            timestamp: TaxTime.dateKST(year: 2027, month: 2, day: 1, hour: 10),
            type: .withdrawal, baseAsset: AssetSymbol("BTC"), quantity: -1,
            sourceKind: "disclosure", rawRef: "r2"
        )
        let r = try replay([buy, out], acc)
        XCTAssertEqual(r.abandonedTotal, 50_000_000, "소멸 처리된 원가가 산 값과 다르다")
        XCTAssertTrue(r.holdings.rows.isEmpty)
        // 「세액이 커지는 방향」 — 소멸한 원가는 필요경비에 들어가면 안 된다
        XCTAssertEqual(r.extraDeductible, 0, "소멸 원가가 필요경비로 새어 들어갔다")
    }

    /// 「손실은 다음 해로 이월되지 않는다」 — 문구와 세율 정책이 같은 말을 하는가
    func testLossCarryForwardNoticeMatchesPolicy() {
        let p = KROtherIncomeTaxRatePolicy()
        let r = StatutoryKRWRoundingPolicy()
        XCTAssertEqual(p.compute(incomeKRW: -10_000_000, rounding: r).taxBaseKRW, 0)
        XCTAssertTrue(TaxCopy.lossNotCarriedForward.contains("이월"))
    }

    /// 「2027-01-01 시행 · 기본공제 250만 · 20%+2%」 — 문구의 숫자가 실제 파라미터와 같은가
    func testScheduleNoticeNumbersMatchPolicy() {
        let p = KROtherIncomeTaxRatePolicy()
        XCTAssertEqual(p.basicDeductionKRW, 2_500_000)
        XCTAssertEqual(p.nationalRate, Decimal(string: "0.20"))
        XCTAssertEqual(p.localRate, Decimal(string: "0.02"))
        XCTAssertEqual(TaxTime.taxStartYear, 2027)
        for token in ["2027-01-01", "250만", "20%", "2%"] {
            XCTAssertTrue(TaxCopy.scheduleMayChange.contains(token), "고지에 \(token) 이 없다")
        }
    }

    /// 원가법 고지가 **실제로 쓰이는 계정 종류**를 다 덮는가.
    ///
    /// 개인지갑은 앱이 버튼으로 만들어 주는 계정이고, 그 안에서 선입선출로 어느 매입 건이
    /// 먼저 나가는지가 **거래소로 되가져올 때 이전되는 취득원가를 바꾼다.**
    /// 예전 문구(「바이낸스·OKX 계정은」)는 그 계정을 빠뜨리고 있었다 — 사용자 승인으로 넓혔고
    /// 잠긴 고지라 정책 id 도 `v1.2` 로 올렸다.
    func testCostMethodDisclosureCoversEveryAccountType() {
        let pid = ProjectID()
        let resolver = VASPMAElseFIFOResolver()
        var uncovered: [String] = []
        for code in [ExchangeCode.bithumb, .binance, .okx, .generic, .wallet] {
            let acc = Account.defaults(for: code, projectID: pid)
            let method = resolver.method(for: acc)
            // 이름이 직접 적혀 있거나, 「그 밖의 계정」 같은 포괄 표현으로 덮여야 한다
            let named = TaxCopy.costMethods.contains(acc.displayName)
            let coveredByCatchAll = method == .fifo && TaxCopy.costMethods.contains("그 밖의 계정")
            if !named && !coveredByCatchAll { uncovered.append(acc.displayName) }
        }
        XCTAssertTrue(uncovered.isEmpty, "원가법 고지가 안 덮는 계정: \(uncovered.joined(separator: ", "))")
        XCTAssertTrue(TaxCopy.costMethods.contains("개인지갑"), "개인지갑은 이름을 직접 적어 둔다")
        XCTAssertTrue(TaxCopy.costMethods.contains("이동평균법") && TaxCopy.costMethods.contains("선입선출법"))
    }

    /// 잠긴 고지를 바꾸면 **정책 id 도 함께 올라가야** 과거 계산과 구분된다
    func testPolicyIDMovedWithTheDisclosure() {
        XCTAssertEqual(PolicyBundle.v1Default.id, "cointax-v1.2")
        XCTAssertEqual(PolicyBundle.v1Default.disclaimers.count, 4)
        XCTAssertTrue(PolicyBundle.v1Default.disclaimers.contains(TaxCopy.costMethods))
    }
}
