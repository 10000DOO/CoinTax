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
        var warnings: [String] = []
        var transferDetails: [TransferCostDetail] = []
        var missingMarket: Set<String> = []
        var missingFX: Set<String> = []
        var fxResolutions: [FXResolvedRate] = []
        var fxResolvedByDay: [String: FXResolvedRate] = [:]

        let confirmed = links.filter { $0.status == .confirmed }
        let linkByFrom = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.fromEventID, $0) })
        let linkedAsTo = Set(confirmed.map(\.toEventID))
        let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })

        let sorted = events
            .filter { $0.type != .ignored }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id.raw.uuidString < $1.id.raw.uuidString
            }

        let tTax = TaxTime.taxStartDate
        let pass1 = sorted.filter { $0.timestamp < tTax }
        let pass2 = sorted.filter { $0.timestamp >= tTax }

        func book(for accountID: AccountID, asset: AssetSymbol) -> AssetBook {
            let key = asset.code
            if books[accountID] == nil { books[accountID] = [:] }
            if let existing = books[accountID]![key] { return existing }
            let method = accountsByID[accountID]?.costMethod ?? .fifo
            let b = AssetBookFactory.make(method)
            books[accountID]![key] = b
            return b
        }

        func feeKRW(_ e: LedgerEvent) -> Decimal {
            guard let feeAmt = e.feeAmount, feeAmt != 0 else { return 0 }
            let asset = e.feeAsset ?? e.baseAsset
            if asset.isKRW { return Money.abs(feeAmt) }
            if asset.isUSDTish {
                if let dayRate = rateFor(e.timestamp) {
                    return Money.abs(feeAmt) * dayRate
                }
                missingFX.insert(TaxTime.dayKST(e.timestamp))
                return 0
            }
            // v1: if fee in base, treated via net qty path; other assets warn
            warnings.append("수수료 자산 \(asset.code) 환산 근사 생략 (\(e.id.raw))")
            return 0
        }

        /// 국세청 서삼46015-11986 취지: 미고시일(공휴일 등) → 직전 고시 기준환율
        func rateFor(_ date: Date) -> Decimal? {
            let day = TaxTime.dayKST(date)
            if let cached = fxResolvedByDay[day] {
                return cached.rate
            }
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
            return resolved.rate
        }

        func costKRWForBuy(_ e: LedgerEvent) throws -> Decimal {
            if let krw = e.quoteAmountKRW { return Money.abs(krw) }
            let quote = e.quoteAmount ?? {
                if let p = e.price { return Money.abs(e.quantity) * p }
                return Decimal(0)
            }()
            let qa = e.quoteAsset
            if qa?.isKRW == true {
                return Money.abs(quote) + feeKRW(e)
            }
            // USDT/USD path
            if qa == nil || qa!.isUSDTish || policies.fxAssumption.usdtEqualsUSD {
                guard let rate = rateFor(e.timestamp) else {
                    missingFX.insert(TaxTime.dayKST(e.timestamp))
                    throw CoinTaxError.missingFX(days: [TaxTime.dayKST(e.timestamp)])
                }
                return Money.abs(quote) * rate + feeKRW(e)
            }
            missingFX.insert(TaxTime.dayKST(e.timestamp))
            throw CoinTaxError.missingFX(days: [TaxTime.dayKST(e.timestamp)])
        }

        func sellProceedsKRW(_ e: LedgerEvent) throws -> Decimal {
            if let krw = e.quoteAmountKRW { return Money.abs(krw) }
            let quote = e.quoteAmount ?? {
                if let p = e.price { return Money.abs(e.quantity) * p }
                return Decimal(0)
            }()
            if e.quoteAsset?.isKRW == true {
                return Money.abs(quote)
            }
            guard let rate = rateFor(e.timestamp) else {
                missingFX.insert(TaxTime.dayKST(e.timestamp))
                throw CoinTaxError.missingFX(days: [TaxTime.dayKST(e.timestamp)])
            }
            return Money.abs(quote) * rate
        }

        func process(_ list: [LedgerEvent], recordTaxDisposals: Bool) throws {
            for e in list {
                switch e.type {
                case .buy:
                    var qty = Money.abs(e.quantity)
                    // Fee in base: net acquire
                    if let fa = e.feeAsset, fa == e.baseAsset, let fee = e.feeAmount {
                        qty = max(0, qty - Money.abs(fee))
                    }
                    let cost = try costKRWForBuy(e)
                    book(for: e.accountID, asset: e.baseAsset).acquire(qty: qty, costKRW: cost)

                case .sell:
                    let qty = Money.abs(e.quantity)
                    let cost = try book(for: e.accountID, asset: e.baseAsset).dispose(qty: qty)
                    let proceeds = try sellProceedsKRW(e)
                    let fees = feeKRW(e)
                    let pnl = proceeds - cost - fees
                    if recordTaxDisposals && e.timestamp >= tTax {
                        let method = accountsByID[e.accountID]?.costMethod ?? .fifo
                        disposals.append(DisposalRecord(
                            id: UUID(),
                            eventID: e.id,
                            timestamp: e.timestamp,
                            accountID: e.accountID,
                            asset: e.baseAsset,
                            quantity: qty,
                            proceedsKRW: proceeds,
                            costKRW: cost,
                            feesKRW: fees,
                            pnlKRW: pnl,
                            method: method,
                            taxYear: TaxTime.calendarYearKST(e.timestamp)
                        ))
                    }

                case .deposit:
                    if linkedAsTo.contains(e.id) {
                        // cost acquired at withdrawal processing
                        continue
                    }
                    if e.baseAsset.isKRW { continue }
                    // external unlinked deposit: cost 0 + warning
                    warnings.append("미매칭 입금 원가 0: \(e.baseAsset.code) \(e.quantity)")
                    book(for: e.accountID, asset: e.baseAsset).acquire(qty: Money.abs(e.quantity), costKRW: 0)

                case .withdrawal:
                    if e.baseAsset.isKRW { continue }
                    let wQty = Money.abs(e.quantity)
                    if let link = linkByFrom[e.id], let dep = eventsByID[link.toEventID] {
                        let rQty = Money.abs(dep.quantity)
                        let outboundCost = try book(for: e.accountID, asset: e.baseAsset).dispose(qty: wQty)
                        // explicit fee cost if fee in same asset already outside amount — v1: 0 unless fee disposed separately
                        var explicitFee: Decimal = 0
                        if let fee = e.feeAmount, fee > 0, (e.feeAsset == nil || e.feeAsset == e.baseAsset) {
                            // fee qty still on book? usually separate; if amount is net, fee may need dispose
                            // LOCK: if fee is extra on book, dispose fee qty too
                            // Most withdraw rows: amount is principal, fee separate — dispose fee from book if still present
                            if book(for: e.accountID, asset: e.baseAsset).quantity + Money.qtyEpsilon >= fee {
                                if let fc = try? book(for: e.accountID, asset: e.baseAsset).dispose(qty: fee) {
                                    explicitFee = fc
                                }
                            }
                        }
                        let result = policies.transferCost.apply(
                            outboundCostKRW: outboundCost,
                            withdrawnQty: wQty,
                            receivedQty: rQty,
                            explicitFeeCostKRW: explicitFee
                        )
                        abandonedTotal += result.abandonedCostKRW
                        extraDeductible += result.deductibleExpenseKRW
                        book(for: dep.accountID, asset: dep.baseAsset).acquire(qty: rQty, costKRW: result.transferredCostKRW)
                        transferDetails.append(TransferCostDetail(
                            linkID: link.id,
                            outboundCostKRW: outboundCost,
                            transferredCostKRW: result.transferredCostKRW,
                            abandonedCostKRW: result.abandonedCostKRW,
                            deductibleExpenseKRW: result.deductibleExpenseKRW,
                            ratio: Money.clamp(rQty / wQty, 0, 1)
                        ))
                    } else {
                        let cost = try book(for: e.accountID, asset: e.baseAsset).dispose(qty: wQty)
                        abandonedTotal += cost
                        warnings.append("미매칭 출금 원가 소멸: \(e.baseAsset.code) \(wQty)")
                        if let fee = e.feeAmount, fee > 0 {
                            let b = book(for: e.accountID, asset: e.baseAsset)
                            if b.quantity + Money.qtyEpsilon >= fee {
                                if let fc = try? b.dispose(qty: fee) {
                                    abandonedTotal += fc
                                }
                            }
                        }
                    }

                case .transferInternal:
                    // v1: no-op on single book per account+asset
                    break

                case .income:
                    if !e.baseAsset.isKRW {
                        book(for: e.accountID, asset: e.baseAsset).acquire(qty: Money.abs(e.quantity), costKRW: 0)
                    }

                case .fiatDeposit, .fiatWithdraw, .fee, .other, .ignored:
                    break
                }
            }
        }

        try process(pass1, recordTaxDisposals: false)

        // Apply deemed
        var deemedPositions: [DeemedPosition] = []
        for (accID, assetMap) in books {
            for (assetCode, b) in assetMap {
                guard b.quantity > Money.qtyEpsilon else { continue }
                let asset = AssetSymbol(assetCode)
                let bookUnit = b.snapshotUnitCost()
                let market = marketPrices[assetCode]
                if market == nil {
                    missingMarket.insert(assetCode)
                }
                guard let deemedUnit = policies.deemed.deemedUnit(bookUnit: bookUnit, marketUnit: market) else {
                    continue
                }
                let qty = b.quantity
                let reason = (market != nil && deemedUnit == market) ? "market" : "actual"
                // if equal book and market, prefer actual when equal
                let finalReason: String = {
                    if let m = market, deemedUnit == m && deemedUnit != bookUnit { return "market" }
                    return "actual"
                }()
                _ = reason
                deemedPositions.append(DeemedPosition(
                    accountID: accID,
                    asset: asset,
                    quantity: qty,
                    bookUnitKRW: bookUnit,
                    marketUnitKRW: market,
                    deemedUnitKRW: deemedUnit,
                    reason: finalReason
                ))
                b.reset()
                b.acquire(qty: qty, costKRW: deemedUnit * qty)
            }
        }

        try process(pass2, recordTaxDisposals: true)

        // Holdings snapshot
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
                let prev = aggMap[code] ?? (0, 0)
                aggMap[code] = (prev.qty + b.quantity, prev.cost + b.totalCost)
            }
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

        return ReplayResult(
            disposals: disposals,
            holdings: HoldingsSnapshot(asOf: asOf, rows: rows, aggregated: aggregated),
            deemedPositions: deemedPositions,
            abandonedTotal: abandonedTotal,
            extraDeductible: extraDeductible,
            warnings: warnings,
            transferCostDetails: transferDetails,
            missingMarketAssets: missingMarket.map { AssetSymbol($0) },
            missingFXDays: Array(missingFX).sorted(),
            fxResolutions: fxResolutions
        )
    }
}

