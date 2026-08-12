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
            rows.append(["tax", key, Money.decimalString(value), "", ""])
        }

        meta("policyBundleID", summary.policyBundleID)
        meta("deemedBasisMode", summary.deemedBasisMode)
        if let alt = summary.deemedAlternative {
            rows.append(["deemedAlt", alt.basisMode, Money.decimalString(alt.totalDeemedCostKRW), Money.decimalString(alt.netIncomeKRW), Money.decimalString(alt.totalTaxKRW)])
        }
        meta("transferCostPolicy", "abandon_lost_cost")
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

        let iso = ISO8601DateFormatter()
        for d in summary.disposals {
            rows.append(["disposal", "timestamp", iso.string(from: d.timestamp), d.asset.code, Money.decimalString(d.quantity)])
            rows.append(["disposal", "amounts", Money.decimalString(d.proceedsKRW), Money.decimalString(d.costKRW), Money.decimalString(d.feesKRW)])
            rows.append(["disposal", "pnl", Money.decimalString(d.pnlKRW), d.method.rawValue, d.eventID.raw.uuidString])
            rows.append(["disposal", "audit", d.fxRateUsed.map { Money.decimalString($0) } ?? "", d.fxSourceDate ?? "", d.deemedApplied ? "deemed" : "actual"])
        }

        for dem in summary.deemed {
            rows.append([
                "deemed", dem.asset.code,
                Money.decimalString(dem.quantity),
                Money.decimalString(dem.deemedUnitKRW),
                dem.reason
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

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
