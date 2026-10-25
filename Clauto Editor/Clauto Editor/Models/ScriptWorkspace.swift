import Foundation

/// Recorded wording belongs to the immutable transcript catalog. Only pickups
/// contain editable speech; neither a draft nor its score is a production permit.
struct ScriptBeat: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case passage, pickup }
    var id = UUID()
    var kind: Kind
    var rowID: String?
    var heading: String
    var notes = ""
    var unrecordedText = ""
}

struct ScriptProvenance: Codable, Equatable, Sendable {
    var author: String
    var model: String
    var origin: String
    var importedSHA256: String? = nil
    var identityVerified = false
}

struct ScriptApproval: Codable, Equatable, Sendable {
    let scriptSHA256: String
    let coverageSHA256: String
    let comparisonID: UUID?
    let factsReviewed: Bool
    let approvedAt: Date
    let scope: String
}

struct ScriptVersion: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var revisionID = UUID()
    var title: String
    var provenance: ScriptProvenance
    var basedOnVersionID: UUID? = nil
    var importedArtifact: Data? = nil
    var beats: [ScriptBeat] = []
    var approval: ScriptApproval? = nil

    func contentSHA256() throws -> String {
        // Include provenance and lineage: editing an attribution must not leave a
        // stale approval or silently rewrite the private comparison identity.
        var content = self; content.approval = nil
        return TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(content))
    }
}

struct ScriptScore: Codable, Equatable, Sendable {
    var clarity = 0
    var story = 0
    var coverage = 0
    var notes = ""
    var complete: Bool { [clarity, story, coverage].allSatisfy { (1...5).contains($0) } }
}

/// This is the only projection supplied to the blind review surface. No title,
/// author, model, filename, lineage, private IDs or import metadata is present.
struct BlindScriptOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let lines: [Line]
    let score: ScriptScore
    struct Line: Equatable, Sendable {
        let position: Int
        let heading: String
        let text: String
        let source: String
        let pickup: Bool
    }
}

struct ScriptComparison: Codable, Equatable, Identifiable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        let versionID: UUID
        let scriptSHA256: String
        let label: String
        var score = ScriptScore()
    }
    var id = UUID()
    let coverageSHA256: String
    var randomizationSeed: UInt64? = nil
    var entries: [Entry]
    var lockedAt: Date? = nil
    var authorsRevealed = false
}

