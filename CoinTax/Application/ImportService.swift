import Foundation
import SwiftData
import CryptoKit

@MainActor
final class ImportService {
    private let modelContext: ModelContext
    private let registry: ParserRegistry

    init(modelContext: ModelContext, registry: ParserRegistry? = nil) {
        self.modelContext = modelContext
        self.registry = registry ?? .v1
    }

    struct ImportOutcome {
        var parseResult: ParseResult
        var inserted: Int
        var skippedDupe: Int
        var sourceFileID: UUID
    }

    struct DetectOutcome: Sendable {
        var probe: FormatProbeResult
        var ranked: [(parserID: String, score: Double)]
        var topParserID: String?
    }

    /// 폴더를 받으면 하위 폴더까지 훑어 넣을 수 있는 파일만 돌려준다. 파일이면 그대로 한 건.
    /// 숨김 파일(.DS_Store)과 거래소 export 가 아닌 확장자는 걸러야 폴더째 넣어도 오류가 쏟아지지 않는다.
    nonisolated static func expandToImportableFiles(_ url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [url] }
        let allowed: Set<String> = ["csv", "xlsx", "xls", "pdf", "txt"]
        let found = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )?.compactMap { $0 as? URL } ?? []
        return found
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func detect(url: URL) -> DetectOutcome {
        let probe = FormatProbe.probe(url: url)
        let ranked: [(parserID: String, score: Double)] = registry.ranked(for: probe).map {
            (parserID: $0.parser.parserID, score: $0.score)
        }
        return DetectOutcome(probe: probe, ranked: ranked, topParserID: ranked.first?.parserID)
    }

    /// 파일 하나가 어느 거래소 것인지 판단한다 (계정 자동 배정용).
    func route(url: URL) -> ImportRouter.Route {
        ImportRouter.route(FormatProbe.probe(url: url), registry: registry)
    }

    /// 파일 내용으로 거래소를 판단해 **그 거래소 계정**을 돌려준다. 없으면 만든다.
    ///
    /// 판단이 서지 않으면(제네릭·미인식) `nil` — 호출부가 사용자에게 묻는다.
    /// 여기서 임의의 계정을 고르면 원가법이 뒤바뀌고 거래소 간 전송이 통째로 사라진다.
    func resolveAccount(url: URL, project: ProjectEntity) throws -> (account: AccountEntity, route: ImportRouter.Route)? {
        let route = route(url: url)
        guard route.isConfident, let code = route.exchange else { return nil }
        let account = try ProjectService(modelContext: modelContext).ensureAccount(code, in: project)
        return (account, route)
    }

    func importFile(
        url: URL,
        project: ProjectEntity,
        account: AccountEntity,
        forceParserID: String? = nil,
        genericColumnMap: [String: String] = [:],
        genericTimeZone: String = "UTC",
        pdfPassword: String? = nil
    ) throws -> ImportOutcome {
        let probe = FormatProbe.probe(url: url)
        if probe.peekText.contains("원천징수영수증") {
            throw CoinTaxError.parserReject("거래내역 확인서가 아닙니다 (이자 원천징수영수증은 v1 미지원)")
        }
        let parser: any ExchangeDocumentParser
        if let force = forceParserID {
            if force == "generic-tabular-v1" {
                parser = GenericTabularMapper(columnMap: genericColumnMap, timeZoneIdentifier: genericTimeZone)
            } else if force == "bithumb-certificate-pdf-v1" {
                var b = BithumbCertificatePDFParser()
                b.password = pdfPassword
                parser = b
            } else if let found = registry.parsers.first(where: { $0.parserID == force }) {
                parser = found
            } else {
                throw CoinTaxError.formatUnknown
            }
        } else if probe.format == .pdf {
            var b = BithumbCertificatePDFParser()
            b.password = pdfPassword
            // Prefer bithumb when pdf; registry may also pick it
            if let resolved = registry.resolve(for: probe), resolved.parserID != "bithumb-certificate-pdf-v1" {
                parser = resolved
            } else {
                parser = b
            }
        } else {
            guard let resolved = registry.resolve(for: probe) else {
                throw CoinTaxError.formatUnknown
            }
            parser = resolved
        }
        let result = try parser.parse(url: url, projectID: ProjectID(project.id), accountID: AccountID(account.id))
        return try persist(
            result: result,
            project: project,
            fileName: url.lastPathComponent,
            format: probe.format,
            fileData: try? Data(contentsOf: url)
        )
    }

    /// 가져온 파일 하나를 되돌린다 — 그 파일에서 만든 거래와 그에 걸린 전송 연결까지 함께 지운다.
    ///
    /// 거래만 남기고 파일만 지우면 「어디서 온 거래인지」를 알 수 없게 되고,
    /// 거래만 지우고 링크를 두면 엔진이 「확정 링크의 출금 거래가 계산 대상에 없습니다」로 막는다.
    /// 개인지갑 입고처럼 **링크 때문에 생긴 짝 이벤트**도 같이 지운다 — 남기면 없던 자산이 떠돈다.
    ///
    /// - Returns: 지운 (거래 수, 전송 연결 수)
    @discardableResult
    func deleteSourceFile(_ file: SourceFileEntity, project: ProjectEntity) throws -> (events: Int, links: Int) {
        let fileID = file.id
        var doomedEventIDs = Set(project.events.filter { $0.sourceFileID == fileID }.map(\.id))

        // 이 거래에 걸린 링크 + 그 링크로 생겨난 개인지갑 이벤트
        var doomedLinks: [TransferLinkEntity] = []
        for link in project.links {
            guard doomedEventIDs.contains(link.fromEventID) || doomedEventIDs.contains(link.toEventID) else { continue }
            doomedLinks.append(link)
            for counterpartID in [link.fromEventID, link.toEventID] where !doomedEventIDs.contains(counterpartID) {
                if let counterpart = project.events.first(where: { $0.id == counterpartID }),
                   counterpart.sourceKind == MatchingService.walletSourceKind {
                    doomedEventIDs.insert(counterpartID)
                }
            }
        }

        for link in doomedLinks {
            project.links.removeAll { $0 === link }
            modelContext.delete(link)
        }
        let doomedEvents = project.events.filter { doomedEventIDs.contains($0.id) }
        for event in doomedEvents {
            project.events.removeAll { $0 === event }
            modelContext.delete(event)
        }
        project.sourceFiles.removeAll { $0 === file }
        modelContext.delete(file)
        try modelContext.save()
        return (doomedEvents.count, doomedLinks.count)
    }

    /// 제네릭용: 파일 헤더 행 추출
    func peekHeaders(url: URL) throws -> [String] {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" || ext == "xls" {
            let rows = try XLSXReader.readFirstSheetRows(url: url)
            return rows.first ?? []
        }
        let text = try CSVUtil.readText(url: url)
        return CSVUtil.parseLines(text).first ?? []
    }

    func importText(_ text: String, fileName: String, project: ProjectEntity, account: AccountEntity, parser: (any ExchangeDocumentParser)? = nil) throws -> ImportOutcome {
        let probe = FormatProbe.probe(text: text, fileName: fileName)
        let p = parser ?? registry.resolve(for: probe)
        guard let parser = p else { throw CoinTaxError.formatUnknown }
        let result = try parser.parse(text: text, fileName: fileName, projectID: ProjectID(project.id), accountID: AccountID(account.id))
        return try persist(result: result, project: project, fileName: fileName, format: probe.format, fileData: Data(text.utf8))
    }

    /// 가져온 파일 기록(`metaJSON`)에 남는 건수.
    ///
    /// 두 값은 성격이 전혀 다르다 — 섞어 보여주면 안 된다.
    /// - `excluded`: **일부러 뺀** 행 (선물·미지원 Type). 정상이다.
    /// - `unreadable`: **읽지 못해 버린** 행. 그만큼 **거래가 통째로 빠졌다**는 뜻이라
    ///   가져오기 직후 한 번이 아니라 파일 목록에 계속 보여야 한다.
    ///   (빗썸 확인서는 표 열이 밀리거나 페이지 경계에 걸리면 그 행을 버린다)
    static func importMeta(_ metaJSON: String) -> (excluded: Int, unreadable: Int) {
        guard let data = metaJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return (0, 0)
        }
        return (Int(obj["ignoredCount"] ?? "") ?? 0, Int(obj["errorCount"] ?? "") ?? 0)
    }

    private func persist(result: ParseResult, project: ProjectEntity, fileName: String, format: SourceFormat, fileData: Data?) throws -> ImportOutcome {
        // 파일 원본 바이트 기준 해시 → 같은 파일 재import 차단 (F-IM-08)
        let sha = fileData.map { Fingerprint.sha256Hex($0) } ?? UUID().uuidString
        if fileData != nil,
           let dupe = project.sourceFiles.first(where: { $0.sha256 == sha }) {
            throw CoinTaxError.duplicateFile("\(dupe.fileName) (\(dupe.importedAt.formatted(date: .numeric, time: .shortened)) 가져옴)")
        }
        let meta: [String: String] = [
            "ignoredCount": "\(result.ignoredCount)",
            "errorCount": "\(result.errors.count)",
            "warningCount": "\(result.warnings.count)"
        ]
        let metaJSON = (try? JSONSerialization.data(withJSONObject: meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sf = SourceFileEntity(
            fileName: fileName,
            format: format.rawValue,
            parserID: result.parserID,
            sha256: sha,
            metaJSON: metaJSON
        )
        sf.project = project
        project.sourceFiles.append(sf)
        modelContext.insert(sf)

        // ── 중복 제거 ────────────────────────────────────────────────
        //
        // 행 번호가 아니라 **거래 내용**으로 센다. 기간이 겹치는 export 를 다시 가져와도
        // 같은 거래가 두 번 쌓이지 않는다 (거래ID가 없는 바이낸스 Spot·빗썸 확인서에서 실제로 발생).
        //
        // 개수로 비교하는 이유: 같은 초에 같은 수량·가격으로 체결된 **서로 다른** 두 건이 있을 수 있다.
        // 이미 1건 있는데 새 파일에 2건 있으면 1건만 새로 넣는다.
        let pid = ProjectID(project.id)
        var existingCounts: [String: Int] = [:]
        var existingByKey: [String: LedgerEventEntity] = [:]
        /// 같은 키로 이미 들어와 있는 **수량들**. 한 거래ID에 여러 행이 붙는 경우
        /// (배치 출금의 같은 TXID 등)를 오탐하지 않으려면 하나가 아니라 전부와 비교해야 한다.
        var existingQtysByKey: [String: Set<String>] = [:]
        for entity in project.events {
            let domain = EntityMappers.event(entity, projectID: pid)
            let key = Fingerprint.contentKey(for: domain, parserID: domain.sourceKind)
            existingCounts[key, default: 0] += 1
            if existingByKey[key] == nil { existingByKey[key] = entity }
            existingQtysByKey[key, default: []].insert(entity.quantity)
        }

        var incomingCounts: [String: Int] = [:]
        var inserted = 0
        var skipped = 0
        var dupeWarnings: [String] = []

        for var event in result.events {
            if event.fingerprint.isEmpty {
                event.fingerprint = Fingerprint.make(for: event, parserID: result.parserID)
            }
            let key = Fingerprint.contentKey(for: event, parserID: result.parserID)
            incomingCounts[key, default: 0] += 1
            if incomingCounts[key]! <= (existingCounts[key] ?? 0) {
                // **건너뛰기 전에** 「같은 거래ID인데 수량이 다른가」를 본다.
                //
                // 거래ID가 있는 이벤트의 키에는 수량이 안 들어간다. 그래서 같은 주문이
                // 다른 수량으로 다시 들어와도 여기서 개수만 보고 조용히 넘어갔다 —
                // 아래에 그 경우를 알리는 코드가 있었지만 **이 줄에 막혀 한 번도 실행되지 않았다.**
                // 한쪽 파일이 그 주문의 일부만 담고 있다는 뜻이라, 어느 숫자로 신고하는지가 달라진다.
                if let ext = event.externalID, !ext.isEmpty {
                    let qty = Money.decimalString(event.quantity)
                    let priors = existingQtysByKey[key] ?? []
                    if !priors.isEmpty, !priors.contains(qty) {
                        dupeWarnings.append(
                            "같은 거래ID \(ext) 가 다른 수량으로 다시 들어왔습니다 (기존 \(priors.sorted().joined(separator: ", ")) / 신규 \(qty)) — 기존 값을 유지했습니다. 한쪽 파일이 그 주문의 일부만 담고 있을 수 있으니 원본을 확인하세요"
                        )
                    }
                }
                skipped += 1
                continue
            }
            // 같은 거래ID인데 내용이 다르면 알린다 (기간 경계에서 잘린 주문 등)
            if let ext = event.externalID, !ext.isEmpty,
               let prior = existingByKey[key],
               prior.quantity != Money.decimalString(event.quantity) {
                dupeWarnings.append("같은 거래ID \(ext) 가 다른 수량으로 다시 들어왔습니다 (기존 \(prior.quantity) / 신규 \(Money.decimalString(event.quantity))) — 기존 값을 유지했습니다")
                skipped += 1
                continue
            }
            event.sourceFileID = SourceFileID(sf.id)
            let entity = EntityMappers.makeEntity(from: event)
            entity.project = project
            project.events.append(entity)
            modelContext.insert(entity)
            inserted += 1
        }
        try modelContext.save()

        var outcomeResult = result
        outcomeResult.warnings.append(contentsOf: dupeWarnings)
        if skipped > 0 {
            outcomeResult.warnings.append("이미 가져온 거래 \(skipped)건은 건너뛰었습니다 (기간이 겹치는 파일)")
        }
        return ImportOutcome(parseResult: outcomeResult, inserted: inserted, skippedDupe: skipped, sourceFileID: sf.id)
    }
}
