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
        /// 재고가 모자라 **처분하지 못한 수량**. 검증기가 이 값만큼만 차이를 봐준다.
        var shortfallQty: [String: Decimal] = [:]
        /// 출금은 처리했는데 아직 도착(입금 이벤트)을 지나지 않은 전송의 이전 원가.
        /// 입금 시각에 입고하기 위해 잠시 들고 있는다.
        var pendingArrivals: [EventID: (qty: Decimal, cost: Decimal)] = [:]
        /// 이미 지나간 입금 이벤트. 입금이 출금보다 먼저 기록된 전송을 구분한다.
        var seenDeposits: Set<EventID> = []

        // ── 거주자별 총평균법 (`[영]` §88①) ───────────────────────────────
        //
        // 계정별 장부(`books`)는 **수량과 재고 부족 검증**만 담당한다. 세금에 쓰이는 원가는
        // 아래 풀이 정한다 — 거래소·지갑을 가리지 않고 한 풀로 묶고, 단가는 과세기간이
        // 끝나야 정해진다(§92②4). 그래서 재생 중에는 수량·금액만 모으고, 재생이 끝난 뒤
        // 정산해서 처분 원가를 채운다.
        let pool = ResidentCostPool()
        /// 코인으로 낸 수수료가 **취득원가에 더해지는** 몫 — 단가가 서로를 참조할 수 있어 수렴 계산한다
        var feeIntoAcquisition: [(acquired: String, year: Int, feeAsset: String, feeQty: Decimal)] = []
        /// 직전 `feeCostKRW` 호출이 처분한 코인 수수료. 호출 직후 읽는다
        var lastCryptoFee: (asset: String, qty: Decimal)?
        /// 처분에 붙은 **코인** 부대비용 (원화 수수료는 금액이 그대로라 기록하지 않는다)
        var cryptoFeeOfDisposal: [UUID: (asset: String, qty: Decimal)] = [:]
        /// 재고가 모자라 **일부만 처분된** 건의 실제 수량. 없으면 기록 수량 그대로다
        var effectiveQtyOfDisposal: [UUID: Decimal] = [:]
        /// 전송 상세를 정산 후 다시 채우기 위한 (자산, 연도, 나간 수량, 소실 수량)
        var transferQtyByLink: [UUID: (asset: String, year: Int, principalQty: Decimal, wQty: Decimal, rQty: Decimal, feeQty: Decimal)] = [:]
        func yearOf(_ e: LedgerEvent) -> Int { TaxTime.calendarYearKST(e.timestamp) }

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

        /// 원가법은 **정책**이 정한다 (05-decisions §1.2 「빗썸=이동평균」은 확정 결정).
        ///
        /// 예전에는 계정에 저장된 값을 그대로 썼다. 지금은 계정을 만들 때 올바른 값이 들어가
        /// 결과가 같지만, 저장 값이 한 번 틀어지면 **확정 결정이 조용히 무시된다** (감사 D-8).
        /// 진실 원천을 정책 하나로 좁힌다.
        func costMethod(for accountID: AccountID) -> CostBasisMethod {
            guard let account = accountsByID[accountID] else { return .fifo }
            return policies.costMethodResolver.method(for: account)
        }

        func book(for accountID: AccountID, asset: AssetSymbol) -> AssetBook {
            let key = asset.code
            if books[accountID] == nil { books[accountID] = [:] }
            if let existing = books[accountID]![key] { return existing }
            let method = costMethod(for: accountID)
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
            return qa.isUSDPegged && policies.fxAssumption.usdtEqualsUSD
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
            lastCryptoFee = nil
            guard let feeAmt = e.feeAmount, feeAmt != 0 else { return 0 }
            let amount = Money.abs(feeAmt)
            // 수수료 자산 칸이 비어 있으면 **원화로 본다.**
            //
            // 예전에는 「기초자산으로 냈겠지」라고 넘겨짚었다. 그러면 원화 수수료 1,500원이
            // 코인 1,500개를 처분해 보유·원가가 통째로 틀어졌다 (감사 D-1).
            // 자산 칸이 없는 파일 형식은 원화 마켓이 압도적이고, 코인으로 낸 수수료는
            // 거래소가 반드시 단위를 적는다. 혹시 코인이었다면 원화로 보는 쪽이
            // 필요경비를 과소 계상해 **세금이 커지는 방향**이라 과다 공제 위험도 없다.
            //
            // 수량 규칙 한 벌(`LedgerDelta`)도 `feeAsset == nil` 이면 장부를 건드리지 않으므로
            // 이제 두 곳이 같은 답을 낸다 (감사 D-2 — 정상 자료가 V-QTY-01 로 막히던 원인).
            let asset = e.feeAsset ?? AssetSymbol("KRW")
            if e.feeAsset == nil {
                issues.append(.init(
                    id: "V-FEE-01", severity: "warning",
                    message: "수수료를 어느 자산으로 냈는지 원본에 없습니다 — 원화로 보고 필요경비에 넣었습니다. 코인으로 낸 것이면 그 코인 수량이 줄지 않았으니 원본을 확인하세요",
                    context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp)) \(Money.decimalString(amount))"
                ))
            }
            if let skip = skipAsset, asset == skip { return 0 }
            if asset.isKRW { return amount }
            let b = book(for: e.accountID, asset: asset)
            let out = b.disposeClamped(qty: amount)
            if out.shortfallQty > Money.qtyEpsilon {
                shortfallQty[bookKey(e.accountID, asset), default: 0] += out.shortfallQty
                warnings.append("수수료 자산 \(asset.code) 장부 부족 \(Money.decimalString(out.shortfallQty)) — 그만큼 부대비용에 반영되지 않았습니다")
            }
            // 풀 수량은 **계정 장부 합과 정확히 같아야** 한다. 어긋나면 의제 재기동·보유
            // 스냅샷에서 원가가 새로 생기거나 사라진다. 그래서 장부가 실제로 내보낸 만큼만 뺀다.
            let feeOut = amount - out.shortfallQty
            pool.dispose(asset: asset.code, year: yearOf(e), qty: feeOut)
            lastCryptoFee = (asset: asset.code, qty: feeOut)
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
        func processQuoteLeg(_ e: LedgerEvent, quoteKRW: Decimal?) {
            guard let quote = e.quoteAsset, let quoteQty = e.cryptoQuoteQuantity else { return }
            guard let quoteKRW else {
                // 원화 환산 실패는 `krwFromQuote` 가 이미 Critical(V-FX-01)로 기록했다.
                // 금액(원가·손익)은 근거가 없으므로 만들지 않는다.
                //
                // **다만 수량은 실제로 움직였다.** 예전에는 여기서 그냥 돌아서서, 코인끼리 바꾼
                // 견적자산이 장부에 그대로 남았다 (감사 D-5 — BTC 1개로 USDT를 사도 BTC가 1개).
                // 바이낸스는 원본에 잔고 열이 없어 V-BAL 로도 못 잡고, `shortfallKeys` 때문에
                // V-QTY-01 도 면제되어 **아무도 모르게 보유가 부풀었다.**
                //
                // 그래서 수량만 맞추고, 나간 원가는 「소멸」로 돌린다 (세금이 커지는 방향).
                // 받은 자산의 취득가는 0 이 되므로 나중에 팔 때 전액이 이익으로 잡힌다 —
                // 어느 쪽도 과소 신고가 아니다.
                let b = book(for: e.accountID, asset: quote)
                if e.type == .buy {
                    let out = b.disposeClamped(qty: quoteQty)
                    abandonedTotal += out.costKRW
                    abandonedByYear[TaxTime.calendarYearKST(e.timestamp), default: 0] += out.costKRW
                    pool.abandon(asset: quote.code, year: yearOf(e), qty: quoteQty - out.shortfallQty)
                }
                // 매도(견적자산을 받는 쪽)는 원가 근거가 없어 0원으로 입고한다.
                if e.type == .sell {
                    b.acquire(qty: quoteQty, costKRW: 0)
                    pool.acquire(asset: quote.code, year: yearOf(e), qty: quoteQty, costKRW: 0)
                }
                issues.append(.init(
                    id: "V-FX-01", severity: "critical",
                    message: "\(quote.code) 를 원화로 환산할 근거가 없어 이 거래의 양도가액·취득가를 확정할 수 없습니다 — 수량만 반영하고 원가는 소멸 처리했습니다 (세액이 커지는 방향)",
                    context: "\(e.baseAsset.code)/\(quote.code) \(TaxTime.dayKST(e.timestamp))"
                ))
                return
            }
            let b = book(for: e.accountID, asset: quote)
            switch e.type {
            case .buy:
                let out = b.disposeClamped(qty: quoteQty)
                pool.dispose(asset: quote.code, year: yearOf(e), qty: quoteQty - out.shortfallQty)
                if out.shortfallQty > Money.qtyEpsilon {
                    shortfallQty[bookKey(e.accountID, quote), default: 0] += out.shortfallQty
                    let dust = Money.isDustShortfall(out.shortfallQty, of: quoteQty)
                    issues.append(.init(
                        id: "V-QTY-02", severity: dust ? "warning" : "critical",
                        message: dust
                            ? "사용한 \(quote.code)가 장부보다 \(Money.decimalString(out.shortfallQty)) 많습니다 (거래소 반올림 수준)"
                            : "보유한 \(quote.code)보다 많이 사용한 거래입니다 (부족 \(Money.decimalString(out.shortfallQty)) \(quote.code)) — ① 이자·리베이트·에어드롭처럼 거래·입출금이 아닌 방식으로 들어온 기록이 빠졌거나 ② 이 계정의 거래내역 시작 전 보유분이 있습니다. 바이낸스는 「Transaction History」, OKX는 「Funding History」를 함께 넣고, 그래도 남으면 더 이전 기간 원본을 받으세요",
                        context: "\(e.baseAsset.code)/\(quote.code) \(TaxTime.dayKST(e.timestamp)) \(e.rawRef ?? e.id.raw.uuidString)"
                    ))
                }
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
                    method: costMethod(for: e.accountID),
                    taxYear: TaxTime.calendarYearKST(e.timestamp),
                    fxRateUsed: fxResolvedByDay[TaxTime.dayKST(e.timestamp)]?.rate,
                    fxSourceDate: fxResolvedByDay[TaxTime.dayKST(e.timestamp)]?.sourceDate,
                    deemedApplied: deemedKeys.contains(bookKey(e.accountID, quote))
                ))
                if out.shortfallQty > 0, let last = disposals.last {
                    effectiveQtyOfDisposal[last.id] = quoteQty - out.shortfallQty
                }
            case .sell:
                b.acquire(qty: quoteQty, costKRW: quoteKRW)
                pool.acquire(asset: quote.code, year: yearOf(e), qty: quoteQty, costKRW: quoteKRW)
            default:
                break
            }
        }

        func process(_ list: [LedgerEvent]) {
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
                    processQuoteLeg(e, quoteKRW: quoteKRW)
                    // 환산 불가 — 원가 0으로 두고 Critical 이슈로 보고 (계산은 계속)
                    var cost = quoteKRW ?? 0
                    // base 수수료는 수량에 반영했으므로 금액에서 제외
                    let buyFeeCost = feeCostKRW(e, skipAsset: e.baseAsset)
                    let buyCryptoFee = lastCryptoFee
                    cost += buyFeeCost
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
                    // 풀에는 원화로 확정된 몫만 넣는다. 코인으로 낸 수수료 몫은 그 코인의
                    // 단가가 정해져야 알 수 있어 따로 적어 두고 정산 때 더한다.
                    // 원화 수수료는 그 자리에서 원가가 확정된다 — 풀에 함께 넣지 않으면 사라진다.
                    // 코인 수수료는 그 코인의 단가가 정해져야 알 수 있어 아래에 적어 둔다.
                    pool.acquire(asset: e.baseAsset.code, year: yearOf(e), qty: qty,
                                 costKRW: (quoteKRW ?? 0) + (buyCryptoFee == nil ? buyFeeCost : 0))
                    if let cf = buyCryptoFee {
                        feeIntoAcquisition.append((acquired: e.baseAsset.code, year: yearOf(e), feeAsset: cf.asset, feeQty: cf.qty))
                    }

                case .sell:
                    let qty = Money.abs(e.quantity)
                    let b = book(for: e.accountID, asset: e.baseAsset)
                    let costBefore = b.totalCost
                    let out = b.disposeClamped(qty: qty)
                    pool.dispose(asset: e.baseAsset.code, year: yearOf(e), qty: qty - out.shortfallQty)
                    let sellEffectiveQty = qty - out.shortfallQty
                    if out.shortfallQty > Money.qtyEpsilon {
                        shortfallQty[bookKey(e.accountID, e.baseAsset), default: 0] += out.shortfallQty
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
                    var proceeds: Decimal = 0
                    var usedFX: FXResolvedRate?
                    var quoteKRW: Decimal?
                    if let krw = e.quoteAmountKRW {
                        proceeds = Money.abs(krw)
                        quoteKRW = proceeds
                    } else if let conv = krwFromQuote(e, quote: quoteAmount(e), purpose: "양도가액") {
                        proceeds = conv.krw
                        quoteKRW = conv.krw
                        usedFX = conv.fx
                    }
                    processQuoteLeg(e, quoteKRW: quoteKRW)

                    // **수수료 처리는 과세 여부보다 앞선다.** 수수료로 나간 코인은 과세 시작 전에도
                    // 지갑에서 실제로 빠지므로, 여기서 장부에 반영하지 않으면 2026-12-31 보유 수량이
                    // 부풀고 의제취득가가 틀어진다 (검증기 V-QTY-01·V-DEM-01 과도 어긋난다).
                    //
                    // 매도 수수료가 기초자산이면 체결 수량과 **별도로** 빠진다 (매수는 받는 수량에서 차감되므로 반대다).
                    // 원본이 이미 순액인 판본(OKX Balance Change)만 중복 차감을 피해 건너뛴다.
                    let feeSkip: AssetSymbol? = e.quantityIsNetOfFee ? e.baseAsset : nil
                    let fees = feeCostKRW(e, skipAsset: feeSkip)
                    let sellCryptoFee = lastCryptoFee

                    // 과세 시작(2027) 전 처분도 기록한다. 신고 대상은 아니지만, 기록하지 않으면
                    // 2027 이 오기 전에는 자기 손익을 볼 방법이 아예 없다 (리포트가 늘 0원).
                    // `taxYear` 로 연도가 구분되고, 집계기가 과세연도에는 2027 이후만 담는다.
                    let pnl = proceeds - out.costKRW - fees
                    let method = costMethod(for: e.accountID)
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
                    if let last = disposals.last {
                        if let cf = sellCryptoFee { cryptoFeeOfDisposal[last.id] = cf }
                        if sellEffectiveQty != qty { effectiveQtyOfDisposal[last.id] = sellEffectiveQty }
                    }

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
                    pool.acquire(asset: e.baseAsset.code, year: yearOf(e), qty: Money.abs(e.quantity), costKRW: 0)

                case .withdrawal:
                    if e.baseAsset.isKRW { continue }
                    let wQty = Money.abs(e.quantity)
                    let b = book(for: e.accountID, asset: e.baseAsset)
                    // 원금 처분과 수수료 처분은 **연결 여부와 무관하게 똑같다.** 갈래마다 따로 적으면
                    // 한쪽만 고쳐지고 다른 쪽이 남는다 — 실제로 그렇게 새어 나갔다 (감사 D4-1).
                    let out = b.disposeClamped(qty: wQty)
                    if out.shortfallQty > Money.qtyEpsilon {
                        shortfallQty[bookKey(e.accountID, e.baseAsset), default: 0] += out.shortfallQty
                        let dust = Money.isDustShortfall(out.shortfallQty, of: wQty)
                        issues.append(.init(
                            id: "V-QTY-02", severity: dust ? "warning" : "critical",
                            message: dust
                                ? "출금 수량이 장부보다 \(Money.decimalString(out.shortfallQty)) \(e.baseAsset.code) 많습니다 (거래소 반올림 수준)"
                                : "보유 수량보다 많은 출금입니다 (부족 \(Money.decimalString(out.shortfallQty)) \(e.baseAsset.code)) — ① 이자·리베이트·에어드롭처럼 거래·입출금이 아닌 방식으로 들어온 기록이 빠졌거나 ② 이 계정의 거래내역 시작 전 보유분이 있습니다. 바이낸스는 「Transaction History」, OKX는 「Funding History」를 함께 넣고, 그래도 남으면 더 이전 기간 원본을 받으세요",
                            context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp)) \(e.rawRef ?? e.id.raw.uuidString)"
                        ))
                    }
                    // 출금 수수료가 원금과 별도로 지갑에서 빠지는 경우(바이낸스 Withdraw).
                    // **어느 자산으로 냈는지는 규칙 한 벌이 정한다** — 원화나 제3코인으로 적혀 있으면
                    // 이 코인은 줄지 않는다. 예전에는 연결 안 된 출금에서 그 조건이 빠져 있었다.
                    var explicitFee: Decimal = 0
                    var explicitFeeQty: Decimal = 0
                    if let feeQty = LedgerDelta.withdrawalFeeQuantity(e) {
                        let feeOut = b.disposeClamped(qty: feeQty)
                        explicitFee = feeOut.costKRW
                        explicitFeeQty = feeQty - feeOut.shortfallQty
                        if feeOut.shortfallQty > Money.qtyEpsilon {
                            // 여기서 기록하지 않으면 검증기가 원인 불명의 V-QTY-01 로만 알려
                            // 사용자가 무엇을 해야 하는지 모른다.
                            shortfallQty[bookKey(e.accountID, e.baseAsset), default: 0] += feeOut.shortfallQty
                            let dust = Money.isDustShortfall(feeOut.shortfallQty, of: feeQty)
                            issues.append(.init(
                                id: "V-QTY-02", severity: dust ? "warning" : "critical",
                                message: dust
                                    ? "출금 수수료가 장부보다 \(Money.decimalString(feeOut.shortfallQty)) \(e.baseAsset.code) 많습니다 (거래소 반올림 수준)"
                                    : "출금 수수료를 뺄 \(e.baseAsset.code)가 부족합니다 (부족 \(Money.decimalString(feeOut.shortfallQty))) — 이 계정의 거래내역 시작 전 보유분이 있거나 내역 일부가 빠졌을 수 있습니다",
                                context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp)) \(e.rawRef ?? e.id.raw.uuidString)"
                            ))
                        }
                    }
                    if let link = linkByFrom[e.id], let dep = eventsByID[link.toEventID] {
                        let rQty = Money.abs(dep.quantity)
                        guard wQty > 0 else { continue }
                        let result = policies.transferCost.apply(
                            outboundCostKRW: out.costKRW,
                            withdrawnQty: wQty,
                            receivedQty: rQty,
                            explicitFeeCostKRW: explicitFee
                        )
                        // 자기 계정 간 이동은 **같은 풀 안의 이동**이라 원가가 움직이지 않는다.
                        // 네트워크 수수료로 실제 사라진 수량만 뺀다 (백서 U-10 · Q2 = 폐기).
                        // 장부의 순변화 = −(실제 나간 수량) + 도착 수량. 풀도 똑같이 움직여야 한다.
                        let poolOut = (wQty - out.shortfallQty) + explicitFeeQty
                        if poolOut > rQty {
                            pool.abandon(asset: e.baseAsset.code, year: yearOf(e), qty: poolOut - rQty)
                        } else if rQty > poolOut {
                            pool.acquire(asset: e.baseAsset.code, year: yearOf(e), qty: rQty - poolOut, costKRW: 0)
                        }
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
                        transferQtyByLink[link.id.raw] = (
                            asset: e.baseAsset.code, year: yearOf(e),
                            principalQty: wQty - out.shortfallQty, wQty: wQty,
                            rQty: rQty, feeQty: explicitFeeQty
                        )
                        transferDetails.append(TransferCostDetail(
                            linkID: link.id,
                            outboundCostKRW: out.costKRW,
                            transferredCostKRW: result.transferredCostKRW,
                            abandonedCostKRW: result.abandonedCostKRW,
                            deductibleExpenseKRW: result.deductibleExpenseKRW,
                            ratio: Money.clamp(rQty / wQty, 0, 1)
                        ))
                    } else {
                        // 원금 + 별도 출금 수수료의 원가가 함께 소멸한다
                        pool.abandon(asset: e.baseAsset.code, year: yearOf(e), qty: (wQty - out.shortfallQty) + explicitFeeQty)
                        abandonedTotal += out.costKRW + explicitFee
                        abandonedByYear[TaxTime.calendarYearKST(e.timestamp), default: 0] += out.costKRW + explicitFee
                        warnings.append("미매칭 출금 원가 소멸: \(e.baseAsset.code) \(Money.decimalString(wQty))")
                        // 사용자가 「잘못 보내 소멸」로 이미 판단한 건은 처리 결과가 같으므로
                        // 「연결하세요」를 다시 재촉하지 않는다. 원가가 사라졌다는 사실만 남긴다.
                        issues.append(.init(
                            id: "V-QTY-04", severity: "warning",
                            message: e.lostForever
                                ? "잘못 보내 소멸로 지정한 출금입니다 — 취득원가는 사라지고 손실로 공제되지 않습니다 (세액이 커지는 방향)"
                                : "연결되지 않은 출금의 취득원가는 소멸 처리됩니다 (세액이 커지는 방향) — 다른 거래소로 보낸 것이면 상대 입금을 연결하고, 개인지갑으로 보낸 것이면 「전송 연결」 화면에서 개인지갑으로 지정하세요 (지정하지 않으면 보유 현황에서도 빠집니다)",
                            context: "\(e.baseAsset.code) \(TaxTime.dayKST(e.timestamp))"
                        ))
                    }

                case .transferInternal:
                    // 같은 계정 안의 지갑 이동. 계정×자산 단위 단일 장부이므로 총원가·수량 불변 (LOCK v1).
                    break

                case .income:
                    if !e.baseAsset.isKRW {
                        book(for: e.accountID, asset: e.baseAsset).acquire(qty: Money.abs(e.quantity), costKRW: 0)
                        pool.acquire(asset: e.baseAsset.code, year: yearOf(e), qty: Money.abs(e.quantity), costKRW: 0)
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

        // 과세기간 목록. 총평균법은 **직전 해 기말이 다음 해 기초**라 거래가 없는 해도 건너뛰면 안 된다.
        let eventYears = Set(sorted.map { yearOf($0) })
        let preYears: [Int] = {
            guard let lo = eventYears.filter({ $0 < TaxTime.taxStartYear }).min() else { return [] }
            // 2026 까지 이어 붙인다 — 의제취득가는 「2026 말 단가」와 시가를 비교한다
            return Array(lo...(TaxTime.taxStartYear - 1))
        }()
        let postYears: [Int] = {
            let hi = eventYears.filter { $0 >= TaxTime.taxStartYear }.max()
            // **2027 이후 거래가 한 건도 없어도 그 해를 정산한다.**
            //
            // 의제취득가 재기동(§37⑤)은 2027 기초를 다시 세우는데, 그 해를 정산하지 않으면
            // 재기동한 값을 **아무도 읽지 않는다** — 보유 스냅샷이 재기동 전 단가를 그대로 쓴다.
            // 지금은 모든 이용자의 자료가 2026 이전이라 이 경우가 기본이다.
            guard hi != nil || !preYears.isEmpty else { return [] }
            return Array(TaxTime.taxStartYear...max(TaxTime.taxStartYear, hi ?? TaxTime.taxStartYear))
        }()

        /// 코인으로 낸 수수료가 취득원가에 더해지면 **단가가 서로를 참조할 수 있다**
        /// (BNB 로 BTC 수수료를 내고 BTC 로 BNB 수수료를 내는 경우). 돌려서 수렴시킨다.
        ///
        /// 예전에는 **세 번으로 고정**하고 「수수료는 거래액의 0.1% 수준이라 두세 번이면
        /// 1원 미만으로 붙는다」고 적어 두었다. 그 전제가 깨지는 자료가 있다 — 수수료가
        /// 거래액의 몇 %인 소액 거래에서 실측 잔차 **1.37원**이 남았다 (7차 감사 M-1).
        /// 몇 번이면 되는지는 자료가 정하므로, **값이 굳을 때까지** 돌리고 상한에서 멈춘다.
        func settleConverging(_ years: [Int]) {
            guard !years.isEmpty else { return }
            let target = Set(years)
            // 1원의 1만분의 1. 이보다 작게 움직이면 어떤 끝수 처리에도 영향이 없다.
            let tolerance = Decimal(string: "0.0001")!
            var previous: [String: [Int: Decimal]]?
            for _ in 0..<12 {
                var derived: [String: [Int: Decimal]] = [:]
                for f in feeIntoAcquisition where target.contains(f.year) {
                    let unit = pool.unitCost(asset: f.feeAsset, year: f.year) ?? 0
                    derived[f.acquired, default: [:]][f.year, default: 0] += unit * f.feeQty
                }
                for (asset, byYear) in derived {
                    for (year, cost) in byYear {
                        pool.setDerivedAcquisitionCost(asset: asset, year: year, costKRW: cost)
                    }
                }
                pool.settle(years: years)
                // 키 집합은 `feeIntoAcquisition` 이 정해 매 회 같다 — 값만 비교하면 된다.
                if let prev = previous, derived.allSatisfy({ asset, byYear in
                    byYear.allSatisfy { year, cost in
                        Money.abs(cost - (prev[asset]?[year] ?? 0)) <= tolerance
                    }
                }) {
                    break
                }
                previous = derived
            }
        }

        process(pass1)
        // 의제취득가 비교에 「2026 말 총평균단가」가 필요하므로 여기서 한 번 정산한다
        settleConverging(preYears)

        // 의제 스냅샷은 **여기까지의** 재생 결과다. 검증기(V-DEM-01)가 그 수량을 규칙과 대조할 때
        // 봐줄 수 있는 부족량도 여기까지 것뿐이다 — 전체 기간 부족량을 쓰면 2027 이후에 난 부족까지
        // 봐주게 되어 스냅샷의 진짜 차이를 놓친다.
        let preTaxShortfallQty = shortfallQty

        // 과세 시작 시점에 「이동 중」인 전송은 **어느 계정 장부에도 없다.**
        //
        // 12/30 에 거래소에서 보내 1/2 에 지갑에 도착하면, 보낸 계정에서는 이미 빠졌고
        // 받는 계정에는 아직 안 들어와 두 장부 어디에도 없다. 그런데 **코인은 계속 내 것이다** —
        // 체인 위에 떠 있을 뿐이다. `[법]` §37⑤ 는 「2027년 1월 1일 전에 이미 **보유하고 있던**」
        // 이라고만 하고, 어느 거래소 파일에 찍혀 있는지는 요건이 아니다.
        //
        // 예전에는 이 수량을 빼고 2027 기초를 못박았다. 그러면 도착한 뒤에도 풀에는 영영
        // 안 들어와, 그 자산 **전체**의 원가가 배분 비율만큼 깎였다 (7차 감사 D-1 —
        // BTC 2개 중 1개가 이동 중이면 필요경비가 2억이 아니라 1억이 되어 세금이 2,200만 원 늘었다).
        // 그래서 **도착 계정 몫으로 세어** 의제취득가 대상에 넣는다.
        var inFlightQtyByKey: [String: Decimal] = [:]
        var inFlightQtyByAsset: [String: Decimal] = [:]
        var inFlightTargets: [(accID: AccountID, code: String, qty: Decimal)] = []
        for eventID in pendingArrivals.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            guard let pending = pendingArrivals[eventID], let dep = eventsByID[eventID] else { continue }
            guard pending.qty > Money.qtyEpsilon else { continue }
            inFlightQtyByAsset[dep.baseAsset.code, default: 0] += pending.qty
            inFlightQtyByKey[bookKey(dep.accountID, dep.baseAsset), default: 0] += pending.qty
            inFlightTargets.append((accID: dep.accountID, code: dep.baseAsset.code, qty: pending.qty))
        }
        if !pendingArrivals.isEmpty {
            issues.append(.init(
                id: "V-DEM-05", severity: "warning",
                message: "과세 시작 시점(2027-01-01 0시)에 아직 도착하지 않은 전송이 \(pendingArrivals.count)건 있습니다 — 그 수량도 보유로 보아 의제취득가에 넣고 **도착할 계정 몫**으로 셌습니다. 실제로 도착하지 않은 전송이면 「전송 연결」에서 해제하세요",
                context: nil
            ))
        }

        // --- 의제취득가 적용 (2027-01-01 0시 기준) ---
        //
        // `[법]` §37⑤ — 2027-01-01 전에 보유하던 가상자산의 취득가액은 「2026-12-31 당시의
        // 시가」와 실제 취득가액 중 **큰 금액**으로 한다.
        //
        // 총평균법에서는 비교 대상이 **자산별 거주자 단가 하나**다. 계정마다·매입 건마다 따로
        // 비교할 대상이 존재하지 않는다 (백서 U-09 · 작업문서 Q1 결정).
        var deemedPositions: [DeemedPosition] = []
        // 합산 순서를 고정한다 — 딕셔너리 순회 순서에 기대면 같은 입력에서 다른 값이 나온다 (V-RE-01)
        var qtyByAsset: [String: Decimal] = [:]
        for accID in books.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            guard let map = books[accID] else { continue }
            for code in map.keys.sorted() {
                guard let b = map[code], b.quantity > Money.qtyEpsilon else { continue }
                qtyByAsset[code, default: 0] += b.quantity
            }
        }
        // 이동 중인 수량도 보유다 (위 참조). 이걸 더해야 풀 자신의 2026 기말과 같아진다.
        for code in inFlightQtyByAsset.keys.sorted() {
            qtyByAsset[code, default: 0] += inFlightQtyByAsset[code] ?? 0
        }
        var deemedUnitByAsset: [String: Decimal] = [:]
        var bookUnitByAsset: [String: Decimal] = [:]
        for code in qtyByAsset.keys.sorted() {
            let bookUnit = pool.unitCost(asset: code, year: TaxTime.taxStartYear - 1) ?? 0
            bookUnitByAsset[code] = bookUnit
            let market = marketPrices[code]
            if market == nil {
                missingMarket.insert(code)
                let pending = TaxTime.isBeforeTaxStart()
                issues.append(.init(
                    id: "V-DEM-04", severity: pending ? "warning" : "critical",
                    message: pending
                        ? "2027-01-01 0시 시가는 그날이 지나야 나옵니다 — 지금은 실제 산 값으로 계산했습니다 (그때 넣으면 취득가가 올라가 세금이 줄 수 있습니다)"
                        : "2027-01-01 0시 시가가 없어 의제취득가를 확정할 수 없습니다",
                    context: code
                ))
            }
            guard let unit = policies.deemed.deemedUnit(bookUnit: bookUnit, marketUnit: market) else { continue }
            deemedUnitByAsset[code] = unit
            // 풀의 2027 기초를 못박는다. 시가가 없어 의제를 적용하지 못한 자산은
            // 그대로 2026 기말이 이어진다 (실제 산 값으로 계산).
            let total = qtyByAsset[code] ?? 0
            // 못박는 기초 수량은 **풀 자신의 직전 해 기말 수량과 같아야 한다.**
            //
            // 다르면 그 차이만큼 원가가 통째로 생기거나 사라진다 — 그리고 모자란 쪽이면
            // 배분 비율(`ResidentCostPool.outflowScales`)이 걸려 **그 자산 전체**의 필요경비가
            // 깎인다. 7차 감사 D-1 이 정확히 이 모양이었는데, 계정별 검증(V-QTY-01)은
            // 계정 합계만 보므로 통과했다. 여기서만 보인다.
            let poolClosing = pool.closing(asset: code, year: TaxTime.taxStartYear - 1)?.qty ?? 0
            if Money.abs(total - poolClosing) > Money.qtyEpsilon {
                issues.append(.init(
                    id: "V-DEM-07", severity: "critical",
                    message: "의제취득가를 적용할 \(code) 수량이 총평균법 장부의 \(TaxTime.taxStartYear - 1)년 기말 수량과 다릅니다 (스냅샷 \(Money.decimalString(total)) / 장부 \(Money.decimalString(poolClosing))) — 이 상태로는 취득가액 전체가 틀어집니다",
                    context: code
                ))
            }
            pool.setOpening(asset: code, year: TaxTime.taxStartYear, qty: total, costKRW: total * unit)
        }

        // 스냅샷은 **계정별로** 발행한다 — 검증기(V-DEM-01)가 계정별 수량을 규칙과 대조한다.
        // 단가는 전부 자산 단위 값이라 같은 자산이면 계정이 달라도 같다.
        //
        // 이동 중인 전송은 **도착할 계정 몫**으로 합친다. 그 계정에 같은 자산이 이미 있으면
        // 한 줄로 합쳐야 한다 — 같은 (계정, 자산)으로 두 줄을 내면 검증기가 각 줄을 같은
        // 기대값과 비교해 정상 계산을 Critical 로 막는다.
        let deemedTargets = books
            .flatMap { accID, map in map.map { (accID, $0.key, $0.value) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.raw.uuidString < rhs.0.raw.uuidString
            }
        var snapshotQty: [String: Decimal] = [:]
        var snapshotOwner: [String: (accID: AccountID, code: String)] = [:]
        for (accID, assetCode, b) in deemedTargets {
            guard b.quantity > Money.qtyEpsilon else { continue }
            guard let unit = deemedUnitByAsset[assetCode] else { continue }
            let key = bookKey(accID, AssetSymbol(assetCode))
            snapshotQty[key, default: 0] += b.quantity
            snapshotOwner[key] = (accID, assetCode)
            // 계정 장부는 수량만 담당하지만, 재기동해 두어야 이후 재고 검증이 맞는다
            b.replaceLots([(qty: b.quantity, unitCost: unit)])
        }
        for t in inFlightTargets where deemedUnitByAsset[t.code] != nil {
            let key = bookKey(t.accID, AssetSymbol(t.code))
            snapshotQty[key, default: 0] += t.qty
            snapshotOwner[key] = (t.accID, t.code)
        }
        // 자산 → 계정 순서를 유지한다 (리포트·CSV 의 표 순서가 실행마다 바뀌면 안 된다)
        let snapshotKeys = snapshotQty.keys.sorted { lhs, rhs in
            let l = snapshotOwner[lhs]!, r = snapshotOwner[rhs]!
            if l.code != r.code { return l.code < r.code }
            return l.accID.raw.uuidString < r.accID.raw.uuidString
        }
        for key in snapshotKeys {
            guard let owner = snapshotOwner[key], let qty = snapshotQty[key],
                  let unit = deemedUnitByAsset[owner.code] else { continue }
            let bookUnit = bookUnitByAsset[owner.code] ?? 0
            deemedPositions.append(DeemedPosition(
                accountID: owner.accID,
                asset: AssetSymbol(owner.code),
                quantity: qty,
                bookUnitKRW: bookUnit,
                marketUnitKRW: marketPrices[owner.code],
                deemedUnitKRW: unit,
                reason: unit > bookUnit ? "market" : "actual",
                basisMode: policies.deemed.mode.rawValue,
                lotCount: 1
            ))
            deemedKeys.insert(key)
        }

        process(pass2)

        // 모든 확정 링크의 입금은 계산 대상에 있어야 한다(링크 채택 단계에서 확인). 그래도 남았다면
        // 원가가 어디에도 입고되지 않은 것이므로 조용히 넘기지 않는다.
        if !pendingArrivals.isEmpty {
            issues.append(.init(
                id: "V-QTY-03", severity: "critical",
                message: "확정 전송 \(pendingArrivals.count)건의 도착 입금이 처리되지 않아 취득원가가 입고되지 않았습니다 — 링크를 확인하세요",
                context: nil
            ))
        }

        // --- 연도별 총평균단가 확정 (2027 이후) ---
        settleConverging(postYears)

        // --- 처분 원가를 풀에서 채운다 ---
        //
        // 재생 중에는 수량·양도가액만 확정할 수 있었다. 총평균단가는 과세기간이 끝나야
        // 정해지므로(§92②4) 여기서 되돌아가 필요경비를 채운다.
        for i in disposals.indices {
            let d = disposals[i]
            let effQty = effectiveQtyOfDisposal[d.id] ?? d.quantity
            // 수량 0 처분은 원가도 0 이다 — 단가를 물을 필요가 없다.
            // (수량 0 거래가 들어오면 풀에 그 자산 자체가 없어 단가가 nil 이 된다)
            if Money.isApproxZero(effQty) {
                disposals[i].costKRW = 0
                disposals[i].feesKRW = 0
                disposals[i].pnlKRW = d.proceedsKRW
                disposals[i].method = .totalAverage
                continue
            }
            guard let cost = pool.costOfDisposal(asset: d.asset.code, year: d.taxYear, qty: effQty) else {
                issues.append(.init(
                    id: "V-COST-01", severity: "critical",
                    message: "총평균단가를 확정하지 못해 취득가액을 채우지 못했습니다",
                    context: "\(d.asset.code) \(d.taxYear)"
                ))
                continue
            }
            // 코인으로 낸 부대비용도 그 코인의 그해 단가로 다시 잡는다 (원화 수수료는 그대로)
            var fees = d.feesKRW
            if let cf = cryptoFeeOfDisposal[d.id] {
                fees = (pool.unitCost(asset: cf.asset, year: d.taxYear) ?? 0) * cf.qty
            }
            disposals[i].costKRW = cost
            disposals[i].feesKRW = fees
            disposals[i].pnlKRW = d.proceedsKRW - cost - fees
            disposals[i].method = .totalAverage
        }

        // --- 전송 상세도 풀 단가 기준으로 ---
        // 재생 중에 넣은 값은 계정 장부 원가라 총평균법과 다르다. 안 고치면 리포트의
        // 「전송 소실 원가」가 합계와 어긋난다.
        // **같은 정책을 다시 태운다.** 여기서 비율을 직접 계산하면 검증기(V-COST-02)가 보는
        // 「이전 원가 = 나간 원가 × 도착비율」 규칙과 어긋난다 — 정상 계산이 Critical 로 막힌다.
        for i in transferDetails.indices {
            guard let q = transferQtyByLink[transferDetails[i].linkID.raw],
                  let unit = pool.unitCost(asset: q.asset, year: q.year) else { continue }
            let result = policies.transferCost.apply(
                outboundCostKRW: unit * q.principalQty,
                withdrawnQty: q.wQty,
                receivedQty: q.rQty,
                explicitFeeCostKRW: unit * q.feeQty
            )
            transferDetails[i].outboundCostKRW = unit * q.principalQty
            transferDetails[i].transferredCostKRW = result.transferredCostKRW
            transferDetails[i].abandonedCostKRW = result.abandonedCostKRW
            transferDetails[i].deductibleExpenseKRW = result.deductibleExpenseKRW
        }

        // --- 소실 원가도 풀 단가 기준으로 ---
        // 재생 중에 더한 값은 계정 장부 원가라 총평균법과 다르다. 통째로 교체한다.
        let poolAbandoned = pool.abandonedCostByYear()
        abandonedByYear = poolAbandoned
        abandonedTotal = poolAbandoned.values.reduce(0, +)

        // --- 풀이 본 수량 부족 ---
        // 계정별 검증(V-QTY-02)과 달리 **거주자 전체**로 봐도 모자란 경우다.
        // 총평균법에서는 계정 하나가 빠져도 전체 단가가 틀어지므로 따로 알린다.
        for w in pool.settleWarnings {
            issues.append(.init(
                id: "V-QTY-05", severity: "warning",
                message: "가진 것보다 많이 처분했습니다 (\(w.year)년 \(w.asset) 부족 \(Money.decimalString(w.shortQty))) — 거래소·지갑 자료가 빠지면 총평균법에서는 그 계정만이 아니라 **전체 세액**이 틀어집니다",
                context: "\(w.asset) \(w.year)"
            ))
        }

        // --- 보유 스냅샷 (결정적 순서) ---
        // 단가·총원가는 **마지막 과세기간의 총평균단가** 기준이다 (계정 장부 원가가 아니다).
        let lastSettledYear = postYears.last ?? preYears.last
        var rows: [HoldingsRow] = []
        var aggMap: [String: (qty: Decimal, cost: Decimal)] = [:]
        for accID in books.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
            guard let assetMap = books[accID] else { continue }
            for code in assetMap.keys.sorted() {
                guard let b = assetMap[code], b.quantity > Money.qtyEpsilon else { continue }
                let unit = lastSettledYear.flatMap { pool.unitCost(asset: code, year: $0) } ?? 0
                rows.append(HoldingsRow(
                    accountID: accID,
                    asset: AssetSymbol(code),
                    quantity: b.quantity,
                    averageUnitKRW: unit,
                    totalCostKRW: unit * b.quantity,
                    method: .totalAverage
                ))
                let prev = aggMap[code] ?? (0, 0)
                aggMap[code] = (prev.qty + b.quantity, prev.cost + unit * b.quantity)
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
            shortfallQtyByKey: shortfallQty,
            preTaxShortfallQtyByKey: preTaxShortfallQty,
            inFlightQtyByKey: inFlightQtyByKey
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
