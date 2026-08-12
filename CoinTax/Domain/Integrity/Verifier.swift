import Foundation

struct VerifierInput: Sendable {
    var summary: TaxYearSummary
    var replay: ReplayResult
    var policies: PolicyBundle
    var events: [LedgerEvent]
    /// Second independent aggregate for V-RE-01
    var summaryRerun: TaxYearSummary?
    /// 확정된 전송 링크 (V-QTY-03)
    var links: [TransferLink] = []
    /// 실제 고시·수동 입력된 환율 (V-FX-02 출처 대조)
    var fxPublished: [String: Decimal] = [:]
}

enum Verifier {
    static func verify(_ input: VerifierInput) -> VerificationReport {
        var issues: [VerificationIssue] = []
        let s = input.summary
        let r = input.replay
        let p = input.policies

        // 엔진이 계산 중 수집한 문제를 그대로 승계 (예외로 죽이지 않고 여기로 모은다)
        issues.append(contentsOf: r.issues)

        // ── V-RE-01 결정성 ─────────────────────────────────────────────
        if let s2 = input.summaryRerun {
            if s.netIncomeKRW != s2.netIncomeKRW || s.totalTaxKRW != s2.totalTaxKRW {
                issues.append(.init(id: "V-RE-01", severity: "critical", message: "동일 입력 재계산 결과 불일치", context: nil))
            }
            if s.disposals.count != s2.disposals.count {
                issues.append(.init(id: "V-RE-01", severity: "critical", message: "재계산 시 처분 건수 불일치", context: nil))
            }
        }

        // ── V-RE-02 독립 재합산 ────────────────────────────────────────
        // 엔진이 기록한 pnl 을 믿지 않고 proceeds − cost − fees 로 다시 더한다.
        let recomputed = s.disposals.reduce(Decimal(0)) { acc, d in
            acc + (d.proceedsKRW - d.costKRW - d.feesKRW)
        }
        if Money.abs(recomputed - s.extraDeductibleKRW - s.netIncomeKRW) > 1 {
            issues.append(.init(
                id: "V-RE-02", severity: "critical",
                message: "독립 재합산 결과가 소득금액과 다릅니다",
                context: "재합산=\(Money.decimalString(recomputed)) 소득=\(Money.decimalString(s.netIncomeKRW))"
            ))
        }

        // ── V-COST-06 건별 손익 ────────────────────────────────────────
        for d in s.disposals {
            let expected = d.proceedsKRW - d.costKRW - d.feesKRW
            if Money.abs(expected - d.pnlKRW) > 1 {
                issues.append(.init(
                    id: "V-COST-06", severity: "critical",
                    message: "건별 손익이 양도−취득−비용과 다릅니다",
                    context: "\(d.asset.code) \(TaxTime.dayKST(d.timestamp))"
                ))
            }
        }

        // ── V-TAX-01 손익 합계 == 소득금액 ─────────────────────────────
        let pnlSum = s.disposals.reduce(Decimal(0)) { $0 + $1.pnlKRW } - s.extraDeductibleKRW
        if Money.abs(pnlSum - s.netIncomeKRW) > 1 {
            issues.append(.init(id: "V-TAX-01", severity: "critical", message: "손익 합계와 소득 불일치", context: "pnl=\(pnlSum) income=\(s.netIncomeKRW)"))
        }

        // ── V-TAX-02/03/04 세액 ────────────────────────────────────────
        let expectedBase = max(0, s.netIncomeKRW - s.basicDeductionKRW)
        if s.taxBaseKRW != expectedBase {
            issues.append(.init(id: "V-TAX-02", severity: "critical", message: "과세표준 불일치", context: nil))
        }
        let expectedNational = p.rounding.roundKRW(s.taxBaseKRW * p.taxRate.nationalRate)
        let expectedLocal = p.rounding.roundKRW(s.taxBaseKRW * p.taxRate.localRate)
        if s.nationalTaxKRW != expectedNational {
            issues.append(.init(id: "V-TAX-03", severity: "critical", message: "국세 세율 검증 실패", context: nil))
        }
        if s.localTaxKRW != expectedLocal {
            issues.append(.init(id: "V-TAX-04", severity: "critical", message: "지방세 세율 검증 실패", context: nil))
        }
        if s.totalTaxKRW != s.nationalTaxKRW + s.localTaxKRW {
            issues.append(.init(id: "V-TAX-03", severity: "critical", message: "세액 합계 불일치", context: nil))
        }

        // ── V-TAX-05 과세 시작일 이전 처분 배제 ────────────────────────
        let tTax = TaxTime.taxStartDate
        if let early = s.disposals.first(where: { $0.timestamp < tTax }) {
            issues.append(.init(
                id: "V-TAX-05", severity: "critical",
                message: "과세 시작일(2027-01-01 KST) 이전 처분이 과세 합계에 포함되었습니다",
                context: TaxTime.dayKST(early.timestamp)
            ))
        }
        if let wrongYear = s.disposals.first(where: { TaxTime.calendarYearKST($0.timestamp) != s.taxYear }) {
            issues.append(.init(
                id: "V-TAX-05", severity: "critical",
                message: "다른 과세연도 처분이 섞여 있습니다",
                context: TaxTime.dayKST(wrongYear.timestamp)
            ))
        }
        // 선택한 연도 밖에도 과세 처분이 있으면 알린다.
        // 리포트는 한 해만 보여주므로, 조용히 두면 **다른 해 신고를 빠뜨린다**.
        let otherYears = Dictionary(grouping: r.disposals.filter { $0.taxYear != s.taxYear }, by: \.taxYear)
            .map { (year: $0.key, count: $0.value.count) }
            .sorted { $0.year < $1.year }
        if !otherYears.isEmpty {
            let detail = otherYears.map { "\($0.year)년 \($0.count)건" }.joined(separator: ", ")
            issues.append(.init(
                id: "V-TAX-06", severity: "warning",
                message: "다른 과세연도에도 과세 대상 처분이 있습니다 — 해당 연도도 각각 계산·신고하세요 (\(detail))",
                context: detail
            ))
        }

        // ── V-QTY-01 이벤트 수량 합 == 보유 수량 ───────────────────────
        // 엔진 결과를 믿지 않고 이벤트만으로 계정×자산 수량을 다시 쌓는다.
        var expectedQty: [String: Decimal] = [:]
        func bump(_ acc: AccountID, _ asset: AssetSymbol, _ delta: Decimal) {
            guard !asset.isKRW else { return }
            let key = "\(acc.raw.uuidString)|\(asset.code)"
            expectedQty[key] = (expectedQty[key] ?? 0) + delta
        }
        for e in input.events where e.type != .ignored {
            let qty = Money.abs(e.quantity)
            switch e.type {
            case .buy:
                var net = qty
                if !e.quantityIsNetOfFee, let fa = e.feeAsset, fa == e.baseAsset, let fee = e.feeAmount {
                    net = max(0, qty - Money.abs(fee))
                }
                bump(e.accountID, e.baseAsset, net)
            case .deposit, .income:
                bump(e.accountID, e.baseAsset, qty)
            case .sell:
                bump(e.accountID, e.baseAsset, -qty)
            case .withdrawal:
                bump(e.accountID, e.baseAsset, -qty)
                if !e.quantityIsNetOfFee, let fee = e.feeAmount, fee > 0,
                   e.feeAsset == nil || e.feeAsset == e.baseAsset {
                    bump(e.accountID, e.baseAsset, -Money.abs(fee))
                }
            case .transferInternal, .fee, .fiatDeposit, .fiatWithdraw, .other, .ignored:
                break
            }
            // 코인↔코인 매매의 견적자산 leg — 매수는 나가고 매도는 들어온다
            if let quote = e.quoteAsset, let quoteQty = e.cryptoQuoteQuantity {
                bump(e.accountID, quote, e.type == .buy ? -quoteQty : quoteQty)
            }
            if let fa = e.feeAsset, let fee = e.feeAmount, fee != 0,
               feeReducesBook(e, feeAsset: fa) {
                bump(e.accountID, fa, -Money.abs(fee))
            }
        }
        var actualQty: [String: Decimal] = [:]
        for row in r.holdings.rows {
            guard let acc = row.accountID else { continue }
            actualQty["\(acc.raw.uuidString)|\(row.asset.code)"] = row.quantity
        }
        for (key, expected) in expectedQty {
            let actual = actualQty[key] ?? 0
            // 재고 부족으로 처분하지 못한 수량이 있으면 차이가 남는다 — 그건 이미 V-QTY-02로 보고됨.
            // **해당 자산만** 면제한다. 전체를 면제하면 다른 자산의 진짜 불일치를 놓친다.
            if Money.abs(expected - actual) > Money.qtyEpsilon, !r.shortfallKeys.contains(key) {
                issues.append(.init(
                    id: "V-QTY-01", severity: "critical",
                    message: "이벤트 수량 합과 보유 수량이 다릅니다 (기대 \(Money.decimalString(expected)) / 실제 \(Money.decimalString(actual)))",
                    context: key.split(separator: "|").last.map(String.init)
                ))
            }
        }

        // ── V-QTY-02 음수 재고 ─────────────────────────────────────────
        for row in r.holdings.rows where row.quantity < 0 {
            issues.append(.init(id: "V-QTY-02", severity: "critical", message: "음수 보유 수량", context: row.asset.code))
        }

        // ── V-QTY-03 확정 전송 수량 정합 ───────────────────────────────
        let eventsByID = Dictionary(input.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for link in input.links where link.status == .confirmed {
            guard let w = eventsByID[link.fromEventID], let d = eventsByID[link.toEventID] else {
                issues.append(.init(id: "V-QTY-03", severity: "critical", message: "확정 링크가 존재하지 않는 이벤트를 가리킵니다", context: link.id.raw.uuidString))
                continue
            }
            if w.baseAsset != d.baseAsset {
                issues.append(.init(id: "V-QTY-03", severity: "critical", message: "확정 링크의 자산이 다릅니다", context: "\(w.baseAsset.code)→\(d.baseAsset.code)"))
            }
            let wQty = Money.abs(w.quantity)
            let dQty = Money.abs(d.quantity)
            let lost = wQty - dQty
            let tolerance = max(wQty * Decimal(string: "0.01")!, w.feeAmount.map { Money.abs($0) } ?? 0, Decimal(string: "0.000001")!)
            if lost < -Money.qtyEpsilon {
                // 받은 양이 보낸 양보다 많다 — 잘못 연결했거나 자료가 틀렸다
                issues.append(.init(
                    id: "V-QTY-03", severity: "critical",
                    message: "확정 전송의 입금이 출금보다 많습니다 (\(Money.decimalString(-lost))) — 잘못 연결했을 수 있습니다",
                    context: w.baseAsset.code
                ))
            } else if lost > tolerance {
                // 소액 전송은 네트워크 수수료가 1%를 훌쩍 넘는다 (10 USDT 전송에 1 USDT = 10%).
                // 이건 정상 전송이므로 Critical 로 막으면 **신고자료 export 가 잠긴다.**
                // 매칭 화면도 같은 구간을 「확인 필요」 후보로 제시한다 — 판단은 사용자가 이미 했다.
                let ratio = wQty > 0 ? NSDecimalNumber(decimal: lost / wQty).doubleValue * 100 : 0
                issues.append(.init(
                    id: "V-QTY-03", severity: "warning",
                    message: String(format: "확정 전송에서 %.1f%% (%@ %@)가 사라졌습니다 — 네트워크 수수료가 맞는지 확인하세요 (그만큼 취득원가가 소멸합니다)", ratio, Money.decimalString(lost), w.baseAsset.code),
                    context: w.baseAsset.code
                ))
            }
        }

        // ── V-COST-02 전송 이전 원가 비율 ──────────────────────────────
        for d in r.transferCostDetails {
            let expected = d.outboundCostKRW * d.ratio
            if Money.abs(expected - d.transferredCostKRW) > 1 {
                issues.append(.init(id: "V-COST-02", severity: "critical", message: "전송 이전 원가 비율 불일치", context: d.linkID.raw.uuidString))
            }
        }

        // ── V-COST-03 소실 원가 미공제 ─────────────────────────────────
        if s.extraDeductibleKRW != 0 && p.transferCost.id == "abandon_lost_cost" {
            issues.append(.init(id: "V-COST-03", severity: "critical", message: "소실 원가가 필요경비에 포함됨", context: nil))
        }
        if Money.abs(s.abandonedTransferCostKRW - (r.abandonedByYear[s.taxYear] ?? 0)) > 1 {
            issues.append(.init(id: "V-COST-03", severity: "warning", message: "소실 원가 합계 불일치", context: nil))
        }
        for d in r.transferCostDetails where d.deductibleExpenseKRW != 0 && p.transferCost.id == "abandon_lost_cost" {
            issues.append(.init(id: "V-COST-03", severity: "critical", message: "전송 소실 필요경비 금지 위반", context: nil))
        }
        // 소실 원가가 필요경비 합계에 섞여 들어가지 않았는지 (총원가 = 취득 + 수수료 + 추가공제)
        let costFromDisposals = s.disposals.reduce(Decimal(0)) { $0 + $1.costKRW + $1.feesKRW } + s.extraDeductibleKRW
        if Money.abs(costFromDisposals - s.totalCostsKRW) > 1 {
            issues.append(.init(id: "V-COST-03", severity: "critical", message: "필요경비 합계가 건별 합과 다릅니다 (소실 원가 혼입 의심)", context: nil))
        }

        // ── V-DEM-01/02 의제 ───────────────────────────────────────────
        var preTaxQty: [String: Decimal] = [:]
        for e in input.events where e.type != .ignored && e.timestamp < tTax {
            let qty = Money.abs(e.quantity)
            guard !e.baseAsset.isKRW else { continue }
            let key = "\(e.accountID.raw.uuidString)|\(e.baseAsset.code)"
            switch e.type {
            case .buy:
                var net = qty
                if !e.quantityIsNetOfFee, let fa = e.feeAsset, fa == e.baseAsset, let fee = e.feeAmount {
                    net = max(0, qty - Money.abs(fee))
                }
                preTaxQty[key] = (preTaxQty[key] ?? 0) + net
            case .deposit, .income:
                preTaxQty[key] = (preTaxQty[key] ?? 0) + qty
            case .sell:
                preTaxQty[key] = (preTaxQty[key] ?? 0) - qty
            case .withdrawal:
                var outQty = qty
                if !e.quantityIsNetOfFee, let fee = e.feeAmount, fee > 0,
                   e.feeAsset == nil || e.feeAsset == e.baseAsset {
                    outQty += Money.abs(fee)
                }
                preTaxQty[key] = (preTaxQty[key] ?? 0) - outQty
            default:
                break
            }
            // 코인↔코인 매매의 견적자산 leg
            if let quote = e.quoteAsset, let quoteQty = e.cryptoQuoteQuantity {
                let quoteKey = "\(e.accountID.raw.uuidString)|\(quote.code)"
                preTaxQty[quoteKey] = (preTaxQty[quoteKey] ?? 0) + (e.type == .buy ? -quoteQty : quoteQty)
            }
            if let fa = e.feeAsset, let fee = e.feeAmount, fee != 0,
               feeReducesBook(e, feeAsset: fa) {
                let feeKey = "\(e.accountID.raw.uuidString)|\(fa.code)"
                preTaxQty[feeKey] = (preTaxQty[feeKey] ?? 0) - Money.abs(fee)
            }
        }
        for d in r.deemedPositions {
            let key = "\(d.accountID.raw.uuidString)|\(d.asset.code)"
            if let expected = preTaxQty[key], Money.abs(expected - d.quantity) > Money.qtyEpsilon,
               !r.shortfallKeys.contains(key) {
                issues.append(.init(
                    id: "V-DEM-01", severity: "critical",
                    message: "의제 스냅샷 수량이 2027-01-01 0시까지 재생 결과와 다릅니다 (기대 \(Money.decimalString(expected)))",
                    context: d.asset.code
                ))
            }
            if let m = d.marketUnitKRW {
                if d.deemedUnitKRW != max(d.bookUnitKRW, m) {
                    issues.append(.init(id: "V-DEM-02", severity: "critical", message: "의제 단가 max 위반", context: d.asset.code))
                }
            }
        }
        // ── V-DEM-04 시가 누락 ─────────────────────────────────────────
        if !r.missingMarketAssets.isEmpty {
            issues.append(.init(
                id: "V-DEM-04", severity: "critical",
                message: "의제 시가 누락 — 2027-01-01 0시(= 2026-12-31 24시) 시가를 입력하세요",
                context: r.missingMarketAssets.map(\.code).joined(separator: ",")
            ))
        }

        // ── V-FX-01/02/03 ──────────────────────────────────────────────
        if !r.missingFXDays.isEmpty {
            issues.append(.init(id: "V-FX-01", severity: "critical", message: "환율 누락", context: r.missingFXDays.joined(separator: ",")))
        }
        if input.events.contains(where: { $0.needsFX }) {
            issues.append(.init(id: "V-FX-01", severity: "critical", message: "needsFX 이벤트 잔존", context: nil))
        }
        if !input.fxPublished.isEmpty {
            for d in s.disposals {
                guard let rate = d.fxRateUsed else { continue }
                guard let src = d.fxSourceDate else {
                    issues.append(.init(id: "V-FX-02", severity: "critical", message: "사용한 환율의 고시일이 기록되지 않았습니다", context: TaxTime.dayKST(d.timestamp)))
                    continue
                }
                guard let published = input.fxPublished[src] else {
                    issues.append(.init(id: "V-FX-02", severity: "critical", message: "사용한 환율의 출처(\(src))가 저장된 환율표에 없습니다", context: TaxTime.dayKST(d.timestamp)))
                    continue
                }
                if published != rate {
                    issues.append(.init(id: "V-FX-02", severity: "critical", message: "사용한 환율이 저장된 원천 값과 다릅니다", context: src))
                }
            }
        }
        for fx in r.fxResolutions where fx.usedPreviousPublished {
            if fx.sourceDate.isEmpty || fx.sourceDate == fx.eventDay {
                issues.append(.init(
                    id: "V-FX-03", severity: "warning",
                    message: "휴일·미고시 환율 대체 시 적용 고시일(sourceDate)이 없습니다",
                    context: fx.eventDay
                ))
            }
        }

        // ── V-IMP-04 OKX 파일 짝 확인 ──────────────────────────────────
        //
        // OKX Trading History 의 Transfer 행은 거래↔펀딩 계정 내부 이동으로 해석한다.
        // 외부 입출금은 Funding History 의 Deposit/Withdrawal 에만 있으므로,
        // Funding History 를 안 가져왔으면 **국내↔해외 전송이 통째로 빠진다**.
        // 잘못된 숫자가 조용히 나오지 않도록 여기서 막는다.
        let hasOKXTradingInternal = input.events.contains {
            $0.sourceKind == "okx-trading-history-csv-v1" && $0.type == .transferInternal
        }
        let hasOKXFunding = input.events.contains { $0.sourceKind == "okx-funding-history-csv-v1" }
        if hasOKXTradingInternal, !hasOKXFunding {
            issues.append(.init(
                id: "V-IMP-04", severity: "critical",
                message: "OKX Trading History 의 이동 기록만 있습니다. 외부 입출금은 Funding History 에 있으므로 함께 가져오세요 — 없으면 국내↔해외 전송이 누락되어 취득원가가 사라집니다",
                context: "okx-funding-history 누락"
            ))
        }

        // ── V-IMP-01 중복 fingerprint ──────────────────────────────────
        var seenFP: Set<String> = []
        var dupeFP: Set<String> = []
        for e in input.events where !e.fingerprint.isEmpty {
            if seenFP.contains(e.fingerprint) { dupeFP.insert(e.fingerprint) }
            seenFP.insert(e.fingerprint)
        }
        if !dupeFP.isEmpty {
            issues.append(.init(
                id: "V-IMP-01", severity: "critical",
                message: "중복 거래가 \(dupeFP.count)건 있습니다 (같은 파일을 두 번 가져왔을 수 있습니다)",
                context: nil
            ))
        }

        // ── V-IMP-05 서로 다른 파일에 같은 거래가 들어온 흔적 ──────────
        //
        // 행 번호가 지문에 섞여 있던 때 가져온 데이터는 기간이 겹치는 export 를 다시 넣으면
        // 같은 거래가 두 건으로 남는다. 내용 기준으로 다시 세어 확인한다.
        var byContent: [String: Set<String>] = [:]   // 내용키 → 출처 파일 집합
        for e in input.events where e.type != .ignored {
            guard let sf = e.sourceFileID else { continue }
            let key = Fingerprint.contentKey(for: e, parserID: e.sourceKind)
            byContent[key, default: []].insert(sf.raw.uuidString)
        }
        let crossFileDupes = byContent.filter { $0.value.count > 1 }
        if !crossFileDupes.isEmpty {
            issues.append(.init(
                id: "V-IMP-05", severity: "warning",
                message: "같은 거래가 서로 다른 파일에서 \(crossFileDupes.count)건 중복으로 보입니다 — 기간이 겹치는 파일을 가져왔는지 확인하세요",
                context: nil
            ))
        }

        // ── 정책 일치 ──────────────────────────────────────────────────
        if s.policyBundleID != p.id {
            issues.append(.init(id: "V-POL-01", severity: "critical", message: "정책 번들 ID 불일치", context: nil))
        }
        // 고지 문구 누락 (design/10-integrity-engine §3)
        if p.transferCost.id == "abandon_lost_cost", !s.disclaimers.contains(TaxCopy.transferCost) {
            issues.append(.init(id: "V-POL-01", severity: "warning", message: "전송 소실 원가 고지 문구가 리포트에 없습니다", context: nil))
        }

        let hasCritical = issues.contains { $0.severity == "critical" }
        let hasWarning = issues.contains { $0.severity == "warning" }
        let status: String
        if hasCritical {
            status = "failed"
        } else if hasWarning {
            status = "passedWithWarnings"
        } else {
            status = "passed"
        }

        return VerificationReport(
            runID: UUID(),
            status: status,
            issues: dedupe(issues),
            calculatedAt: Date()
        )
    }

    /// 이 수수료가 **수수료 자산 장부의 수량을 별도로 줄이는가**.
    ///
    /// 엔진 `CostBasisEngine.feeCostKRW` 와 규칙이 반드시 같아야 한다. 어긋나면 정상 계산이
    /// 「이벤트 수량 합과 보유 수량이 다릅니다」로 막힌다.
    ///
    /// - 원화 수수료: 장부와 무관 (금액일 뿐)
    /// - 매수의 기초자산 수수료: 받는 수량에서 이미 차감했다 → 다시 빼지 않는다
    /// - 매도의 기초자산 수수료: 체결 수량과 **별도로** 빠진다 → 뺀다
    ///   (원본이 이미 순액인 판본 `quantityIsNetOfFee` 만 예외)
    /// - 그 밖의 코인 수수료(USDT·BNB…): 항상 뺀다
    private static func feeReducesBook(_ e: LedgerEvent, feeAsset fa: AssetSymbol) -> Bool {
        guard e.type == .buy || e.type == .sell, !fa.isKRW else { return false }
        guard fa == e.baseAsset else { return true }
        if e.type == .buy { return false }
        return !e.quantityIsNetOfFee
    }

    /// 같은 ID·메시지·문맥이 반복되면 하나로 합친다 (SwiftUI 목록 식별자 중복 방지 — 리뷰 4-6)
    private static func dedupe(_ issues: [VerificationIssue]) -> [VerificationIssue] {
        var seen: Set<String> = []
        var out: [VerificationIssue] = []
        for i in issues {
            let key = "\(i.id)|\(i.severity)|\(i.message)|\(i.context ?? "")"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(i)
        }
        return out
    }
}
