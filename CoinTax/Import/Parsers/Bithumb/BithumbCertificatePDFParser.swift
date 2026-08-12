import Foundation
import PDFKit

struct BithumbCertificatePDFParser: ExchangeDocumentParser {
    let parserID = "bithumb-certificate-pdf-v1"
    /// 암호 PDF 잠금 해제용 (UI에서 전달)
    var password: String?

    func detect(_ probe: FormatProbeResult) -> Double {
        let n = probe.fileName.lowercased()
        if probe.peekText.contains("원천징수영수증") { return 0 } // reject path
        if probe.peekText.contains("거래내역 확인서") { return 0.98 }
        if n.contains("bithumb") || n.contains("빗썸") || n.contains("거래내역") { return 0.7 }
        if probe.format == .pdf { return 0.4 }
        if probe.format == .text && probe.peekText.contains("거래구분") { return 0.85 }
        return 0
    }

    func parse(url: URL, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        let ext = url.pathExtension.lowercased()
        if ext == "txt" || ext == "text" {
            let text = try CSVUtil.readText(url: url)
            return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
        }
        guard let doc = PDFDocument(url: url) else {
            throw CoinTaxError.parserReject("PDF를 열 수 없습니다")
        }
        if doc.isLocked {
            let pw = password ?? ""
            guard !pw.isEmpty, doc.unlock(withPassword: pw) else {
                throw CoinTaxError.pdfPassword
            }
        }
        var text = ""
        for i in 0..<doc.pageCount {
            text += doc.page(at: i)?.string ?? ""
            text += "\n"
        }
        if text.contains("원천징수영수증") {
            throw CoinTaxError.parserReject("거래내역 확인서가 아닙니다 (원천징수영수증)")
        }

        // 표 좌표로 읽는 경로가 **기본**이다.
        //
        // `PDFPage.string` 의 텍스트 순서에 의존하면 안 된다. 이 문서는 열 단위로 그려져 있어
        // 텍스트가 「모든 거래수량 → 모든 체결가격 → 모든 거래금액 …」 순으로 나온다.
        // 그 순서를 한 거래로 읽으면 수량·금액이 서로 다른 거래의 값으로 섞이고,
        // 그렇게 만들어진 취득가액으로 세액이 계산된다 (조용한 오답).
        let geo = Self.extractRowsByLayout(document: doc)
        if !geo.rows.isEmpty {
            var events: [LedgerEvent] = []
            var errors = geo.errors
            for row in geo.rows {
                if let e = makeEvent(parts: row.parts, projectID: projectID, accountID: accountID, rawRef: row.rawRef) {
                    events.append(e)
                } else {
                    errors.append("\(row.rawRef) 행을 읽지 못했습니다")
                }
            }
            guard !events.isEmpty else {
                throw CoinTaxError.parseRow("거래내역 확인서의 표를 찾았지만 거래 행을 하나도 해석하지 못했습니다")
            }
            var warnings = geo.warnings
            if !errors.isEmpty {
                warnings.append("검증에 실패한 \(errors.count)행은 제외했습니다 — 리포트의 오류 목록을 확인하세요")
            }
            return ParseResult(
                parserID: parserID,
                // 확인서는 최신 거래가 위에 온다 → 시간 오름차순으로 바로잡고 순번을 새긴다
                events: RowOrder.chronological(events),
                meta: ["rows": "\(events.count)", "mode": "layout"],
                warnings: warnings,
                errors: errors,
                ignoredCount: 0
            )
        }

        return try parse(text: text, fileName: url.lastPathComponent, projectID: projectID, accountID: accountID)
    }

    func parse(text: String, fileName: String, projectID: ProjectID, accountID: AccountID) throws -> ParseResult {
        if text.contains("원천징수영수증") {
            throw CoinTaxError.parserReject("거래내역 확인서가 아닙니다 (원천징수영수증)")
        }
        var events: [LedgerEvent] = []
        var warnings: [String] = []
        var errors: [String] = []
        let rawLines = text.components(separatedBy: .newlines)

        // 1) 파이프 구분 텍스트 모드 (합성 fixture / 사용자 정리본)
        for (i, line) in rawLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard trimmed.contains("|") else { continue }
            let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 5 else { continue }
            if let e = makeEvent(parts: parts, projectID: projectID, accountID: accountID, rawRef: "line\(i+1)") {
                events.append(e)
            }
        }

