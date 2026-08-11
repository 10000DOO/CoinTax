import Foundation
import AppKit
import PDFKit

enum ReportPDFExporter {
    /// 간단 텍스트 기반 신고 보조 PDF. Critical 실패 시 거부.
    static func exportPDF(_ summary: TaxYearSummary) throws -> Data {
        guard let v = summary.verification, v.isExportAllowed else {
            throw CoinTaxError.verifyFail
        }

        let pageWidth: CGFloat = 595.2  // A4
        let pageHeight: CGFloat = 841.8
        let margin: CGFloat = 40
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CoinTaxError.parseRow("PDF 생성 실패")
        }

        ctx.beginPDFPage(nil)
        let text = buildText(summary)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.black
        ]
        let rect = CGRect(x: margin, y: margin, width: pageWidth - margin * 2, height: pageHeight - margin * 2)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pageHeight)
        ctx.scaleBy(x: 1, y: -1)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        (text as NSString).draw(in: rect, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static func buildText(_ s: TaxYearSummary) -> String {
        var lines: [String] = []
        lines.append("CoinTax 과세연도 요약 (참고용 · 세무 자문 아님)")
        lines.append("PolicyBundle: \(s.policyBundleID)")
        lines.append("연도: \(s.taxYear)  상태: \(s.status.rawValue)  검증: \(s.verification?.status ?? "-")")
        lines.append("")
        lines.append("총수입(양도가): \(Money.decimalString(s.totalProceedsKRW)) 원")
        lines.append("필요경비: \(Money.decimalString(s.totalCostsKRW)) 원")
        lines.append("소득금액: \(Money.decimalString(s.netIncomeKRW)) 원")
        lines.append("기본공제: \(Money.decimalString(s.basicDeductionKRW)) 원")
        lines.append("과세표준: \(Money.decimalString(s.taxBaseKRW)) 원")
        lines.append("국세: \(Money.decimalString(s.nationalTaxKRW)) 원")
        lines.append("지방세: \(Money.decimalString(s.localTaxKRW)) 원")
        lines.append("예상 세액 합계: \(Money.decimalString(s.totalTaxKRW)) 원")
        lines.append("전송 소실 원가(참고·비공제): \(Money.decimalString(s.abandonedTransferCostKRW)) 원")
        lines.append("")
        lines.append("실현손익 \(s.disposals.count)건")
        for d in s.disposals.prefix(40) {
            lines.append("  \(d.asset.code) qty=\(Money.decimalString(d.quantity)) pnl=\(Money.decimalString(d.pnlKRW))")
        }
        if s.disposals.count > 40 {
            lines.append("  … 외 \(s.disposals.count - 40)건")
        }
        lines.append("")
        lines.append("고지")
        for (i, d) in s.disclaimers.enumerated() {
            lines.append("\(i + 1). \(d)")
        }
        return lines.joined(separator: "\n")
    }
}
