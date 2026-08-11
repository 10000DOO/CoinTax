import Foundation

enum ReportCSVExporter {
    static func exportCSV(_ summary: TaxYearSummary) throws -> String {
        guard let v = summary.verification, v.isExportAllowed else {
            throw CoinTaxError.verifyFail
        }
        var lines: [String] = []
        lines.append("section,key,value")
        lines.append("meta,policyBundleID,\(summary.policyBundleID)")
        lines.append("meta,taxYear,\(summary.taxYear)")
        lines.append("meta,status,\(summary.status.rawValue)")
        lines.append("meta,verification,\(summary.verification?.status ?? "")")
        lines.append("tax,totalProceedsKRW,\(Money.decimalString(summary.totalProceedsKRW))")
        lines.append("tax,totalCostsKRW,\(Money.decimalString(summary.totalCostsKRW))")
        lines.append("tax,netIncomeKRW,\(Money.decimalString(summary.netIncomeKRW))")
        lines.append("tax,basicDeductionKRW,\(Money.decimalString(summary.basicDeductionKRW))")
        lines.append("tax,taxBaseKRW,\(Money.decimalString(summary.taxBaseKRW))")
        lines.append("tax,nationalTaxKRW,\(Money.decimalString(summary.nationalTaxKRW))")
        lines.append("tax,localTaxKRW,\(Money.decimalString(summary.localTaxKRW))")
        lines.append("tax,totalTaxKRW,\(Money.decimalString(summary.totalTaxKRW))")
        lines.append("tax,abandonedTransferCostKRW,\(Money.decimalString(summary.abandonedTransferCostKRW))")
        for d in summary.disclaimers {
            let escaped = d.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("disclaimer,text,\"\(escaped)\"")
        }
        lines.append("disposal,eventID,timestamp,asset,qty,proceeds,cost,fees,pnl")
        let iso = ISO8601DateFormatter()
        for d in summary.disposals {
            lines.append([
                "disposal",
                d.eventID.raw.uuidString,
                iso.string(from: d.timestamp),
                d.asset.code,
                Money.decimalString(d.quantity),
                Money.decimalString(d.proceedsKRW),
                Money.decimalString(d.costKRW),
                Money.decimalString(d.feesKRW),
                Money.decimalString(d.pnlKRW)
            ].joined(separator: ","))
        }
        for dem in summary.deemed {
            lines.append("deemed,\(dem.asset.code),\(Money.decimalString(dem.quantity)),\(Money.decimalString(dem.deemedUnitKRW)),\(dem.reason)")
        }
        return lines.joined(separator: "\n")
    }
}
