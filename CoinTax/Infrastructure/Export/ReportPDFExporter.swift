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

        let pageWidth: CGFloat = Self.pageWidth
        let pageHeight: CGFloat = 841.8
        let margin: CGFloat = Self.margin
        let fontSize: CGFloat = Self.fontSize
        let lineHeight: CGFloat = fontSize * 1.45
        let usableHeight = pageHeight - margin * 2
        let linesPerPage = max(1, Int(usableHeight / lineHeight))

        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CoinTaxError.parseRow("PDF 생성 실패")
        }

        let attrs = Self.textAttributes

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

    // 종이·글꼴은 한 곳에서 정한다 — 줄바꿈 폭 계산과 실제 그리기가 어긋나면 다시 잘린다
    private static let pageWidth: CGFloat = 595.2  // A4
    private static let margin: CGFloat = 40
    private static let fontSize: CGFloat = 9.5
    private static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
         .foregroundColor: NSColor.black]
    }
    /// 실제로 글자를 그릴 수 있는 폭. `draw(in:)` 의 사각형과 **같은 값**이어야 한다.
    private static var textWidth: CGFloat { pageWidth - margin * 2 }

    private static func buildLines(_ s: TaxYearSummary) -> [String] {
        let attrs = textAttributes
        func wrapped(_ text: String) -> [String] { wrap(text, maxWidth: textWidth, attrs: attrs) }
        var lines: [String] = []
        lines.append("CoinTax 과세연도 요약 (참고용 · 세무 자문 아님)")
        lines.append("PolicyBundle: \(s.policyBundleID)")
        lines.append("연도: \(s.taxYear)  상태: \(s.status.rawValue)  검증: \(s.verification?.status ?? "-")")
        // 과세 시작 전 연도는 신고 대상이 아니다 — 인쇄물만 보고 신고자료로 오해하면 안 된다
        if s.taxYear < TaxTime.taxStartYear {
            lines.append("※ \(s.taxYear)년은 과세 시작(2027-01-01) 전이라 신고 대상이 아닙니다.")
            lines.append("   그해 실제 거래 손익에 2027년 규정을 적용해 본 예상입니다.")
        }
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
            lines.append("의제취득가 (2027-01-01 0시 기준 · \(modeLabel))")
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
                lines.append(contentsOf: wrapped("  [\(i.severity)] \(i.id): \(i.message)"))
            }
            lines.append("")
        }

        lines.append("고지")
        for (i, d) in s.disclaimers.enumerated() {
            for chunk in wrapped("\(i + 1). \(d)") {
                lines.append(chunk)
            }
        }
        lines.append("")
        lines.append("주의사항")
        for n in TaxCopy.notices {
            for chunk in wrapped("- \(n)") {
                lines.append(chunk)
            }
        }
        lines.append("")
        lines.append("세무 확인이 필요한 항목 (신고 전 반드시 확인)")
        for q in TaxOpenQuestions.all {
            for chunk in wrapped("- [\(q.id)/\(q.kind.label)] \(q.title)") {
                lines.append(chunk)
            }
            for chunk in wrapped("    현재 가정: \(q.currentAssumption.replacingOccurrences(of: "\n", with: " "))") {
                lines.append(chunk)
            }
        }
        return lines
    }

    private static func krw(_ d: Decimal) -> String {
        Money.decimalString(Money.roundKRW(d))
    }

    /// 고정폭 글꼴 기준 줄바꿈 — 고지 문구가 페이지 밖으로 밀려나지 않게 한다.
    /// 줄바꿈을 **실제로 그려지는 폭**으로 계산한다.
    ///
    /// 예전에는 글자 수 92자로 잘랐다. 고정폭 글꼴에서 한글은 영문의 약 두 배 폭이라
    /// 종이 폭을 넘고, `NSString.draw(in:)` 는 넘은 부분을 **그냥 잘라 버린다.**
    /// 그래서 `05-decisions §7.3` 이 문구 그대로 싣도록 잠근 필수 고지가 실제로는
    /// 문장 중간에서 끊겨 있었다 (감사 D-4).
    ///
    /// 한글 문장은 공백이 드물어 한 「단어」가 한 줄을 넘기는 일이 흔하다.
    /// 그래서 공백 단위로 붙이다가 그래도 넘치면 **글자 단위로 쪼갠다.**
    private static func wrap(_ text: String, maxWidth: CGFloat, attrs: [NSAttributedString.Key: Any]) -> [String] {
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        guard width(text) > maxWidth else { return [text] }

        /// 공백이 없어도 폭을 넘지 않게 글자 단위로 쪼갠다
        func breakLongToken(_ token: String, indent: String) -> [String] {
            var out: [String] = []
            var line = ""
            for ch in token {
                let candidate = line.isEmpty ? String(ch) : line + String(ch)
                if width(out.isEmpty ? candidate : indent + candidate) <= maxWidth {
                    line = candidate
                } else {
                    out.append(out.isEmpty ? line : indent + line)
                    line = String(ch)
                }
            }
            if !line.isEmpty { out.append(out.isEmpty ? line : indent + line) }
            return out
        }

        let indent = "   "
        var out: [String] = []
        var line = ""
        for token in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let prefix = out.isEmpty && line.isEmpty ? "" : (line.isEmpty ? indent : "")
            let candidate = line.isEmpty ? prefix + token : line + " " + token
            if width(candidate) <= maxWidth {
                line = candidate
                continue
            }
            if !line.isEmpty {
                out.append(line)
                line = ""
            }
            // 새 줄에 혼자 놓아도 넘치는 토큰은 글자 단위로 쪼갠다
            let base = out.isEmpty ? token : indent + token
            if width(base) <= maxWidth {
                line = base
            } else {
                let pieces = breakLongToken(token, indent: indent)
                out.append(contentsOf: pieces.dropLast())
                line = pieces.last ?? ""
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }
}