        // 2) PDF 추출 모드 — 2단 레이아웃 병합 후 한 줄로 재구성
        if events.isEmpty {
            let merged = Self.mergeCertificateRows(rawLines)
            for row in merged {
                if let e = makeEvent(parts: row.parts, projectID: projectID, accountID: accountID, rawRef: row.rawRef) {
                    events.append(e)
                } else {
                    errors.append("\(row.rawRef) 행을 읽지 못했습니다")
                }
            }
        }

        if events.isEmpty {
            // 조용히 "성공"으로 넘기면 국내 거래 전체가 빠진 채 세액이 계산된다 (리뷰 1-5)
            throw CoinTaxError.parseRow("거래내역 확인서에서 거래 행을 추출하지 못했습니다. 표 레이아웃이 다를 수 있습니다 — 제네릭 컬럼 매핑을 사용하거나 텍스트로 정리해 주세요.")
        }
        if !errors.isEmpty {
            warnings.append("일부 행을 건너뜀 \(errors.count)건")
        }
        return ParseResult(
            parserID: parserID,
            events: RowOrder.chronological(events),
            meta: ["rows": "\(events.count)"],
            warnings: warnings,
            errors: errors,
            ignoredCount: 0
        )
    }

    // MARK: - 표 좌표 기반 추출 (PDF 기본 경로)

    struct LayoutResult {
        var rows: [MergedRow] = []
        var warnings: [String] = []
        var errors: [String] = []
    }

    /// 확인서 PDF 의 표를 **좌표로** 읽는다.
    ///
    /// `PDFPage.characterBounds(at:)` 는 이 문서에서 인덱스와 글리프가 어긋나 쓸 수 없다.
    /// 반면 `PDFDocument.findString` 과 `PDFPage.selection(for:)` 는 정확하므로 그 둘만 쓴다.
    ///
    /// 1. 머리글(`거래일시`·`자산명`)의 x·y 를 찾아 「거래일시」 열의 x 구간과 표 상단 y 를 정한다 (하드코딩 없음)
    /// 2. 그 열만 잘라 줄 단위로 읽어 **거래일자가 있는 y 밴드** = 거래 한 건의 y 구간을 얻는다
    /// 3. 밴드마다 페이지 전체 폭을 다시 선택해 그 거래의 토큰만 순서대로 얻는다
    /// 4. 토큰을 분류해 숫자 셀을 만든다 — **자산 단위 토큰(USDT/KRW…)이 나오면 셀을 닫는다**
    static func extractRowsByLayout(document: PDFDocument) -> LayoutResult {
        var out = LayoutResult()
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            guard let dateHeader = firstBounds(of: "거래일시", in: document, page: page),
                  let assetHeader = firstBounds(of: "자산명", in: document, page: page) else {
                continue // 표가 없는 표지·부속 페이지
            }
            let pageWidth = page.bounds(for: .mediaBox).width
            // 값은 열 안에서 오른쪽 정렬되고 머리글보다 넓게 퍼진다 → 좌우로 조금씩 넓힌다
            let stripMinX = max(0, dateHeader.minX - dateHeader.width * 0.8)
            let stripMaxX = max(stripMinX + 1, assetHeader.minX - 2)
            // 표 머리글 위쪽(발급정보 등)의 날짜를 거래로 오인하지 않도록 머리글 아래만 본다
            let stripRect = CGRect(x: stripMinX, y: 0, width: stripMaxX - stripMinX, height: max(1, dateHeader.minY - 1))
            guard let stripSel = page.selection(for: stripRect) else { continue }

            var bands: [CGRect] = []
            for line in stripSel.selectionsByLine() {
                let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard isDateOnly(text) else { continue }
                bands.append(line.bounds(for: page))
            }
            bands.sort { $0.minY > $1.minY }
            guard !bands.isEmpty else { continue }

            for (i, band) in bands.enumerated() {
                // 아래쪽 경계: 다음 거래의 날짜 줄 바로 위까지 (그 사이에 시각·줄바꿈된 숫자가 들어 있다)
                let bottom: CGFloat
                if i + 1 < bands.count {
                    bottom = bands[i + 1].maxY + 0.5
                } else {
                    bottom = max(0, band.minY - band.height * 3)
                }
                let rowRect = CGRect(x: 0, y: bottom, width: pageWidth, height: max(1, band.maxY + 1 - bottom))
                let raw = page.selection(for: rowRect)?.string ?? ""
                let rawRef = "p\(pageIndex + 1)r\(i + 1)"
                switch decodeRow(raw, rawRef: rawRef) {
                case .success(let row):
                    out.rows.append(row)
                case .failure(let reason):
                    out.errors.append("\(rawRef): \(reason)")
                }
            }
        }
        return out
    }

    private static func firstBounds(of needle: String, in document: PDFDocument, page: PDFPage) -> CGRect? {
        document.findString(needle, withOptions: [])
            .filter { $0.pages.contains(page) }
            .map { $0.bounds(for: page) }
            .filter { !$0.isNull && $0.width > 0 }
            .max { $0.minY < $1.minY } // 표 머리글은 페이지에서 가장 위쪽 일치 항목
    }

    private enum RowDecode {
        case success(MergedRow)
        case failure(String)
    }

    private static let kindTokens = ["매수", "매도", "입금", "출금"]
    private static let dateOnlyRE = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
    private static let timeRE = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}(:\d{2})?$"#)
    /// 숫자 조각 — 부호·자리구분 콤마·소수점만
    private static let numberFragmentRE = try! NSRegularExpression(pattern: #"^-?[\d,]*\.?\d*$"#)
    /// 자산 단위 토큰 (KRW, USDT, BTC …)
    private static let unitRE = try! NSRegularExpression(pattern: #"^[A-Z][A-Z0-9]{1,9}$"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        let ns = s as NSString
        guard ns.length > 0 else { return false }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func isDateOnly(_ s: String) -> Bool { matches(dateOnlyRE, s) }

    /// 한 거래의 토큰 문자열을 `MergedRow` 로 만든다.
    ///
    /// 셀 배치는 문서 구조를 그대로 쓴다.
    /// - 매매(매수/매도): `수량 · 체결가격 · 거래금액 · 정산금액`
    /// - 입출금: 체결가격 칸이 없으므로 `수량 · 거래금액 · 정산금액`
    ///
    /// 마지막에 `거래금액 ≒ 수량 × 체결가격` 으로 교차검증한다. 틀리면 그 행을 **버린다** —
    /// 세액 계산에 쓰이는 값이므로 조용히 통과시키면 안 된다.
    private static func decodeRow(_ raw: String, rawRef: String) -> RowDecode {
        var date = ""
        var time = "00:00:00"
        var asset = ""
        var kind = ""
        var cells: [(value: String, unit: String)] = []
        var fragment = ""
        var memo: [String] = []

        for token in tokenize(raw) {
            if date.isEmpty, isDateOnly(token) {
                date = token
                continue
            }
            if matches(timeRE, token) {
                if time == "00:00:00" { time = token.count == 5 ? token + ":00" : token }
                continue
            }
            if kindTokens.contains(token) {
                if kind.isEmpty { kind = token } else { memo.append(token) }
                continue
            }
            if matches(unitRE, token) {
                if !fragment.isEmpty {
                    cells.append((fragment, token))
                    fragment = ""
                } else if asset.isEmpty {
                    asset = token
                } else {
                    memo.append(token)
                }
                continue
            }
            if matches(numberFragmentRE, token), token.contains(where: \.isNumber) || token == "," {
                // 줄바꿈으로 쪼개진 숫자를 이어 붙인다. 자리구분 콤마의 위치는 신뢰하지 않고
                // 파싱 단계에서 제거하므로, 조각 순서가 어긋나도 숫자값은 보존된다.
                fragment += token
                continue
            }
            memo.append(token)
        }
        if !fragment.isEmpty { cells.append((fragment, "")) }

        guard !date.isEmpty else { return .failure("거래일시를 찾지 못했습니다") }
        guard !kind.isEmpty else { return .failure("거래구분(매수/매도/입금/출금)을 찾지 못했습니다") }
        guard !asset.isEmpty else { return .failure("자산명을 찾지 못했습니다") }

        let isTrade = kind == "매수" || kind == "매도"
        let needed = isTrade ? 4 : 3
        guard cells.count >= needed else {
            return .failure("\(kind) 행에 필요한 금액 칸이 \(needed)개인데 \(cells.count)개만 읽혔습니다")
        }
        let qty = cells[0].value
        let price = isTrade ? cells[1].value : ""
        let tradeAmount = isTrade ? cells[2].value : cells[1].value
        let settlement = isTrade ? cells[3].value : cells[2].value

        // 뒤에 남은 칸은 확인서의 「가상자산 잔고」·「통화별 잔고」다.
        // 거래소가 자기 장부로 찍어준 값이라 **우리 계산의 정답지**가 된다 (V-BAL).
        // 자리로 세지 않고 **단위 토큰이 그 자산인 칸**을 고른다 — 열 구성이 판본마다 다를 수 있다.
        let assetBalance = cells.dropFirst(needed).first { $0.unit == asset }?.value ?? ""

        if isTrade,
           let q = Money.parseDecimal(qty), let p = Money.parseDecimal(price), let amt = Money.parseDecimal(tradeAmount) {
            let expected = q * p
            let diff = Money.abs(expected - Money.abs(amt))
            // 거래소가 원 단위로 절사하므로 소액 오차는 정상. 열이 밀렸으면 자릿수 단위로 벌어진다.
            let tolerance = max(Money.abs(amt) * Decimal(string: "0.005")!, 10)
            if diff > tolerance {
                return .failure("수량 × 체결가격(\(Money.decimalString(expected)))이 거래금액(\(Money.decimalString(amt)))과 맞지 않습니다 — 표 열이 밀렸을 수 있습니다")
            }
        }

        return .success(MergedRow(
            parts: [date, time, asset, kind, qty, price, tradeAmount, settlement, memo.joined(separator: " "), assetBalance],
            rawRef: rawRef
        ))
    }

    /// 선택 텍스트를 토큰으로 쪼갠다. 붙어 나온 `매수0.00120000`·`KRW홍길동` 도 분리한다.
    private static func tokenize(_ raw: String) -> [String] {
        let pieces = raw
            .components(separatedBy: .newlines)
            .flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
        var out: [String] = []
        for piece in pieces {
            var rest = piece.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            // 거래구분이 다음 칸 값과 붙어 나오는 경우 (`매수0.00120000`, `입금0.00005000`)
            if let kind = kindTokens.first(where: { rest.hasPrefix($0) }), rest.count > kind.count {
                out.append(kind)
                rest = String(rest.dropFirst(kind.count))
            }
            // 단위가 비고 텍스트와 붙어 나오는 경우 (`KRW홍길동` — 비고 칸에 예금주명이 붙는다)
            if let m = rest.range(of: #"^[A-Z][A-Z0-9]{1,9}"#, options: .regularExpression), m.upperBound < rest.endIndex {
                let unit = String(rest[m])
                let tail = String(rest[m.upperBound...])
                if tail.first?.isNumber != true, tail.first != "." , tail.first != "," {
                    out.append(unit)
                    rest = tail
                }
            }
            if !rest.isEmpty { out.append(rest) }
        }
        return out
    }

    // MARK: - 2단 레이아웃 병합 (텍스트 폴백)

    struct MergedRow {
        /// date, time, asset, type, qty, price, tradeAmt, settle, memo, **assetBalanceAfter**
        var parts: [String]
        var rawRef: String
    }

    /// 빗썸 확인서 PDF는 한 거래가 여러 줄로 흩어져 나온다
    /// (거래일시 날짜/시간 2줄 + 금액 줄 + 단위 줄 USDT/KRW + 비고).
    /// 문서 요구사항: parsers/bithumb-transaction-certificate.md §1.2 「줄 병합 필요」.
    ///
    /// 전략: 날짜로 시작하는 줄을 거래 시작점으로 보고, 다음 날짜 줄이 나오기 전까지의
    /// 모든 토큰을 모아 (거래구분 · 숫자열 · 자산 단위 · 비고)로 분류한다.
    /// 컬럼 위치에 의존하지 않으므로 열 순서가 조금 달라도 견딘다.
    static func mergeCertificateRows(_ lines: [String]) -> [MergedRow] {
        let dateHead = try! NSRegularExpression(pattern: #"^(\d{4})[-./](\d{2})[-./](\d{2})"#)
        let timeToken = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}(:\d{2})?$"#)
        let numberToken = try! NSRegularExpression(pattern: #"^-?[\d,]+(\.\d+)?$"#)
        let kinds: Set<String> = ["매수", "매도", "입금", "출금"]

        func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
            let ns = s as NSString
            return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
        }

        // 거래 블록으로 자르기
        var blocks: [(startLine: Int, tokens: [String])] = []
        var current: (startLine: Int, tokens: [String])?
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if matches(dateHead, line) {
                if let c = current { blocks.append(c) }
                current = (i + 1, [])
            }
            guard current != nil else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            current!.tokens.append(contentsOf: tokens)
        }
        if let c = current { blocks.append(c) }

        var out: [MergedRow] = []
        for block in blocks {
            var date = ""
            var time = "00:00:00"
            var kind = ""
            var numbers: [String] = []
            var units: [String] = []
            var memoParts: [String] = []

            for token in block.tokens {
                if date.isEmpty, matches(dateHead, token) {
                    date = token.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "/", with: "-")
                    continue
                }
                if matches(timeToken, token) {
                    time = token.count == 5 ? token + ":00" : token
                    continue
                }
                if kinds.contains(token) {
                    kind = token
                    continue
                }
                if matches(numberToken, token) {
                    numbers.append(token)
                    continue
                }
                // 자산 단위는 대문자 3~10자 (USDT, KRW, BTC …)
                if token.count >= 2, token.count <= 10,
                   token == token.uppercased(),
                   token.rangeOfCharacter(from: CharacterSet.uppercaseLetters) != nil,
                   token.rangeOfCharacter(from: CharacterSet.letters.inverted) == nil {
                    units.append(token)
                    continue
                }
                memoParts.append(token)
            }

            guard !date.isEmpty, !kind.isEmpty, !numbers.isEmpty else { continue }

            // 자산: 단위 줄 중 KRW가 아닌 것을 우선 (매매 대상 자산)
            let asset = units.first(where: { $0 != "KRW" }) ?? units.first ?? "KRW"

            // 숫자열 = [거래수량, 체결가격, 거래금액, 정산금액, 가상자산잔고, 통화별잔고]
            // 앞의 4개를 쓰고, 다섯 번째가 있으면 잔고 대조(V-BAL)용으로 함께 넘긴다.
            let qty = numbers.count > 0 ? numbers[0] : ""
            let price = numbers.count > 1 ? numbers[1] : ""
            let tradeAmt = numbers.count > 2 ? numbers[2] : ""
            let settle = numbers.count > 3 ? numbers[3] : (numbers.count > 2 ? numbers[2] : "")
            let assetBalance = numbers.count > 4 ? numbers[4] : ""

            out.append(MergedRow(
                parts: [date, time, asset, kind, qty, price, tradeAmt, settle, memoParts.joined(separator: " "), assetBalance],
                rawRef: "line\(block.startLine)"
            ))
        }
        return out
    }

    private func makeEvent(parts: [String], projectID: ProjectID, accountID: AccountID, rawRef: String) -> LedgerEvent? {
        guard parts.count >= 5 else { return nil }
        let date = parts[0]
        let time = parts[1]
        let asset = parts[2]
        let typeKO = parts[3]
        let qty = Money.parseDecimal(parts[4]) ?? 0
        let price = parts.count > 5 ? Money.parseDecimal(parts[5]) : nil
        let tradeAmount = parts.count > 6 ? Money.parseDecimal(parts[6]) : nil
        let settle = parts.count > 7 ? Money.parseDecimal(parts[7]) : (parts.count > 6 ? Money.parseDecimal(parts[6]) : nil)
        let memo = parts.count > 8 ? parts[8] : ""
        // 확인서가 찍어준 「가상자산 잔고」 — 우리 계산의 정답지 (V-BAL)
        let balanceAfter = parts.count > 9 ? Money.parseDecimal(parts[9]) : nil

        let ts = CSVUtil.parseDate("\(date) \(time)", timeZone: TaxTime.seoul, formats: ["yyyy-MM-dd HH:mm:ss"])
            ?? CSVUtil.parseDate("\(date) \(time)", timeZone: TaxTime.seoul, formats: ["yyyy-MM-dd HH:mm"])
        guard let timestamp = ts else { return nil }

        if asset.uppercased() == "KRW" {
            let type: EventType = typeKO == "입금" ? .fiatDeposit : (typeKO == "출금" ? .fiatWithdraw : .other)
            if memo.contains("예치금 이용료") {
                var e = LedgerEvent(
                    projectID: projectID, accountID: accountID, timestamp: timestamp,
                    type: .income, baseAsset: AssetSymbol("KRW"), quantity: Money.abs(qty),
                    quoteAmountKRW: settle.map { Money.abs($0) },
                    memo: memo, sourceKind: parserID, rawRef: rawRef
                )
                e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
                return e
            }
            var e = LedgerEvent(
                projectID: projectID, accountID: accountID, timestamp: timestamp,
                type: type, baseAsset: AssetSymbol("KRW"), quantity: type == .fiatDeposit ? Money.abs(qty) : -Money.abs(qty),
                quoteAmountKRW: settle.map { Money.abs($0) },
                memo: memo, sourceKind: parserID, rawRef: rawRef
            )
            e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
            return e
        }

        // 스테이킹·이자 보상은 전송 입고가 아니라 **보상 취득**이다 (03-tax-rules §8).
        // `deposit` 으로 두면 전송 매칭 후보에 올라가고 「상대 출금을 연결하세요」라는 틀린 안내가 붙는다.
        let isReward = memo.contains("이자받기") || memo.contains("스테이킹")
            || memo.contains("에어드랍") || memo.contains("에어드롭") || memo.contains("리워드")

        let type: EventType
        let quantity: Decimal
        switch typeKO {
        case "매수": type = .buy; quantity = Money.abs(qty)
        case "매도": type = .sell; quantity = -Money.abs(qty)
        case "입금": type = isReward ? .income : .deposit; quantity = Money.abs(qty)
        case "출금": type = .withdrawal; quantity = -Money.abs(qty)
        default: return nil
        }

        var hint: String?
        if memo.contains("바이낸스") || memo.lowercased().contains("binance") { hint = "binance" }
        if memo.uppercased().contains("OKX") { hint = "okx" }

        // 입·출금 행의 「정산금액」은 KRW가 아니라 코인 수량이다 → 원화 금액으로 쓰지 않는다.
        let isTrade = (type == .buy || type == .sell)

        // 총수입금액·필요경비 기준 통일 (TQ-02):
        //  - 매도: 「거래금액」(수수료 차감 전 총액)을 양도가액으로, (거래금액 − 정산금액)을 수수료로 분리.
        //          해외 거래소와 같은 기준이 되어 신고서 두 칸이 계정별로 달라지지 않는다.
        //  - 매수: 「정산금액」이 이미 수수료를 포함한 총 지출이므로 그대로 취득가액 (IMPLEMENTATION §6.3)
        var krwAmount: Decimal?
        var feeKRW: Decimal?
        if isTrade {
            switch type {
            case .sell:
                if let gross = tradeAmount.map({ Money.abs($0) }), gross > 0 {
                    krwAmount = gross
                    if let net = settle.map({ Money.abs($0) }) {
                        let diff = gross - net
                        feeKRW = diff > 0 ? diff : nil
                    }
                } else {
                    // 거래금액 칸이 비면 정산금액(순액)으로 폴백 — 소득금액은 동일
                    krwAmount = settle.map { Money.abs($0) }
                }
            default:
                krwAmount = settle.map { Money.abs($0) }
            }
        }

        var e = LedgerEvent(
            projectID: projectID,
            accountID: accountID,
            timestamp: timestamp,
            type: type,
            baseAsset: AssetSymbol(asset),
            quoteAsset: isTrade ? AssetSymbol("KRW") : nil,
            quantity: quantity,
            price: isTrade ? price : nil,
            quoteAmountKRW: krwAmount,
            feeAmount: feeKRW,
            feeAsset: feeKRW != nil ? AssetSymbol("KRW") : nil,
            memo: memo.isEmpty ? nil : memo,
            counterpartyHint: hint,
            sourceKind: parserID,
            rawRef: rawRef,
            balanceAfter: balanceAfter
        )
        e.fingerprint = Fingerprint.make(for: e, parserID: parserID)
        return e
    }
}
