import Foundation

enum ReportCSVExporter {
    /// 신고 보조 CSV. 열 수가 섹션마다 다르면 표 도구가 깨지므로 **고정 5열**로 통일한다.
    /// `section,key,value1,value2,value3`
    static func exportCSV(_ summary: TaxYearSummary) throws -> String {
        guard let v = summary.verification, v.isExportAllowed else {
            throw CoinTaxError.verifyFail
        }
        var rows: [[String]] = []
        rows.append(["section", "key", "value1", "value2", "value3"])

        func meta(_ key: String, _ value: String) {
            rows.append(["meta", key, value, "", ""])
        }
        func tax(_ key: String, _ value: Decimal) {
            rows.append(["tax", key, krw(value), "", ""])
        }

        meta("policyBundleID", summary.policyBundleID)
        meta("deemedBasisMode", summary.deemedBasisMode)
        if let alt = summary.deemedAlternative {
            rows.append(["deemedAlt", alt.basisMode, krw(alt.totalDeemedCostKRW), krw(alt.netIncomeKRW), krw(alt.totalTaxKRW)])
        }
        meta("transferCostPolicy", "abandon_lost_cost")
        if !summary.proxyExpenseAssets.isEmpty {
            meta("proxyExpense50Assets", summary.proxyExpenseAssets.joined(separator: "|"))
            if let alt = summary.proxyExpenseAlternative {
                rows.append(["proxyAlt", alt.basisMode, krw(alt.totalDeemedCostKRW), krw(alt.netIncomeKRW), krw(alt.totalTaxKRW)])
            }
        }
        meta("taxYear", "\(summary.taxYear)")
        // 과세 시작 전 연도는 신고 대상이 아니다 — 파일만 보고 신고자료로 오해하면 안 된다
        if summary.taxYear < TaxTime.taxStartYear {
            meta("estimateOnly", "과세 시작(2027-01-01) 전 연도 — 신고 대상 아님. 27년 규정을 적용해 본 예상입니다")
        }
        meta("status", summary.status.rawValue)
        meta("verification", summary.verification?.status ?? "")
        meta("calculatedAt", ISO8601DateFormatter().string(from: summary.calculatedAt))

        tax("totalProceedsKRW", summary.totalProceedsKRW)
        tax("totalCostsKRW", summary.totalCostsKRW)
        tax("netIncomeKRW", summary.netIncomeKRW)
        tax("basicDeductionKRW", summary.basicDeductionKRW)
        tax("taxBaseKRW", summary.taxBaseKRW)
        tax("nationalTaxKRW", summary.nationalTaxKRW)
        tax("localTaxKRW", summary.localTaxKRW)
        tax("totalTaxKRW", summary.totalTaxKRW)
        tax("abandonedTransferCostKRW", summary.abandonedTransferCostKRW)
        // 채택한 방식의 의제취득가 **총액**. 화면에는 「합계」로 있는데 파일에만 없었다 —
        // 신고서 취득가액 칸에 옮겨 적는 값이라 파일에 없으면 화면을 다시 봐야 한다.
        //
        // 다만 **과세 시작 전 예상 연도**에는 싣지 않는다. 화면이 그 표를 일부러 감추기 때문이다
        // (의제취득가는 2027 이후 처분에만 쓰인다). 화면이 감춘 것을 파일이 실으면
        // 「파일을 보고 신고서를 쓴다」는 원칙이 거꾸로 깨진다 (4차 감사 D-7·D4-2 의 반대 방향).
        let showsDeemed = !summary.deemed.isEmpty && summary.taxYear >= TaxTime.taxStartYear
        if showsDeemed {
            tax("totalDeemedCostKRW", summary.totalDeemedCostKRW)
        }

        let iso = ISO8601DateFormatter()
        for d in summary.disposals {
            rows.append(["disposal", "timestamp", iso.string(from: d.timestamp), d.asset.code, Money.decimalString(d.quantity)])
            rows.append(["disposal", "amounts", krw(d.proceedsKRW), krw(d.costKRW), krw(d.feesKRW)])
            rows.append(["disposal", "pnl", krw(d.pnlKRW), d.method.rawValue, d.eventID.raw.uuidString])
            rows.append(["disposal", "audit", d.fxRateUsed.map { Money.decimalString($0) } ?? "", d.fxSourceDate ?? "", d.deemedApplied ? "deemed" : "actual"])
        }

        for dem in (showsDeemed ? summary.deemed : []) {
            rows.append([
                "deemed", dem.asset.code,
                Money.decimalString(dem.quantity),
                // 단가는 원 단위로 반올림하지 않는다 — 1원 미만 코인이 0이 된다
                Money.unitPriceString(dem.deemedUnitKRW),
                dem.reason
            ])
            // 채택 단가만으로는 검산이 안 된다. 장부·시가·그 자산의 취득가 총액을 함께 남긴다
            rows.append([
                "deemedDetail", dem.asset.code,
                Money.unitPriceString(dem.bookUnitKRW),
                dem.marketUnitKRW.map { Money.unitPriceString($0) } ?? "",
                krw(dem.totalDeemedKRW)
            ])
        }

        for note in summary.fxSources {
            rows.append(["fx", "source", note, "", ""])
        }

        for issue in summary.verification?.issues ?? [] {
            rows.append(["verification", issue.id, issue.severity, issue.message, issue.context ?? ""])
        }

        for d in summary.disclaimers {
            rows.append(["disclaimer", "text", d, "", ""])
        }
        for n in TaxCopy.notices {
            rows.append(["notice", "text", n, "", ""])
        }
        // 신고 안내 — 화면·PDF 와 같은 문구를 같은 순서로
        if summary.taxYear >= TaxTime.taxStartYear {
            for (i, g) in TaxCopy.filingGuide.enumerated() {
                rows.append(["filing", "guide\(i + 1)", g, "", ""])
            }
        }

        // 세무 확인 대기 항목 — 신고 전에 반드시 다시 볼 것
        for q in TaxOpenQuestions.all {
            rows.append([
                "openQuestion", q.id, q.kind.label, q.title,
                q.currentAssumption.replacingOccurrences(of: "\n", with: " ")
            ])
        }

        return rows.map { row in
            row.map(escape).joined(separator: ",")
        }.joined(separator: "\n")
    }

    /// **원화 금액은 원 단위로 맞춘다.**
    ///
    /// 예전에는 `Money.decimalString` 을 그대로 썼다. 화면·PDF 는 원 단위로 반올림하는데
    /// CSV 만 나눗셈 찌꺼기(소수 30자리대)까지 적어서, 같은 계산인데 화면 `₩4,637,203` /
    /// CSV `4637202.9` 가 나왔다 (감사 D-7). 신고서에 옮길 때 어느 값을 쓸지 헷갈린다.
    ///
    /// 코인 **수량**은 반올림하지 않는다 — 소수 8자리가 의미를 갖는다.
    private static func krw(_ value: Decimal) -> String {
        Money.decimalString(Money.roundKRW(value))
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
