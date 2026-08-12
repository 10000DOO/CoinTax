import Foundation

struct CostBasisEngine {
    var policies: PolicyBundle
    var accountsByID: [AccountID: Account]
    /// 실제 고시·수동 입력된 일자별 USD/KRW (미고시일 키 없음)
    var fxRates: [String: Decimal]
    var marketPrices: [String: Decimal] // asset code -> KRW unit as of deemed

    func replay(
        events: [LedgerEvent],
        links: [TransferLink],
        asOf: Date = Date()
    ) throws -> ReplayResult {
        var books: [AccountID: [String: AssetBook]] = [:]
        var disposals: [DisposalRecord] = []
        var abandonedTotal: Decimal = 0
        var extraDeductible: Decimal = 0
        var abandonedByYear: [Int: Decimal] = [:]
        var extraDeductibleByYear: [Int: Decimal] = [:]
        var warnings: [String] = []
        var issues: [VerificationIssue] = []
        var transferDetails: [TransferCostDetail] = []
        var missingMarket: Set<String> = []
        var missingFX: Set<String> = []
        var fxResolutions: [FXResolvedRate] = []
        var fxResolvedByDay: [String: FXResolvedRate] = [:]
        var deemedKeys: Set<String> = []
        var shortfallKeys: Set<String> = []
        /// 출금은 처리했는데 아직 도착(입금 이벤트)을 지나지 않은 전송의 이전 원가.
        /// 입금 시각에 입고하기 위해 잠시 들고 있는다.
        var pendingArrivals: [EventID: (qty: Decimal, cost: Decimal)] = [:]
        /// 이미 지나간 입금 이벤트. 입금이 출금보다 먼저 기록된 전송을 구분한다.
        var seenDeposits: Set<EventID> = []

        // id 는 저장소에서 유일하지만, 방어적으로 첫 값을 채택한다 (중복 키로 프로세스가 죽지 않게)
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 같은 timestamp의 정렬 기준은 rawRef(원본 행 순서) 우선 — 임의 UUID 순서에 의존하면
        // 같은 초에 발생한 매수/매도가 뒤바뀌어 재고 부족이 날 수 있다.
        let sorted = events
            .filter { $0.type != .ignored }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                let a = $0.rawRef ?? ""
                let b = $1.rawRef ?? ""
                if a != b { return a < b }
                return $0.id.raw.uuidString < $1.id.raw.uuidString
            }
        let processedIDs = Set(sorted.map(\.id))