enum CoinTaxError: Error, LocalizedError {
    case missingFX(days: [String])
    case missingMarket(assets: [String])
    case negativeLot(String)
    case verifyFail
    case parserReject(String)
    case formatUnknown
    case parseRow(String)
    case pdfPassword

    var errorDescription: String? {
        switch self {
        case .missingFX(let d): return "환율을 입력하세요: \(d.joined(separator: ", "))"
        case .missingMarket(let a): return "2026-12-31 시가를 입력하세요: \(a.joined(separator: ", "))"
        case .negativeLot(let m): return m
        case .verifyFail: return "계산 검증 실패 — 내보내기 불가"
        case .parserReject(let m): return m
        case .formatUnknown: return "지원 형식이 아닙니다"
        case .parseRow(let m): return m
        case .pdfPassword: return "PDF 비밀번호를 확인하세요"
        }
    }

    var code: String {
        switch self {
        case .missingFX: return "E_MISSING_FX"
        case .missingMarket: return "E_MISSING_MARKET"
        case .negativeLot: return "E_NEGATIVE_LOT"
        case .verifyFail: return "E_VERIFY_FAIL"
        case .parserReject: return "E_PARSER_REJECT"
        case .formatUnknown: return "E_FORMAT_UNKNOWN"
        case .parseRow: return "E_PARSE_ROW"
        case .pdfPassword: return "E_PDF_PASSWORD"
        }
    }
}
