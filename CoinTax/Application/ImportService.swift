import Foundation
import SwiftData
import CryptoKit

@MainActor
final class ImportService {
    private let modelContext: ModelContext
    private let registry: ParserRegistry

    init(modelContext: ModelContext, registry: ParserRegistry = .v1) {
        self.modelContext = modelContext
        self.registry = registry
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

    func detect(url: URL) -> DetectOutcome {
        let probe = FormatProbe.probe(url: url)
        let ranked: [(parserID: String, score: Double)] = registry.ranked(for: probe).map {
            (parserID: $0.parser.parserID, score: $0.score)
        }
        return DetectOutcome(probe: probe, ranked: ranked, topParserID: ranked.first?.parserID)
    }

    func importFile(
        url: URL,
        project: ProjectEntity,
        account: AccountEntity,
        forceParserID: String? = nil,
        genericColumnMap: [String: String] = [:],
        pdfPassword: String? = nil
    ) throws -> ImportOutcome {
        let probe = FormatProbe.probe(url: url)
        if probe.peekText.contains("원천징수영수증") {
            throw CoinTaxError.parserReject("거래내역 확인서가 아닙니다")
        }
        let parser: any ExchangeDocumentParser
        if let force = forceParserID {
            if force == "generic-tabular-v1" {
                parser = GenericTabularMapper(columnMap: genericColumnMap)
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

    /// 제네릭용: 파일 헤더 행 추출
    func peekHeaders(url: URL) throws -> [String] {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" || ext == "xls" {
            let rows = try XLSXReader.readFirstSheetRows(url: url)
            return rows.first ?? []
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return CSVUtil.parseLines(text).first ?? []
    }

    func importText(_ text: String, fileName: String, project: ProjectEntity, account: AccountEntity, parser: (any ExchangeDocumentParser)? = nil) throws -> ImportOutcome {
        let probe = FormatProbe.probe(text: text, fileName: fileName)
        let p = parser ?? registry.resolve(for: probe)
        guard let parser = p else { throw CoinTaxError.formatUnknown }
        let result = try parser.parse(text: text, fileName: fileName, projectID: ProjectID(project.id), accountID: AccountID(account.id))
        return try persist(result: result, project: project, fileName: fileName, format: probe.format, fileData: Data(text.utf8))
    }

    private func persist(result: ParseResult, project: ProjectEntity, fileName: String, format: SourceFormat, fileData: Data?) throws -> ImportOutcome {
        let sha = fileData.map { Fingerprint.sha256Hex(String(decoding: $0.prefix(1_000_000), as: UTF8.self)) } ?? UUID().uuidString
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

        let existingFP = Set(project.events.map(\.fingerprint))
        var inserted = 0
        var skipped = 0
        for var event in result.events {
            if event.fingerprint.isEmpty {
                event.fingerprint = Fingerprint.make(for: event, parserID: result.parserID)
            }
            if existingFP.contains(event.fingerprint) {
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
        return ImportOutcome(parseResult: result, inserted: inserted, skippedDupe: skipped, sourceFileID: sf.id)
    }
}