struct ScriptWorkspaceState: Codable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    let projectID: UUID
    let catalogSHA256: String
    var inventorySHA256: String
    var revisionID = UUID()
    var reviewedRowIDs: Set<String> = []
    /// Imported media absent from the speech catalog must have an explicit
    /// disposition (e.g. reviewed B-roll / no speech), never an assumed silence.
    var nonTranscriptDispositions: [UUID: String] = [:]
    var versions: [ScriptVersion] = []
    var comparison: ScriptComparison? = nil

    func coverageSHA256() throws -> String {
        struct Coverage: Encodable { let catalog: String; let inventory: String; let rows: [String]; let other: [String: String] }
        return TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(Coverage(catalog: catalogSHA256,
            inventory: inventorySHA256, rows: reviewedRowIDs.sorted(),
            other: Dictionary(uniqueKeysWithValues: nonTranscriptDispositions.map { ($0.key.uuidString, $0.value) }))))
    }

    func validate(catalog: TranscriptCatalog, projectID: UUID) throws {
        try catalog.validate()
        let rows = Set(catalog.rows.map(\.id))
        guard schemaVersion == 1, self.projectID == projectID,
              TranscriptCatalog.isSHA(catalogSHA256), TranscriptCatalog.isSHA(inventorySHA256),
              reviewedRowIDs.isSubset(of: rows), versions.count <= 500,
              Set(versions.map(\.id)).count == versions.count else { throw ProjectFailure.invalidProject }
        for version in versions {
            guard !version.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  version.title.count <= 300, version.beats.count <= 100_000,
                  !version.provenance.identityVerified,
                  version.provenance.author.count <= 2000, version.provenance.model.count <= 2000, version.provenance.origin.count <= 2000,
                  Set(version.beats.map(\.id)).count == version.beats.count,
                  Set(version.beats.compactMap(\.rowID)).count == version.beats.compactMap(\.rowID).count else {
                throw WorkflowFailure.invalid("A script needs a title, unverified local attribution and distinct recorded passages. Duplicate a version to try another order.")
            }
            for beat in version.beats {
                guard beat.heading.count <= 2000, beat.notes.count <= 20_000, beat.unrecordedText.count <= 20_000 else { throw ProjectFailure.invalidProject }
                switch beat.kind {
                case .passage:
                    guard let rowID = beat.rowID, rows.contains(rowID), beat.unrecordedText.isEmpty else {
                        throw WorkflowFailure.invalid("Recorded beats must reference unchanged transcript passages. Put new wording in an unrecorded pickup.")
                    }
                case .pickup:
                    guard beat.rowID == nil, !beat.unrecordedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw WorkflowFailure.invalid("Give the pickup its unrecorded wording; it cannot claim a source timecode.")
                    }
                }
            }
        }
        if let comparison {
            guard comparison.entries.count >= 2, comparison.entries.count <= versions.count,
                  Set(comparison.entries.map(\.id)).count == comparison.entries.count,
                  Set(comparison.entries.map(\.versionID)).count == comparison.entries.count,
                  comparison.entries.enumerated().allSatisfy({ $0.element.label == "Option \($0.offset + 1)" }),
                  comparison.entries.allSatisfy({ entry in versions.contains { $0.id == entry.versionID } && TranscriptCatalog.isSHA(entry.scriptSHA256) }),
                  !comparison.authorsRevealed || comparison.lockedAt != nil,
                  comparison.lockedAt == nil || comparison.entries.allSatisfy({ $0.score.complete }) else { throw ProjectFailure.invalidProject }
        }
    }

    var reviewInProgress: Bool { comparison != nil && comparison?.lockedAt == nil }
    mutating func requireEditing() throws {
        guard !reviewInProgress else { throw WorkflowFailure.invalid("Lock the blind scores or cancel this review before editing scripts or source coverage.") }
    }
    mutating func invalidateApprovals() { for i in versions.indices { versions[i].approval = nil } }

    mutating func editVersion(_ id: UUID, _ edit: (inout ScriptVersion) throws -> Void) throws {
        try requireEditing()
        guard let index = versions.firstIndex(where: { $0.id == id }) else { throw ProjectFailure.invalidProject }
        let before = versions[index]
        try edit(&versions[index])
        if before != versions[index] { versions[index].revisionID = UUID(); versions[index].approval = nil }
    }

    mutating func startComparison(_ ids: [UUID]) throws {
        guard !reviewInProgress, ids.count >= 2, Set(ids).count == ids.count else {
            throw WorkflowFailure.invalid("Choose at least two distinct script versions for a fresh blind review.")
        }
        // Randomized once and persisted. Labels and the private mapping never
        // change during scoring; this is UI masking, not forensic anonymity.
        let seed = UInt64(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16), radix: 16)!
        var random = ScriptComparisonRandom(seed: seed)
        let shuffled = ids.shuffled(using: &random)
        let entries = try shuffled.enumerated().map { index, id in
            guard let version = versions.first(where: { $0.id == id }) else { throw ProjectFailure.invalidProject }
            return ScriptComparison.Entry(versionID: id, scriptSHA256: try version.contentSHA256(), label: "Option \(index + 1)")
        }
        comparison = .init(coverageSHA256: try coverageSHA256(), randomizationSeed: seed, entries: entries)
        invalidateApprovals()
    }

    func comparisonCurrent() -> Bool {
        guard let comparison, let coverage = try? coverageSHA256(), comparison.coverageSHA256 == coverage else { return false }
        return comparison.entries.allSatisfy { entry in
            guard let version = versions.first(where: { $0.id == entry.versionID }) else { return false }
            return (try? version.contentSHA256()) == entry.scriptSHA256
        }
    }

    func blindOptions(catalog: TranscriptCatalog) throws -> [BlindScriptOption] {
        guard let comparison, comparisonCurrent() else { throw WorkflowFailure.invalid("These scripts or sources changed. Start a fresh blind comparison.") }
        let rows = Dictionary(uniqueKeysWithValues: catalog.rows.map { ($0.id, $0) })
        return try comparison.entries.map { entry in
            guard let version = versions.first(where: { $0.id == entry.versionID }) else { throw ProjectFailure.invalidProject }
            let lines = try version.beats.enumerated().map { offset, beat -> BlindScriptOption.Line in
                if beat.kind == .pickup { return .init(position: offset + 1, heading: beat.heading, text: beat.unrecordedText, source: "Unrecorded pickup", pickup: true) }
                guard let rowID = beat.rowID, let row = rows[rowID] else { throw ProjectFailure.invalidProject }
                return .init(position: offset + 1, heading: beat.heading, text: row.text,
                    source: "\(row.sourceID) · \(row.inTimecode)–\(row.outTimecode)", pickup: false)
            }
            return .init(id: entry.id, label: entry.label, lines: lines, score: entry.score)
        }
    }

    mutating func score(_ option: UUID, score: ScriptScore) throws {
        guard var comparison, comparison.lockedAt == nil, comparisonCurrent(),
              let index = comparison.entries.firstIndex(where: { $0.id == option }),
              [score.clarity, score.story, score.coverage].allSatisfy({ (0...5).contains($0) }), score.notes.count <= 20_000 else {
            throw WorkflowFailure.invalid("Scores are locked or stale. Start a fresh comparison to score changed scripts.")
        }
        comparison.entries[index].score = score; self.comparison = comparison
    }
    mutating func lockScores() throws {
        guard var comparison, comparison.lockedAt == nil, comparisonCurrent(), comparison.entries.allSatisfy({ $0.score.complete }) else {
            throw WorkflowFailure.invalid("Score clarity, story and source coverage from 1 to 5 for every option before locking.")
        }
        comparison.lockedAt = Date(); self.comparison = comparison
    }
    mutating func revealAuthors() throws {
        guard comparison?.lockedAt != nil else { throw WorkflowFailure.invalid("Author and model details stay hidden until every score is locked.") }
        comparison?.authorsRevealed = true
    }

    func approvalCurrent(_ version: ScriptVersion) -> Bool {
        guard let approval = version.approval else { return false }
        return approval.factsReviewed && (try? version.contentSHA256()) == approval.scriptSHA256 &&
            (try? coverageSHA256()) == approval.coverageSHA256 &&
            (approval.comparisonID == nil || (comparison?.id == approval.comparisonID && comparison?.lockedAt != nil && comparisonCurrent()))
    }

    mutating func approve(_ id: UUID, catalog: TranscriptCatalog, missing: [ProjectFile], factsReviewed: Bool) throws {
        try requireEditing()
        guard factsReviewed, coverageComplete(catalog: catalog, missing: missing),
              let index = versions.firstIndex(where: { $0.id == id }), versions[index].beats.contains(where: { $0.kind == .passage }) else {
            throw WorkflowFailure.invalid("Review every source passage and uncovered media item, include recorded speech, and confirm the script's facts before approval.")
        }
        if versions.count > 1 {
            guard let comparison, comparison.lockedAt != nil, comparisonCurrent(), comparison.entries.contains(where: { $0.versionID == id }) else {
                throw WorkflowFailure.invalid("Compare the current versions and lock blind scores before approving a script.")
            }
        }
        versions[index].approval = .init(scriptSHA256: try versions[index].contentSHA256(), coverageSHA256: try coverageSHA256(),
            comparisonID: versions.count > 1 ? comparison?.id : nil, factsReviewed: true, approvedAt: Date(),
            scope: "Local script and factual-content approval for a separate source-linked assembly candidate; human identity is not authenticated.")
    }

    func coverageComplete(catalog: TranscriptCatalog, missing: [ProjectFile]) -> Bool {
        reviewedRowIDs == Set(catalog.rows.map(\.id)) && missing.allSatisfy {
            !(nonTranscriptDispositions[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Persist the seed and mapping so a review's presentation can be reproduced.
private struct ScriptComparisonRandom: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9e3779b97f4a7c15
        var value = seed
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

enum ScriptSourceInventory {
    static func files(_ project: Project) -> [ProjectFile] { project.manifest.files.filter { [.footage, .audio].contains($0.group) && $0.creativeReferenceRole == nil } }
    static func path(_ file: ProjectFile, project: Project) -> String {
        // Referenced media is a project-relative symlink in this repository;
        // originalPath is provenance, not the current intake attachment.
        let url = project.folder.appendingPathComponent(file.relativePath)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    static func sha(_ project: Project) throws -> String {
        TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(files(project).sorted { $0.id.uuidString < $1.id.uuidString }))
    }
    static func missing(_ project: Project, catalog: TranscriptCatalog) -> [ProjectFile] {
        let paths = Set(catalog.sources.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path })
        return files(project).filter { !paths.contains(path($0, project: project)) }
    }
}
