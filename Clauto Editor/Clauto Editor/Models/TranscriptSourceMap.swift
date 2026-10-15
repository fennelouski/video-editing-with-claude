import Foundation
import CryptoKit
import Darwin

struct TranscriptBoundReview: Sendable {
    let session: TranscriptReviewSession
    let revisionSHA256: String
}

/// Concatenation coordinates describe untrimmed source selections, never a rendered cut.
struct TranscriptSourceSpan: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let sourcePath: String
    let sourceSHA256: String
    let transcriptSHA256: String
    let firstWord: Int
    let lastWord: Int
    let sourceIn: Double
    let sourceOut: Double
    let selectionIn: Double
    let selectionOut: Double
    var duration: Double { sourceOut - sourceIn }
}

struct TranscriptSourceMap: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let projectID: UUID
    let reviewID: UUID
    let revisionID: UUID
    let catalogSHA256: String
    let revisionSHA256: String
    let spans: [TranscriptSourceSpan]
    let untrimmedSelectionSeconds: Double
    let reviewOnly: Bool
    let appliedToCut: Bool

    static func compile(_ bound: TranscriptBoundReview) throws -> Self {
        let session = bound.session
        try session.catalog.validate()
        try session.state.validate(catalog: session.catalog, projectID: session.state.projectID, catalogSHA256: session.state.catalogSHA256)
        guard TranscriptCatalog.isSHA(bound.revisionSHA256), session.selectedBoundsIssues.isEmpty else {
            throw WorkflowFailure.invalid("A kept source range crosses its recorded media bounds. Exclude or review that passage before preparing a source map.")
        }
        let rows = session.rowsByID
        let sources = Dictionary(uniqueKeysWithValues: session.catalog.sources.map { ($0.id, $0) })
        var spans: [TranscriptSourceSpan] = [], at = 0.0
        var sourceHashes: [String: String] = [:]
        for id in session.state.rowOrder where session.state.decisions[id]!.keep {
            let row = rows[id]!, source = sources[row.sourceID]!
            if let other = sourceHashes[source.sourceSHA256], other != source.id {
                throw WorkflowFailure.invalid("Two clip IDs refer to identical source media. Use one canonical source identity for its passages.")
            }
            sourceHashes[source.sourceSHA256] = source.id
            let end = at + (row.end - row.start)
            guard row.start >= 0, row.end > row.start, end.isFinite, end > at,
                  source.words[row.firstWord...row.lastWord].allSatisfy({ $0.start >= row.start && $0.end <= row.end }) else {
                throw WorkflowFailure.invalid("A selected source span has invalid or unrepresentable time boundaries.")
            }
            spans.append(.init(id: id, sourceID: source.id, sourcePath: source.path, sourceSHA256: source.sourceSHA256,
                transcriptSHA256: source.transcriptSHA256, firstWord: row.firstWord, lastWord: row.lastWord,
                sourceIn: row.start, sourceOut: row.end, selectionIn: at, selectionOut: end))
            at = end
        }
        guard !spans.isEmpty else { throw WorkflowFailure.invalid("Keep at least one recorded passage before preparing its source map.") }
        return .init(schemaVersion: 1, projectID: session.state.projectID, reviewID: session.state.reviewID,
            revisionID: session.state.revisionID, catalogSHA256: session.state.catalogSHA256,
            revisionSHA256: bound.revisionSHA256, spans: spans, untrimmedSelectionSeconds: at, reviewOnly: true, appliedToCut: false)
    }

    func validate(against bound: TranscriptBoundReview) throws {
        guard self == (try Self.compile(bound)) else {
            throw WorkflowFailure.invalid("Source selections or their catalog changed. Prepare a new map from the saved review.")
        }
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    func sha256() throws -> String { Self.sha(try encoded()) }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func location(at seconds: Double) -> (span: TranscriptSourceSpan, sourceSeconds: Double)? {
        guard seconds.isFinite, seconds >= 0, seconds < untrimmedSelectionSeconds,
              let span = spans.first(where: { seconds >= $0.selectionIn && seconds < $0.selectionOut }) else { return nil }
        return (span, span.sourceIn + (seconds - span.selectionIn))
    }
}

struct SourceFileSignature: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

struct SourceAudioRange: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
}

