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

    func importFile(url: URL, project: ProjectEntity, account: AccountEntity) throws -> ImportOutcome {
        let probe = FormatProbe.probe(url: url)
        guard let parser = registry.resolve(for: probe) else {
            throw CoinTaxError.formatUnknown
        }
        // withhold reject if bithumb detect rejects
        if probe.peekText.contains("원천징수영수증") {
            throw CoinTaxError.parserReject("거래내역 확인서가 아닙니다")
        }
        let result = try parser.parse(url: url, projectID: ProjectID(project.id), accountID: AccountID(account.id))
        return try persist(result: result, project: project, fileName: url.lastPathComponent, format: probe.format, fileData: try? Data(contentsOf: url))
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
        let sf = SourceFileEntity(
            fileName: fileName,
            format: format.rawValue,
            parserID: result.parserID,
            sha256: sha,
            metaJSON: "{}"
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
