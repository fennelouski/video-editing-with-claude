import Foundation

/// Recorded speech is immutable. Editorial decisions live in TranscriptReviewState.
struct TranscriptCatalog: Codable, Sendable {
    let schemaVersion: Int
    let title: String
    let datasetSHA256: String
    let sources: [TranscriptSource]
    let rows: [TranscriptRow]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", title, datasetSHA256 = "dataset_sha256", sources, rows
    }

    func validate() throws {
        guard schemaVersion == 1, !sources.isEmpty, !rows.isEmpty,
              sources.count <= 10_000, rows.count <= 100_000, Self.isSHA(datasetSHA256),
              Set(sources.map(\.id)).count == sources.count,
              Set(sources.map(\.path)).count == sources.count,
              Set(rows.map(\.id)).count == rows.count,
              Set(rows.map(\.originalOrder)) == Set(1...rows.count) else {
            throw WorkflowFailure.invalid("This transcript catalog has missing or duplicate source identities or rows.")
        }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var covered: [String: Set<Int>] = [:]
        for source in sources {
            guard !source.id.isEmpty, source.id.count <= 200, source.path.hasPrefix("/"),
                  Self.isSHA(source.sourceSHA256), Self.isSHA(source.transcriptSHA256),
                  source.duration.isFinite, source.duration > 0, !source.words.isEmpty,
                  source.words.count <= 1_000_000,
                  source.words.allSatisfy({ !$0.word.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
                throw WorkflowFailure.invalid("A transcript source has invalid hashes or word timing.")
            }
            guard zip(source.words, source.words.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
                throw WorkflowFailure.invalid("Source word times run backwards. Correct the transcript alignment before importing this catalog.")
            }
        }
        for row in rows {
            guard let source = byID[row.sourceID], row.firstWord >= 0,
                  row.lastWord >= row.firstWord, row.lastWord < source.words.count,
                  row.sourceSHA256 == source.sourceSHA256 else {
                throw WorkflowFailure.invalid("A transcript row lost its original source mapping.")
            }
            let words = source.words[row.firstWord...row.lastWord]
            let expectedID = source.id + String(format: "-w%05d-%05d-", row.firstWord, row.lastWord) + source.sourceSHA256.prefix(8)
            guard row.id == expectedID, row.text == words.map(\.word).joined(separator: " "),
                  row.start.isFinite, row.end.isFinite, row.end > row.start,
                  abs(row.start - words.first!.start) < 0.000001,
                  abs(row.end - words.last!.end) < 0.000001 else {
                throw WorkflowFailure.invalid("Recorded words, stable row identity or source time changed. Put wording requests in comments.")
            }
            for index in row.firstWord...row.lastWord {
                guard covered[row.sourceID, default: []].insert(index).inserted else {
                    throw WorkflowFailure.invalid("A source word appears in more than one transcript row.")
                }
            }
        }
        guard sources.allSatisfy({ covered[$0.id]?.count == $0.words.count }) else {
            throw WorkflowFailure.invalid("Source words were deleted from this catalog. Exclude passages with Keep instead.")
        }
        // Raw ASR may cross the final source boundary. Preserve it, flag it, and
        // carry the required review into exports rather than silently clipping it.
    }

    static func isSHA(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct TranscriptWord: Codable, Sendable {
    let word: String
    let start: Double
    let end: Double
}

struct TranscriptSource: Codable, Identifiable, Sendable {
    let id: String
    let path: String
    let sourceSHA256: String
    let transcriptSHA256: String
    let duration: Double
    let words: [TranscriptWord]
    enum CodingKeys: String, CodingKey {
        case id = "source_id", path, sourceSHA256 = "source_sha256"
        case transcriptSHA256 = "transcript_sha256", duration = "duration_seconds", words
    }
}

struct TranscriptRow: Codable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let sourceSHA256: String
    let firstWord: Int
    let lastWord: Int
    let start: Double
    let end: Double
    let inTimecode: String
    let outTimecode: String
    let text: String
    let keep: Bool
    let notes: String
    let requestedGraphics: String
    let assistantGraphics: String
    let handwrittenAsset: String
    let section: String
    let uncertainty: String
    let originalOrder: Int
    enum CodingKeys: String, CodingKey {
        case id, sourceID = "source_id", sourceSHA256 = "source_sha256"
        case firstWord = "first_word", lastWord = "last_word", start, end
        case inTimecode = "in_tc", outTimecode = "out_tc", text, keep, notes
        case requestedGraphics = "requested_graphics", assistantGraphics = "assistant_graphics"
        case handwrittenAsset = "handwritten_asset", section, uncertainty, originalOrder = "original_order"
    }
}

struct TranscriptRowDecision: Codable, Equatable, Sendable {
    var keep: Bool
    var comment: String
    var graphicRequest: String
    var handwritingReference: String
    init(row: TranscriptRow) {
        keep = row.keep; comment = row.notes; graphicRequest = row.requestedGraphics
        handwritingReference = row.handwrittenAsset
    }
}

struct TranscriptReviewState: Codable, Sendable {
    var schemaVersion = 1
    var reviewID: UUID
    var projectID: UUID
    var catalogSHA256: String
    var revisionID = UUID()
    var revisionNumber = 0
    var undoTargetRevisionID: UUID? = nil
    var undoTargetSHA256: String? = nil
    var saved = Date()
    var rowOrder: [String]
    var decisions: [String: TranscriptRowDecision]

    func validate(catalog: TranscriptCatalog, projectID: UUID, catalogSHA256: String) throws {
        let ids = Set(catalog.rows.map(\.id))
        guard schemaVersion == 1, self.projectID == projectID, self.catalogSHA256 == catalogSHA256,
              revisionNumber >= 0, rowOrder.count == ids.count, Set(rowOrder) == ids,
              Set(decisions.keys) == ids,
              (undoTargetRevisionID == nil) == (undoTargetSHA256 == nil),
              undoTargetSHA256.map(TranscriptCatalog.isSHA) ?? true else {
            throw WorkflowFailure.invalid("This review changed source identity or deleted rows. Reload the saved review.")
        }
    }

    mutating func move(_ rowID: String, to position: Int) throws {
        guard let old = rowOrder.firstIndex(of: rowID), (1...rowOrder.count).contains(position) else {
            throw WorkflowFailure.invalid("Choose a story position between 1 and \(rowOrder.count).")
        }
        rowOrder.remove(at: old); rowOrder.insert(rowID, at: position - 1)
    }
}

struct TranscriptReviewSession: Sendable {
    let catalog: TranscriptCatalog
    var state: TranscriptReviewState
    var rowsByID: [String: TranscriptRow] { Dictionary(uniqueKeysWithValues: catalog.rows.map { ($0.id, $0) }) }
    var keptCount: Int { state.decisions.values.filter(\.keep).count }
    var selectedBoundsIssues: [String] {
        let sources = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.id, $0) })
        return catalog.rows.filter { row in
            guard state.decisions[row.id]?.keep == true else { return false }
            let source = sources[row.sourceID]!
            return source.words[row.firstWord...row.lastWord].contains { $0.end > source.duration }
        }.map(\.id)
    }
}

enum TranscriptScope: String, CaseIterable, Sendable { case all = "All passages", kept = "Kept story", excluded = "Excluded" }

struct TranscriptDisplayRow: Identifiable, Sendable {
    let row: TranscriptRow
    let decision: TranscriptRowDecision
    let position: Int
    var id: String { row.id }

    static func make(session: TranscriptReviewSession, query: String, scope: TranscriptScope) -> [Self] {
        let byID = session.rowsByID
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.state.rowOrder.enumerated().compactMap { index, id in
            guard let row = byID[id], let decision = session.state.decisions[id],
                  scope == .all || (scope == .kept ? decision.keep : !decision.keep),
                  search.isEmpty || [row.text, row.sourceID, row.id, decision.comment, decision.graphicRequest].contains(where: { $0.localizedStandardContains(search) }) else { return nil }
            return .init(row: row, decision: decision, position: index + 1)
        }
    }
}
