import Foundation
import AppKit
import PDFKit

enum ReportPDFExporter {
    /// 신고 보조 PDF. Critical 실패 시 거부.
    ///
    /// 한 페이지에 몰아 그리면 거래가 많을 때 **필수 고지 4종이 잘려 나간다**(리뷰 4-5).
    /// 여기서는 줄 수를 기준으로 페이지를 나누고, 고지는 항상 마지막 페이지에 온전히 싣는다.
    static func exportPDF(_ summary: TaxYearSummary) throws -> Data {
        guard let v = summary.verification, v.isExportAllowed else {
            throw CoinTaxError.verifyFail
        }

        let pageWidth: CGFloat = 595.2  // A4
        let pageHeight: CGFloat = 841.8
        let margin: CGFloat = 40
        let fontSize: CGFloat = 9.5
        let lineHeight: CGFloat = fontSize * 1.45
        let usableHeight = pageHeight - margin * 2
        let linesPerPage = max(1, Int(usableHeight / lineHeight))

        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CoinTaxError.parseRow("PDF 생성 실패")
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.black
        ]

        let allLines = buildLines(summary)
        let pages = stride(from: 0, to: max(allLines.count, 1), by: linesPerPage).map { start in
            Array(allLines[start..<min(start + linesPerPage, allLines.count)])
        }

        for (index, pageLines) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageHeight)
            ctx.scaleBy(x: 1, y: -1)
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            var y = margin
            for line in pageLines {
                let rect = CGRect(x: margin, y: y, width: pageWidth - margin * 2, height: lineHeight)
                (line as NSString).draw(in: rect, withAttributes: attrs)
                y += lineHeight
            }
            let footer = "— \(index + 1) / \(pages.count) —"
            (footer as NSString).draw(
                in: CGRect(x: margin, y: pageHeight - margin, width: pageWidth - margin * 2, height: lineHeight),
                withAttributes: attrs
            )

            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private static func buildLines(_ s: TaxYearSummary) -> [String] {
        var lines: [String] = []
        lines.append("CoinTax 과세연도 요약 (참고용 · 세무 자문 아님)")
        lines.append("PolicyBundle: \(s.policyBundleID)")
        lines.append("연도: \(s.taxYear)  상태: \(s.status.rawValue)  검증: \(s.verification?.status ?? "-")")
        lines.append("")
        lines.append("총수입(양도가): \(krw(s.totalProceedsKRW)) 원")
        lines.append("필요경비: \(krw(s.totalCostsKRW)) 원")
        lines.append("소득금액: \(krw(s.netIncomeKRW)) 원")
        lines.append("기본공제: \(krw(s.basicDeductionKRW)) 원")
        lines.append("과세표준: \(krw(s.taxBaseKRW)) 원")
        lines.append("국세: \(krw(s.nationalTaxKRW)) 원")
        lines.append("지방세: \(krw(s.localTaxKRW)) 원")
        lines.append("예상 세액 합계: \(krw(s.totalTaxKRW)) 원")
        lines.append("전송 소실 원가(참고·비공제): \(krw(s.abandonedTransferCostKRW)) 원")
        lines.append("")

        lines.append("실현손익 \(s.disposals.count)건")
        for d in s.disposals {
            let fx = d.fxSourceDate.map { " fx=\($0)" } ?? ""
            lines.append("  \(TaxTime.dayKST(d.timestamp)) \(d.asset.code) qty=\(Money.decimalString(d.quantity)) 양도=\(krw(d.proceedsKRW)) 원가=\(krw(d.costKRW)) 손익=\(krw(d.pnlKRW))\(fx)")
        }
        lines.append("")

        if !s.deemed.isEmpty {
            let modeLabel = DeemedBasisMode(rawValue: s.deemedBasisMode)?.label ?? s.deemedBasisMode
            lines.append("의제취득가 (2026-12-31 기준 · \(modeLabel))")
            for d in s.deemed {
                let market = d.marketUnitKRW.map { krw($0) } ?? "-"
                lines.append("  \(d.asset.code) qty=\(Money.decimalString(d.quantity)) 장부=\(krw(d.bookUnitKRW)) 시가=\(market) 채택=\(krw(d.deemedUnitKRW)) (\(d.reason))")
            }
            if let alt = s.deemedAlternative {
                lines.append("  [참고] 다른 방식(\(alt.basisLabel)) 적용 시 — 의제취득가 \(krw(alt.totalDeemedCostKRW)) / 소득 \(krw(alt.netIncomeKRW)) / 세액 \(krw(alt.totalTaxKRW))")
                lines.append("  ※ 어느 방식이 맞는지는 세무 확인 대기 (TQ-01)")
            }
            lines.append("")
        }

        if !s.fxSources.isEmpty {
            lines.append("적용 환율 출처")
            for note in s.fxSources {
                lines.append("  \(note)")
            }
            lines.append("")
        }

        if let issues = s.verification?.issues, !issues.isEmpty {
            lines.append("검증 이슈 \(issues.count)건")
            for i in issues {
                lines.append("  [\(i.severity)] \(i.id): \(i.message)")
            }
            lines.append("")
        }

        lines.append("고지")
        for (i, d) in s.disclaimers.enumerated() {
            for chunk in wrap("\(i + 1). \(d)", width: 92) {
                lines.append(chunk)
            }
        }
        lines.append("")
        lines.append("주의사항")
        for n in TaxCopy.notices {
            for chunk in wrap("- \(n)", width: 92) {
                lines.append(chunk)
            }
        }
        lines.append("")
        lines.append("세무 확인이 필요한 항목 (신고 전 반드시 확인)")
        for q in TaxOpenQuestions.all {
            for chunk in wrap("- [\(q.id)/\(q.kind.label)] \(q.title)", width: 92) {
                lines.append(chunk)
            }
            for chunk in wrap("    현재 가정: \(q.currentAssumption.replacingOccurrences(of: "\n", with: " "))", width: 92) {
                lines.append(chunk)
            }
        }
        return lines
    }

    private static func krw(_ d: Decimal) -> String {
        Money.decimalString(Money.roundKRW(d))
    }

    /// 고정폭 글꼴 기준 줄바꿈 — 고지 문구가 페이지 밖으로 밀려나지 않게 한다.
    private static func wrap(_ text: String, width: Int) -> [String] {
        guard text.count > width else { return [text] }
        var out: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                out.append(line)
                line = "   " + word
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }
}
