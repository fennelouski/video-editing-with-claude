import Foundation

struct RenderDirectoryIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
}

struct SyntheticFixtureSource: Codable, Sendable {
    let sourceID: String
    let mediaRelativePath: String
    let sourceSHA256: String
    let transcriptRelativePath: String
    let transcriptSHA256: String
    let frames: Int
}

struct SyntheticFixtureManifest: Codable, Sendable {
    let schemaVersion: Int
    let generator: String
    let projectID: UUID
    let fixtureID: UUID
    let catalogRelativePath: String
    let catalogSHA256: String
    let sources: [SyntheticFixtureSource]
}

struct SourceSpanRenderSnapshot: Sendable {
    let map: TranscriptSourceMap
    let acknowledgement: LocalSourceReviewAcknowledgement
    let acknowledgementSHA256: String
}

struct RenderedSourceSpan: Codable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let sourceSHA256: String
    let requestedIn: Double
    let requestedOut: Double
    let startFrame: Int
    let endFrame: Int
    let startSample: Int
    let endSample: Int
    let timelineFrame: Int
    var frames: Int { endFrame - startFrame }
}

enum SourceSpanFrameGrid {
    static let numerator = 24_000, denominator = 1_001, sampleRate = 48_000
    static let samplesPerFrame = 2_002
    static func compile(_ map: TranscriptSourceMap, media: [VerifiedSourceMedia]) throws -> [RenderedSourceSpan] {
        var result: [RenderedSourceSpan] = [], offset = 0
        for span in map.spans {
            func frame(_ seconds: Double, rounding: FloatingPointRoundingRule) throws -> Int {
                let value = seconds * Double(numerator) / Double(denominator)
                guard value.isFinite, value >= 0, value < Double(Int.max / samplesPerFrame) else { throw ProjectFailure.invalidProject }
                let nearest = value.rounded()
                return Int(abs(value - nearest) <= 0.0000001 ? nearest : value.rounded(rounding))
            }
            let start = try frame(span.sourceIn, rounding: .down), end = try frame(span.sourceOut, rounding: .up)
            guard end > start, offset <= Int.max - (end-start), let verified = media.first(where: { $0.sourceID == span.sourceID }) else { throw ProjectFailure.invalidProject }
            let rounded = TranscriptSourceSpan(id: span.id, sourceID: span.sourceID, sourcePath: span.sourcePath,
                sourceSHA256: span.sourceSHA256, transcriptSHA256: span.transcriptSHA256, firstWord: span.firstWord, lastWord: span.lastWord,
                sourceIn: Double(start * denominator) / Double(numerator), sourceOut: Double(end * denominator) / Double(numerator),
                selectionIn: span.selectionIn, selectionOut: span.selectionOut)
            try verified.validate(span: rounded)
            result.append(.init(id: span.id, sourceID: span.sourceID, sourceSHA256: span.sourceSHA256,
                requestedIn: span.sourceIn, requestedOut: span.sourceOut, startFrame: start, endFrame: end,
                startSample: start * samplesPerFrame, endSample: end * samplesPerFrame, timelineFrame: offset))
            offset += end-start
        }
        return result
    }
}

struct SourceSpanRenderInput: Encodable, Sendable {
    let schemaVersion = 1
    let purpose = "synthetic_source_span_acceptance"
    let productionAuthorized = false
    let projectPath: String
    let projectIdentity: RenderDirectoryIdentity
    let stagingPath: String
    let stagingIdentity: RenderDirectoryIdentity
    let fixtureID: UUID
    let fixtureManifestPath: String
    let fixtureManifestSHA256: String
    let map: TranscriptSourceMap
    let acknowledgementID: UUID
    let acknowledgementSHA256: String
    let mapSHA256: String
    let spans: [RenderedSourceSpan]
}

enum SyntheticSourceByteContract {
    static let strategy = "private_unlinked_readonly_v1"
    static let sourceLimit = 1_024 * 1_024, jobLimit = 2 * sourceLimit
}

struct SyntheticSourceByteProof: Codable, Equatable, Sendable {
    let sha256: String
    let byteCount: Int
    let readOnly: Bool
    let unlinked: Bool
}

struct SourceSpanWorkerReceipt: Codable, Sendable {
    let schemaVersion: Int
    let purpose: String
    let productionAuthorized: Bool
    let inputSHA256: String
    let fixtureID: UUID
    let mapSHA256: String
    let acknowledgementID: UUID
    let acknowledgementSHA256: String
    let sourceByteStrategy: String
    let sourceBytes: [String: SyntheticSourceByteProof]
    let spans: [RenderedSourceSpan]
    let totalFrames: Int
    let audioSamples: Int
    let fullDecodePassed: Bool
    let schemaChecked: Bool
    let artifactsSHA256: [String: String]
}

struct SyntheticSourceSpanRenderResult: Codable, Sendable {
    let id: UUID
    let projectID: UUID
    let reviewID: UUID
    let revisionID: UUID
    let acknowledgementID: UUID
    let mapSHA256: String
    let acknowledgementSHA256: String
    let inputSHA256: String
    let workerReceiptSHA256: String
    let sourceByteStrategy: String
    let sourceBytes: [String: SyntheticSourceByteProof]
    let purpose: String
    let productionAuthorized: Bool
    let appliedToCut: Bool
    let folder: URL
    let bundlePublication: String
    let folderIdentity: RenderDirectoryIdentity
    let artifactsSHA256: [String: String]
    let totalFrames: Int
    let audioSamples: Int
    let schemaChecked: Bool
}