struct VerifiedSourceMedia: Codable, Equatable, Sendable {
    let sourceID: String
    let requestedPath: String
    let canonicalPath: String
    let sourceSHA256: String
    let transcriptSHA256: String
    let transcriptRequestedPath: String?
    let transcriptPath: String?
    let transcriptSignature: SourceFileSignature?
    let signature: SourceFileSignature
    let durationSeconds: Double
    let audioRanges: [SourceAudioRange]
    let checkedAt: Date
    var transcriptSnapshotVerified: Bool { transcriptRequestedPath != nil && transcriptPath != nil && transcriptSignature != nil }

    func validate(source: TranscriptSource) throws {
        guard sourceID == source.id, requestedPath == source.path, sourceSHA256 == source.sourceSHA256,
              transcriptSHA256 == source.transcriptSHA256, transcriptRequestedPath == source.originalTranscriptPath,
              source.originalTranscriptPath == nil || transcriptSnapshotVerified else {
            throw WorkflowFailure.invalid("The media verification receipt does not bind this catalog's original source and transcript snapshot.")
        }
    }

    func validate(span: TranscriptSourceSpan) throws {
        guard span.sourceID == sourceID, span.sourcePath == requestedPath,
              span.sourceSHA256 == sourceSHA256, span.transcriptSHA256 == transcriptSHA256,
              span.sourceIn.isFinite, span.sourceOut.isFinite, span.sourceIn >= 0,
              durationSeconds.isFinite, span.sourceOut > span.sourceIn, span.sourceOut <= durationSeconds,
              audioRanges.contains(where: { $0.start.isFinite && $0.end.isFinite && $0.start <= span.sourceIn && $0.end >= span.sourceOut }) else {
            throw WorkflowFailure.invalid("This passage crosses verified source/audio boundaries or refers to different media.")
        }
    }
}

struct VerifiedSourcePlayback: Identifiable, Sendable {
    let id = UUID()
    let projectID: UUID
    let reviewID: UUID
    let revisionID: UUID
    let revisionSHA256: String
    let catalogSHA256: String
    let span: TranscriptSourceSpan
    let media: VerifiedSourceMedia
}

struct LocalSourceReviewAcknowledgement: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let projectID: UUID
    let reviewID: UUID
    let revisionID: UUID
    let catalogSHA256: String
    let revisionSHA256: String
    let mapSHA256: String
    let created: Date
    let sourceMappingsReviewed: Bool
    let recordedSpeechOrderAndNotesReviewed: Bool
    let media: [VerifiedSourceMedia]
    let approvalScope: String
    let humanIdentityVerified: Bool
    let pairedEditorialApproval: Bool
    let humanFactApproval: Bool
    let renderingAuthorized: Bool
    let appliedToCut: Bool
}

enum TranscriptProductionGate {
    static let blockers = ["Independent editorial agreement is not integrated.",
        "Trusted human fact approval is not integrated.", "Applying source-span selections to the engine is not integrated."]
    /// A durable association survives an unreadable/deleted head and refuses legacy
    /// whole-clip rendering that would ignore transcript selections.
    static func requireLegacyPipelineAllowed(project: Project) throws {
        let root = project.folder.resolvingSymlinksInPath().standardizedFileURL
        for relative in [".clauto/transcript-review-required.json", ".clauto/transcript-review.json", "notes/transcript-review"] {
            if try associationExists(relative, root: root) { try requireCutApplication() }
        }
    }
    private static func associationExists(_ relative: String, root: URL) throws -> Bool {
        var url = root
        let components = relative.split(separator: "/")
        for (index, component) in components.enumerated() {
            url = url.appendingPathComponent(String(component))
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(root.path + "/") else { throw ProjectFailure.invalidProject }
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { return false }
                throw WorkflowFailure.invalid("The project's transcript-review association cannot be checked. Reconnect or repair its metadata before running a cut.")
            }
            if index < components.count - 1 {
                // An existing symlink ancestor must resolve to a real local directory.
                var resolved = stat()
                guard lstat(canonical.path, &resolved) == 0, resolved.st_mode & S_IFMT == S_IFDIR else {
                    throw WorkflowFailure.invalid("The project's transcript-review metadata has a damaged ancestor. Repair it before running a cut.")
                }
            }
        }
        return true
    }

    static func requireCutApplication() throws {
        throw WorkflowFailure.invalid("Transcript choices remain a source-bound review draft. " + blockers.joined(separator: " ") + " No new cut was started.")
    }
}