        let confirmed = links.filter { $0.status == .confirmed }
        // 같은 출금이 두 링크에 확정되면 원가가 이중 이전된다 → 첫 링크만 채택하고 나머지는 Critical.
        var linkByFrom: [EventID: TransferLink] = [:]
        var linkedAsTo: Set<EventID> = []
        for link in confirmed.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            // 링크를 채택하면 입금 쪽은 「출금 처리 때 입고된다」고 보고 건너뛴다.
            // 그래서 **출금이 실제로 처리되지 않는 링크는 채택해선 안 된다** —
            // 채택하면 입금은 건너뛰고 입고도 일어나지 않아 자산이 통째로 사라진다.
            guard let w = eventsByID[link.fromEventID], processedIDs.contains(link.fromEventID) else {
                issues.append(.init(
                    id: "V-QTY-03", severity: "critical",
                    message: "확정 링크의 출금 거래가 계산 대상에 없습니다 (삭제되었거나 제외 처리됨) — 링크를 해제하세요",
                    context: link.id.raw.uuidString
                ))
                continue
            }
            guard let d = eventsByID[link.toEventID], processedIDs.contains(link.toEventID) else {
                issues.append(.init(
                    id: "V-QTY-03", severity: "critical",
                    message: "확정 링크의 입금 거래가 계산 대상에 없습니다 — 링크를 해제하세요",
                    context: link.id.raw.uuidString
                ))
                continue
            }
            guard Money.abs(w.quantity) > 0 else {
                issues.append(.init(
                    id: "V-QTY-03", severity: "critical",
                    message: "출금 수량이 0인 링크는 원가를 이전할 수 없습니다 — 링크를 해제하고 원본을 확인하세요",
                    context: link.id.raw.uuidString
                ))
                continue
            }
            guard Money.abs(d.quantity) > 0 else {
                issues.append(.init(
                    id: "V-QTY-03", severity: "critical",
                    message: "입금 수량이 0인 링크입니다 — 링크를 해제하고 원본을 확인하세요",
                    context: link.id.raw.uuidString
                ))
                continue
            }
            if linkByFrom[link.fromEventID] != nil {
                issues.append(.init(
                    id: "V-QTY-04", severity: "critical",
                    message: "한 출금이 두 개 이상의 입금에 확정 연결되어 있습니다 (원가 이중 이전)",
                    context: link.id.raw.uuidString
                ))
                continue
            }
            if linkedAsTo.contains(link.toEventID) {
                issues.append(.init(
                    id: "V-QTY-04", severity: "critical",
                    message: "한 입금이 두 개 이상의 출금에 확정 연결되어 있습니다 (원가 이중 계상)",
                    context: link.id.raw.uuidString
                ))
                continue
            }
            linkByFrom[link.fromEventID] = link
            linkedAsTo.insert(link.toEventID)
        }

        let tTax = TaxTime.taxStartDate
        let pass1 = sorted.filter { $0.timestamp < tTax }
        let pass2 = sorted.filter { $0.timestamp >= tTax }

        func bookKey(_ accountID: AccountID, _ asset: AssetSymbol) -> String {
            "\(accountID.raw.uuidString)|\(asset.code)"
        }

        func book(for accountID: AccountID, asset: AssetSymbol) -> AssetBook {
            let key = asset.code
            if books[accountID] == nil { books[accountID] = [:] }
            if let existing = books[accountID]![key] { return existing }
            let method = accountsByID[accountID]?.costMethod ?? .fifo
            let b = AssetBookFactory.make(method)
            books[accountID]![key] = b
            return b
        }

        /// 국세청 서삼46015-11986 취지: 미고시일(공휴일 등) → 직전 고시 기준환율
        func resolveFX(_ date: Date) -> FXResolvedRate? {
            let day = TaxTime.dayKST(date)
            if let cached = fxResolvedByDay[day] { return cached }
            guard let resolved = FXHolidayPolicy.resolve(eventDay: day, published: fxRates) else {
                return nil
            }
            fxResolvedByDay[day] = resolved
            fxResolutions.append(resolved)
            if resolved.usedPreviousPublished {
                warnings.append(
                    "환율 미고시일 \(resolved.eventDay) → 직전 고시일 \(resolved.sourceDate) 기준환율 적용 (FXHolidayPolicy/\(FXHolidayPolicy.id))"
                )
            }
            return resolved
        }

        /// 견적 자산이 USD 연동(USDT/USD)인지. 그 외 코인 견적은 환산 근거가 없다.
        func isUSDLinkedQuote(_ e: LedgerEvent) -> Bool {
            guard let qa = e.quoteAsset else { return true } // 견적 미기재 → USDT 마켓 가정 (기존 동작)
            if qa.isKRW { return false }
            return qa.isUSDTish && policies.fxAssumption.usdtEqualsUSD
        }

        /// 견적 금액(견적 자산 단위)을 KRW로 환산. 실패 시 nil + 이슈 기록.
        func krwFromQuote(_ e: LedgerEvent, quote: Decimal, purpose: String) -> (krw: Decimal, fx: FXResolvedRate?)? {
            if e.quoteAsset?.isKRW == true {
                return (Money.abs(quote), nil)
            }
            guard isUSDLinkedQuote(e) else {
                // 코인 견적(예: ETH/BTC) — USDT 환산 경로가 없으면 추정 금지 (IMPLEMENTATION §6.2-3)
                issues.append(.init(
                    id: "V-FX-01", severity: "critical",
                    message: "\(e.quoteAsset?.code ?? "?") 견적 거래는 원화 환산 근거가 없습니다 (\(purpose))",
                    context: "\(e.baseAsset.code)/\(e.quoteAsset?.code ?? "?") \(TaxTime.dayKST(e.timestamp))"
                ))
                return nil
            }
            guard let resolved = resolveFX(e.timestamp) else {
                missingFX.insert(TaxTime.dayKST(e.timestamp))
                issues.append(.init(
                    id: "V-FX-01", severity: "critical",
                    message: "환율이 없어 원화 환산을 못했습니다 (\(purpose))",
                    context: TaxTime.dayKST(e.timestamp)
                ))
                return nil
            }
            return (Money.abs(quote) * resolved.rate, resolved)
        }

        func quoteAmount(_ e: LedgerEvent) -> Decimal {
            if let qa = e.quoteAmount { return Money.abs(qa) }
            if let p = e.price { return Money.abs(e.quantity) * p }
            return 0
        }

        /// 수수료의 KRW 원가.
        /// - 원화 수수료: 금액 그대로
        /// - **가상자산 수수료(USDT·BNB 등): 그 자산 장부에서 처분하고 장부 원가를 부대비용으로** (IMPLEMENTATION §6.3)
        ///
        /// USDT 수수료를 「환율로 환산만 하고 장부는 그대로」 두면 **수수료로 나간 USDT 가 보유에 남는다.**
        /// 그러면 평단·의제취득가·이후 손익이 전부 어긋난다. 코인으로 낸 수수료는 종류를 가리지 않고
        /// 실제로 지갑에서 빠지므로 반드시 장부에서 처분한다.
        ///
        /// 장부 원가를 부대비용으로 쓰는 것은 「수수료 자산 처분손익 인식 + 시가를 필요경비로」와 값이 같다.
        /// (처분이익 = 시가 − 장부원가, 필요경비 = 시가 → 순효과 = −장부원가)
        func feeCostKRW(_ e: LedgerEvent, skipAsset: AssetSymbol? = nil) -> Decimal {
            guard let feeAmt = e.feeAmount, feeAmt != 0 else { return 0 }
            let amount = Money.abs(feeAmt)
            let asset = e.feeAsset ?? e.baseAsset
            if let skip = skipAsset, asset == skip { return 0 }
            if asset.isKRW { return amount }
            let b = book(for: e.accountID, asset: asset)
            let out = b.disposeClamped(qty: amount)
            if out.shortfallQty > Money.qtyEpsilon {
                shortfallKeys.insert(bookKey(e.accountID, asset))
                warnings.append("수수료 자산 \(asset.code) 장부 부족 \(Money.decimalString(out.shortfallQty)) — 그만큼 부대비용에 반영되지 않았습니다")
            }
            return out.costKRW
        }

        /// 코인↔코인 매매의 **견적자산 leg**.
        ///
        /// 소득세법 시행령 제88조는 가상자산 교환의 양도가액 산정 방법을 규정한다 → 교환은 처분이다.
        /// 문서(03-tax-rules §3.1)도 `ALT→USDT` 는 처분으로 잡고 있었는데 반대 방향에서
        /// USDT 가 나가는 leg 만 빠져 있었다. 대칭을 맞춘다.
        ///
        /// - 매수: 견적자산을 장부에서 출고하고 그 처분손익을 인식
        /// - 매도: 받은 견적자산을 그 시점 원화가액으로 입고
        ///
        /// 이 leg 이 없으면 USDT 수량이 줄지 않아 보유·평단·의제취득가가 모두 틀린다.
        func processQuoteLeg(_ e: LedgerEvent, quoteKRW: Decimal?, recordTaxDisposals: Bool) {
            guard let quote = e.quoteAsset, let quoteQty = e.cryptoQuoteQuantity else { return }
            guard let quoteKRW else {
                // 원화 환산 실패는 `krwFromQuote` 가 이미 Critical(V-FX-01)로 기록했다.
                // 근거 없는 0원으로 장부를 움직이면 오차가 조용히 누적되므로 건드리지 않는다.
                //
                // 대신 이 자산을 수량 대조에서 제외한다. 그러지 않으면 검증기가
                // 「이벤트 수량 합과 보유 수량이 다릅니다」를 덧붙여, 진짜 원인(환율 누락)이
                // 데이터 오류처럼 보이게 된다.
                shortfallKeys.insert(bookKey(e.accountID, quote))
                return
            }
            let b = book(for: e.accountID, asset: quote)
            switch e.type {
            case .buy:
                let out = b.disposeClamped(qty: quoteQty)
                if out.shortfallQty > Money.qtyEpsilon {
                    shortfallKeys.insert(bookKey(e.accountID, quote))
                    let dust = Money.isDustShortfall(out.shortfallQty, of: quoteQty)
                    issues.append(.init(
                        id: "V-QTY-02", severity: dust ? "warning" : "critical",
                        message: dust
                            ? "사용한 \(quote.code)가 장부보다 \(Money.decimalString(out.shortfallQty)) 많습니다 (거래소 반올림 수준)"
                            : "보유한 \(quote.code)보다 많이 사용한 거래입니다 (부족 \(Money.decimalString(out.shortfallQty)) \(quote.code)) — 이 계정의 거래내역이 시작되기 전 보유분이 있거나 입금·전송 내역이 빠졌을 수 있습니다. 더 이전 기간 원본을 함께 가져오세요",
                        context: "\(e.baseAsset.code)/\(quote.code) \(TaxTime.dayKST(e.timestamp)) \(e.rawRef ?? e.id.raw.uuidString)"
                    ))
                }
                guard recordTaxDisposals, e.timestamp >= tTax else { return }
                disposals.append(DisposalRecord(
                    id: UUID(),
                    eventID: e.id,
                    timestamp: e.timestamp,
                    accountID: e.accountID,
                    asset: quote,
                    quantity: quoteQty,
                    proceedsKRW: quoteKRW,
                    costKRW: out.costKRW,
                    feesKRW: 0, // 체결 수수료는 취득한 자산의 원가에 가산했다 (이중 계상 금지)
                    pnlKRW: quoteKRW - out.costKRW,
                    method: accountsByID[e.accountID]?.costMethod ?? .fifo,
                    taxYear: TaxTime.calendarYearKST(e.timestamp),
                    fxRateUsed: fxResolvedByDay[TaxTime.dayKST(e.timestamp)]?.rate,
                    fxSourceDate: fxResolvedByDay[TaxTime.dayKST(e.timestamp)]?.sourceDate,
                    deemedApplied: deemedKeys.contains(bookKey(e.accountID, quote))
                ))
            case .sell:
                b.acquire(qty: quoteQty, costKRW: quoteKRW)
            default:
                break
            }
        }

        func process(_ list: [LedgerEvent], recordTaxDisposals: Bool) {
            for e in list {
                switch e.type {
                case .buy:
                    var qty = Money.abs(e.quantity)
                    // base 자산 수수료: 순취득 수량 감소 (IMPLEMENTATION §6.3).
                    // 단, 원본이 이미 순액이면(OKX Balance Change) 다시 빼지 않는다 — 리뷰 1-1.
                    if !e.quantityIsNetOfFee,
                       let fa = e.feeAsset, fa == e.baseAsset, let fee = e.feeAmount {
                        qty = max(0, qty - Money.abs(fee))
                    }
                    let krw = e.quoteAmountKRW.map { Money.abs($0) }
                    var quoteKRW: Decimal?
                    if let krw {
                        quoteKRW = krw
                    } else if let conv = krwFromQuote(e, quote: quoteAmount(e), purpose: "취득가액") {
                        quoteKRW = conv.krw
                    }
                    // 순서: 견적자산 지출 → 수수료 지출 → 기초자산 입고.
                    // 수수료를 견적자산(USDT)으로 내면 같은 장부를 두 번 건드리므로 순서가 원가에 영향을 준다.
                    // 실제 거래 순서(대금 먼저, 수수료 나중)를 그대로 따른다.
                    processQuoteLeg(e, quoteKRW: quoteKRW, recordTaxDisposals: recordTaxDisposals)
                    // 환산 불가 — 원가 0으로 두고 Critical 이슈로 보고 (계산은 계속)
                    var cost = quoteKRW ?? 0
                    // base 수수료는 수량에 반영했으므로 금액에서 제외
                    cost += feeCostKRW(e, skipAsset: e.baseAsset)
                    // 취득가 0원 매수는 파싱이 깨졌다는 뜻이다. 조용히 통과시키면
                    // 이후 처분 전액이 이익으로 잡혀 세액이 크게 부풀려진다.
                    if qty > Money.qtyEpsilon, Money.isApproxZero(cost, eps: 0) {
                        issues.append(.init(
                            id: "V-COST-07", severity: "critical",
                            message: "취득가액이 0원인 매수입니다 — 원본에서 금액 칸을 읽지 못했을 수 있습니다 (처분 시 전액이 이익으로 잡힙니다)",
                            context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp)) \(e.rawRef ?? e.id.raw.uuidString)"
                        ))
                    }
                    book(for: e.accountID, asset: e.baseAsset).acquire(qty: qty, costKRW: cost)

                case .sell:
                    let qty = Money.abs(e.quantity)
                    let b = book(for: e.accountID, asset: e.baseAsset)
                    let costBefore = b.totalCost
                    let out = b.disposeClamped(qty: qty)
                    if out.shortfallQty > Money.qtyEpsilon {
                        shortfallKeys.insert(bookKey(e.accountID, e.baseAsset))
                        let dust = Money.isDustShortfall(out.shortfallQty, of: qty)
                        issues.append(.init(
                            id: "V-QTY-02", severity: dust ? "warning" : "critical",
                            message: dust
                                ? "매도 수량이 장부보다 \(Money.decimalString(out.shortfallQty)) \(e.baseAsset.code) 많습니다 (거래소 반올림 수준 — 그만큼 취득원가가 잡히지 않았습니다)"
                                : "보유 수량보다 많은 매도입니다 (부족 \(Money.decimalString(out.shortfallQty)) \(e.baseAsset.code)) — 이 계정의 거래내역이 시작되기 전 보유분이 있거나 내역 일부가 빠졌을 수 있습니다. 더 이전 기간 원본을 함께 가져오세요",
                            context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp)) \(e.rawRef ?? e.id.raw.uuidString)"
                        ))
                    }
                    if out.costKRW > costBefore + 1 {
                        issues.append(.init(
                            id: "V-COST-01", severity: "critical",
                            message: "매도 출고 원가가 직전 총 장부원가를 초과했습니다",
                            context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp))"
                        ))
                    }
                    // 견적자산 원화가액은 **과세 대상이 아닌 처분에도** 필요하다.
                    // 코인↔코인 매도로 받은 USDT 의 취득원가가 곧 이 값이고,
                    // 그 원가가 2026-12-31 의제취득가와 이후 처분손익의 출발점이 된다.
                    // (원화 마켓 매도는 여전히 환율이 필요 없다 — 과세 대상일 때만 계산한다)
                    let isTaxable = recordTaxDisposals && e.timestamp >= tTax
                    let needsQuoteKRW = isTaxable || e.cryptoQuoteQuantity != nil
                    var proceeds: Decimal = 0
                    var usedFX: FXResolvedRate?
                    var quoteKRW: Decimal?
                    if needsQuoteKRW {
                        if let krw = e.quoteAmountKRW {
                            proceeds = Money.abs(krw)
                            quoteKRW = proceeds
                        } else if let conv = krwFromQuote(e, quote: quoteAmount(e), purpose: "양도가액") {
                            proceeds = conv.krw
                            quoteKRW = conv.krw
                            usedFX = conv.fx
                        }
                    }
                    processQuoteLeg(e, quoteKRW: quoteKRW, recordTaxDisposals: recordTaxDisposals)

                    // **수수료 처리는 과세 여부보다 앞선다.** 수수료로 나간 코인은 과세 시작 전에도
                    // 지갑에서 실제로 빠지므로, 여기서 장부에 반영하지 않으면 2026-12-31 보유 수량이
                    // 부풀고 의제취득가가 틀어진다 (검증기 V-QTY-01·V-DEM-01 과도 어긋난다).
                    //
                    // 매도 수수료가 기초자산이면 체결 수량과 **별도로** 빠진다 (매수는 받는 수량에서 차감되므로 반대다).
                    // 원본이 이미 순액인 판본(OKX Balance Change)만 중복 차감을 피해 건너뛴다.
                    let feeSkip: AssetSymbol? = e.quantityIsNetOfFee ? e.baseAsset : nil
                    let fees = feeCostKRW(e, skipAsset: feeSkip)
                    guard isTaxable else { continue }

                    let pnl = proceeds - out.costKRW - fees
                    let method = accountsByID[e.accountID]?.costMethod ?? .fifo
                    disposals.append(DisposalRecord(
                        id: UUID(),
                        eventID: e.id,
                        timestamp: e.timestamp,
                        accountID: e.accountID,
                        asset: e.baseAsset,
                        quantity: qty,
                        proceedsKRW: proceeds,
                        costKRW: out.costKRW,
                        feesKRW: fees,
                        pnlKRW: pnl,
                        method: method,
                        taxYear: TaxTime.calendarYearKST(e.timestamp),
                        fxRateUsed: usedFX?.rate,
                        fxSourceDate: usedFX?.sourceDate,
                        deemedApplied: deemedKeys.contains(bookKey(e.accountID, e.baseAsset))
                    ))

                case .deposit:
                    seenDeposits.insert(e.id)
                    if linkedAsTo.contains(e.id) {
                        // 확정 전송의 도착분은 **이 입금 시각에** 입고한다.
                        // 출금 시각에 입고하면 연말을 걸치는 전송(예: 12/31 출금 → 1/2 입금)에서
                        // 아직 도착하지 않은 자산이 2026-12-31 스냅샷에 잡혀 의제취득가가 잘못 적용된다.
                        if let pending = pendingArrivals.removeValue(forKey: e.id) {
                            book(for: e.accountID, asset: e.baseAsset).acquire(qty: pending.qty, costKRW: pending.cost)
                        }
                        // 아직 출금을 처리하지 않았다면(거래소 시계 차이로 입금이 먼저 기록된 경우)
                        // 출금 처리 시점에 입고한다 — 그때 `seenDeposits` 로 판단한다.
                        continue
                    }
                    if e.baseAsset.isKRW { continue }
                    // external unlinked deposit: cost 0 + warning
                    warnings.append("미매칭 입금 원가 0: \(e.baseAsset.code) \(e.quantity)")
                    issues.append(.init(
                        id: "V-QTY-04", severity: "warning",
                        message: "연결되지 않은 입금은 취득가 0원으로 처리됩니다 (처분 시 전액이 이익) — 상대 출금을 연결하세요",
                        context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp))"
                    ))
                    book(for: e.accountID, asset: e.baseAsset).acquire(qty: Money.abs(e.quantity), costKRW: 0)

                case .withdrawal:
                    if e.baseAsset.isKRW { continue }
                    let wQty = Money.abs(e.quantity)
                    let b = book(for: e.accountID, asset: e.baseAsset)
                    if let link = linkByFrom[e.id], let dep = eventsByID[link.toEventID] {
                        let rQty = Money.abs(dep.quantity)
                        let out = b.disposeClamped(qty: wQty)
                        if out.shortfallQty > Money.qtyEpsilon {
                            shortfallKeys.insert(bookKey(e.accountID, e.baseAsset))
                            let dust = Money.isDustShortfall(out.shortfallQty, of: wQty)
                            issues.append(.init(
                                id: "V-QTY-02", severity: dust ? "warning" : "critical",
                                message: dust
                                    ? "출금 수량이 장부보다 \(Money.decimalString(out.shortfallQty)) \(e.baseAsset.code) 많습니다 (거래소 반올림 수준)"
                                    : "보유 수량보다 많은 출금입니다 (부족 \(Money.decimalString(out.shortfallQty)) \(e.baseAsset.code)) — 이 계정의 거래내역이 시작되기 전 보유분이 있거나 내역 일부가 빠졌을 수 있습니다. 더 이전 기간 원본을 함께 가져오세요",
                                context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp)) \(e.rawRef ?? e.id.raw.uuidString)"
                            ))
                        }
                        // 출금 수수료가 원금과 별도로 지갑에서 빠지는 경우(바이낸스 Withdraw) 그 수량도 처분한다.
                        var explicitFee: Decimal = 0
                        if !e.quantityIsNetOfFee,
                           let fee = e.feeAmount, fee > 0,
                           e.feeAsset == nil || e.feeAsset == e.baseAsset {
                            let feeOut = b.disposeClamped(qty: Money.abs(fee))
                            explicitFee = feeOut.costKRW
                        }
                        guard wQty > 0 else { continue }
                        let result = policies.transferCost.apply(
                            outboundCostKRW: out.costKRW,
                            withdrawnQty: wQty,
                            receivedQty: rQty,
                            explicitFeeCostKRW: explicitFee
                        )
                        abandonedTotal += result.abandonedCostKRW
                        extraDeductible += result.deductibleExpenseKRW
                        let year = TaxTime.calendarYearKST(e.timestamp)
                        abandonedByYear[year, default: 0] += result.abandonedCostKRW
                        extraDeductibleByYear[year, default: 0] += result.deductibleExpenseKRW
                        if seenDeposits.contains(link.toEventID) {
                            // 입금이 먼저 기록된 전송 — 지금 입고하지 않으면 원가가 사라진다
                            book(for: dep.accountID, asset: dep.baseAsset).acquire(qty: rQty, costKRW: result.transferredCostKRW)
                        } else {
                            pendingArrivals[link.toEventID] = (qty: rQty, cost: result.transferredCostKRW)
                        }
                        transferDetails.append(TransferCostDetail(
                            linkID: link.id,
                            outboundCostKRW: out.costKRW,
                            transferredCostKRW: result.transferredCostKRW,
                            abandonedCostKRW: result.abandonedCostKRW,
                            deductibleExpenseKRW: result.deductibleExpenseKRW,
                            ratio: Money.clamp(rQty / wQty, 0, 1)
                        ))
                    } else {
                        let out = b.disposeClamped(qty: wQty)
                        if out.shortfallQty > Money.qtyEpsilon {
                            shortfallKeys.insert(bookKey(e.accountID, e.baseAsset))
                            let dust = Money.isDustShortfall(out.shortfallQty, of: wQty)
                            issues.append(.init(
                                id: "V-QTY-02", severity: dust ? "warning" : "critical",
                                message: dust
                                    ? "출금 수량이 장부보다 \(Money.decimalString(out.shortfallQty)) \(e.baseAsset.code) 많습니다 (거래소 반올림 수준)"
                                    : "보유 수량보다 많은 출금입니다 (부족 \(Money.decimalString(out.shortfallQty)) \(e.baseAsset.code)) — 이 계정의 거래내역이 시작되기 전 보유분이 있거나 내역 일부가 빠졌을 수 있습니다. 더 이전 기간 원본을 함께 가져오세요",
                                context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp)) \(e.rawRef ?? e.id.raw.uuidString)"
                            ))
                        }
                        abandonedTotal += out.costKRW
                        abandonedByYear[TaxTime.calendarYearKST(e.timestamp), default: 0] += out.costKRW
                        warnings.append("미매칭 출금 원가 소멸: \(e.baseAsset.code) \(Money.decimalString(wQty))")
                        issues.append(.init(
                            id: "V-QTY-04", severity: "warning",
                            message: "연결되지 않은 출금의 취득원가는 소멸 처리됩니다 (세액이 커지는 방향) — 다른 거래소로 보낸 것이면 상대 입금을 연결하고, 개인지갑으로 보낸 것이면 「전송 연결」 화면에서 개인지갑으로 지정하세요 (지정하지 않으면 보유 현황에서도 빠집니다)",
                            context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp))"
                        ))
                        if !e.quantityIsNetOfFee, let fee = e.feeAmount, fee > 0 {
                            let feeOut = b.disposeClamped(qty: Money.abs(fee))
                            abandonedTotal += feeOut.costKRW
                            abandonedByYear[TaxTime.calendarYearKST(e.timestamp), default: 0] += feeOut.costKRW
                        }
                    }

                case .transferInternal:
                    // 같은 계정 안의 지갑 이동. 계정×자산 단위 단일 장부이므로 총원가·수량 불변 (LOCK v1).
                    break

                case .income:
                    if !e.baseAsset.isKRW {
                        book(for: e.accountID, asset: e.baseAsset).acquire(qty: Money.abs(e.quantity), costKRW: 0)
                        issues.append(.init(
                            id: "V-COST-01", severity: "warning",
                            message: "에어드롭·리베이트 등은 취득가 0원으로 처리됩니다 (처분 시 전액이 이익)",
                            context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp))"
                        ))
                    }

                case .fiatDeposit, .fiatWithdraw, .fee, .other, .ignored:
                    break
                }
            }
        }

        process(pass1, recordTaxDisposals: false)

        // 과세 시작 시점에 「이동 중」인 전송이 있으면 그 수량은 어느 계정 장부에도 없다.
        // 의제취득가(2027-01-01 0시 보유분) 대상에서 빠지므로 사용자가 알아야 한다.
        if !pendingArrivals.isEmpty {
            issues.append(.init(
                id: "V-DEM-05", severity: "warning",
                message: "과세 시작 시점(2027-01-01 0시)에 도착하지 않은 전송이 \(pendingArrivals.count)건 있습니다 — 그 수량은 의제취득가 대상에서 빠집니다 (세액이 커지는 방향)",
                context: nil
            ))
        }

        // --- 의제취득가 적용 (2026-12-31 24:00 KST 스냅샷) ---
        // 「실제 취득가 vs 시가」 비교 단위는 세무 확인 대기 항목(TQ-01)이라 두 방식을 모두 지원한다.
        //   positionAverage: 보유 전체 평균 단가와 비교 (기본 · 보수적)
        //   perLot:          매입 건별로 각각 비교 (FIFO 계정에서만 결과가 달라진다)
        let deemedMode = policies.deemed.mode
        var deemedPositions: [DeemedPosition] = []
        let deemedTargets = books
            .flatMap { accID, map in map.map { (accID, $0.key, $0.value) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.raw.uuidString < rhs.0.raw.uuidString
            }
        for (accID, assetCode, b) in deemedTargets {
            guard b.quantity > Money.qtyEpsilon else { continue }
            let asset = AssetSymbol(assetCode)
            let bookUnit = b.snapshotUnitCost()
            let market = marketPrices[assetCode]
            if market == nil {
                missingMarket.insert(assetCode)
                issues.append(.init(
                    id: "V-DEM-04", severity: "critical",
                    message: "2027-01-01 0시 시가가 없어 의제취득가를 확정할 수 없습니다",
                    context: assetCode
                ))
            }
            guard policies.deemed.deemedUnit(bookUnit: bookUnit, marketUnit: market) != nil else {
                continue
            }
            let qty = b.quantity
            let lots = b.openLots

            // 재기동할 lot 구성 계산
            let newLots: [(qty: Decimal, unitCost: Decimal)]
            if deemedMode == .perLot, !lots.isEmpty {
                newLots = lots.compactMap { lot in
                    guard let unit = policies.deemed.deemedUnit(bookUnit: lot.unitCost, marketUnit: market) else { return nil }
                    return (qty: lot.qty, unitCost: unit)
                }
            } else {
                // 평균 방식, 또는 lot 개념이 없는 이동평균 장부
                guard let unit = policies.deemed.deemedUnit(bookUnit: bookUnit, marketUnit: market) else { continue }
                newLots = [(qty: qty, unitCost: unit)]
            }
            guard !newLots.isEmpty else { continue }

            let deemedTotal = newLots.reduce(Decimal(0)) { $0 + $1.qty * $1.unitCost }
            let deemedUnit = Money.isApproxZero(qty) ? 0 : deemedTotal / qty
            // 건별 방식에서는 lot 마다 채택 근거가 갈릴 수 있다 → 그대로 표기한다
            let reason: String = {
                guard let m = market else { return "actual" }
                let tookMarket = newLots.filter { $0.unitCost == m }.count
                if deemedMode == .perLot, newLots.count > 1 {
                    if tookMarket == 0 { return "actual" }
                    if tookMarket == newLots.count { return "market" }
                    return "mixed(\(tookMarket)/\(newLots.count) market)"
                }
                return deemedUnit > bookUnit ? "market" : "actual"
            }()
            deemedPositions.append(DeemedPosition(
                accountID: accID,
                asset: asset,
                quantity: qty,
                bookUnitKRW: bookUnit,
                marketUnitKRW: market,
                deemedUnitKRW: deemedUnit,
                reason: reason,
                basisMode: deemedMode.rawValue,
                lotCount: newLots.count
            ))
            b.replaceLots(newLots)
            deemedKeys.insert(bookKey(accID, asset))
            // V-DEM-03: 재기동 직후 총원가 == 의제 총액
            if Money.abs(b.totalCost - deemedTotal) > 1 {
                issues.append(.init(
                    id: "V-DEM-03", severity: "critical",
                    message: "의제 재기동 후 장부 총원가가 의제 총액과 다릅니다",
                    context: assetCode
                ))
            }
        }

        process(pass2, recordTaxDisposals: true)

        // 모든 확정 링크의 입금은 계산 대상에 있어야 한다(링크 채택 단계에서 확인). 그래도 남았다면
        // 원가가 어디에도 입고되지 않은 것이므로 조용히 넘기지 않는다.
        if !pendingArrivals.isEmpty {
            issues.append(.init(
                id: "V-QTY-03", severity: "critical",
                message: "확정 전송 \(pendingArrivals.count)건의 도착 입금이 처리되지 않아 취득원가가 입고되지 않았습니다 — 링크를 확인하세요",
                context: nil
            ))
        }

        // --- 보유 스냅샷 (결정적 순서) ---
        var rows: [HoldingsRow] = []
        var aggMap: [String: (qty: Decimal, cost: Decimal)] = [:]
        for (accID, assetMap) in books {
            for (code, b) in assetMap {
                guard b.quantity > Money.qtyEpsilon else { continue }
                let unit = b.snapshotUnitCost()
                rows.append(HoldingsRow(
                    accountID: accID,
                    asset: AssetSymbol(code),
                    quantity: b.quantity,
                    averageUnitKRW: unit,
                    totalCostKRW: b.totalCost,
                    method: b.method
                ))
                // V-COST-04 / V-COST-05
                if Money.abs(unit * b.quantity - b.totalCost) > 1 {
                    issues.append(.init(
                        id: "V-COST-04", severity: "critical",
                        message: "평단 × 수량이 총원가와 다릅니다",
                        context: code
                    ))
                }
                if b.method == .fifo {
                    let lotQty = b.openLots.reduce(Decimal(0)) { $0 + $1.qty }
                    let lotCost = b.openLots.reduce(Decimal(0)) { $0 + $1.qty * $1.unitCost }
                    if Money.abs(lotQty - b.quantity) > Money.qtyEpsilon || Money.abs(lotCost - b.totalCost) > 1 {
                        issues.append(.init(
                            id: "V-COST-05", severity: "critical",
                            message: "FIFO 열린 lot 합이 포지션과 다릅니다",
                            context: code
                        ))
                    }
                }
                let prev = aggMap[code] ?? (0, 0)
                aggMap[code] = (prev.qty + b.quantity, prev.cost + b.totalCost)
            }
        }
        rows.sort {
            if $0.asset.code != $1.asset.code { return $0.asset.code < $1.asset.code }
            return ($0.accountID?.raw.uuidString ?? "") < ($1.accountID?.raw.uuidString ?? "")
        }
        let aggregated = aggMap.map { code, v in
            HoldingsRow(
                accountID: nil,
                asset: AssetSymbol(code),
                quantity: v.qty,
                averageUnitKRW: Money.isApproxZero(v.qty) ? 0 : v.cost / v.qty,
                totalCostKRW: v.cost,
                method: nil
            )
        }.sorted { $0.asset.code < $1.asset.code }

        // --- 환율 출처 요약 ---
        let fxNotes = fxResolutions
            .sorted { $0.eventDay < $1.eventDay }
            .map { r -> String in
                r.usedPreviousPublished
                    ? "\(r.eventDay): \(Money.decimalString(r.rate)) (직전 고시일 \(r.sourceDate) 적용)"
                    : "\(r.eventDay): \(Money.decimalString(r.rate)) (당일 고시)"
            }

        return ReplayResult(
            disposals: disposals,
            holdings: HoldingsSnapshot(asOf: asOf, rows: rows, aggregated: aggregated),
            deemedPositions: deemedPositions,
            abandonedTotal: abandonedTotal,
            extraDeductible: extraDeductible,
            abandonedByYear: abandonedByYear,
            extraDeductibleByYear: extraDeductibleByYear,
            warnings: warnings,
            transferCostDetails: transferDetails,
            missingMarketAssets: missingMarket.map { AssetSymbol($0) }.sorted { $0.code < $1.code },
            missingFXDays: Array(missingFX).sorted(),
            fxResolutions: fxResolutions,
            issues: issues,
            fxUsageNotes: fxNotes,
            deemedAppliedKeys: deemedKeys,
            shortfallKeys: shortfallKeys
        )
    }
}

enum CoinTaxError: Error, LocalizedError {
    case missingFX(days: [String])
    case missingMarket(assets: [String])
    case negativeLot(String)
    case unconvertibleQuote(String)
    case verifyFail
    case parserReject(String)
    case formatUnknown
    case parseRow(String)
    case pdfPassword
    case duplicateFile(String)
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingFX(let d): return "환율을 입력하세요: \(d.joined(separator: ", "))"
        case .missingMarket(let a): return "2027-01-01 0시 시가를 입력하세요: \(a.joined(separator: ", "))"
        case .negativeLot(let m): return m
        case .unconvertibleQuote(let m): return "원화 환산 근거가 없습니다: \(m)"
        case .verifyFail: return "계산 검증 실패 — 내보내기 불가"
        case .parserReject(let m): return m
        case .formatUnknown: return "지원 형식이 아닙니다"
        case .parseRow(let m): return m
        case .pdfPassword: return "PDF 비밀번호를 확인하세요"
        case .duplicateFile(let m): return "이미 가져온 파일입니다: \(m)"
        case .storeUnavailable(let m): return "저장소를 열 수 없습니다: \(m)"
        }
    }

    var code: String {
        switch self {
        case .missingFX: return "E_MISSING_FX"
        case .missingMarket: return "E_MISSING_MARKET"
        case .negativeLot: return "E_NEGATIVE_LOT"
        case .unconvertibleQuote: return "E_QUOTE_UNCONVERTIBLE"
        case .verifyFail: return "E_VERIFY_FAIL"
        case .parserReject: return "E_PARSER_REJECT"
        case .formatUnknown: return "E_FORMAT_UNKNOWN"
        case .parseRow: return "E_PARSE_ROW"
        case .pdfPassword: return "E_PDF_PASSWORD"
        case .duplicateFile: return "E_DUPLICATE_FILE"
        case .storeUnavailable: return "E_STORE_UNAVAILABLE"
        }
    }
}
