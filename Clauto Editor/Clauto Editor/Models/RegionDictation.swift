import Foundation

/// Raw recognition revisions are evidence. The editable region note is a
/// separate projection, and can never replace these original words.
struct RegionSpeechRevision: Codable, Equatable, Sendable {
    let segmentID: String
    let text: String
    let isFinal: Bool
    let audioStart: Double?
    let audioEnd: Double?
    let runs: [VoiceSpeechRun]?
    init(_ result: VoiceSpeechResult) {
        segmentID = result.segmentID; text = result.text; isFinal = result.isFinal
        audioStart = result.audioStart; audioEnd = result.audioEnd; runs = result.runs
    }
    func validate() throws {
        guard !segmentID.isEmpty, segmentID.utf8.count <= 256, text.utf8.count <= 16_384,
              [audioStart,audioEnd].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 86_400 }),
              audioStart == nil || audioEnd == nil || audioEnd! >= audioStart!, (runs?.count ?? 0) <= 4096 else { throw ProjectFailure.invalidProject }
        for run in runs ?? [] {
            guard run.utf16Start >= 0, run.utf16Length >= 0, run.utf16Start <= text.utf16.count,
                  run.utf16Length <= text.utf16.count-run.utf16Start,
                  [run.audioStart,run.audioEnd].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 86_400 }),
                  run.audioStart == nil || run.audioEnd == nil || run.audioEnd! >= run.audioStart! else { throw ProjectFailure.invalidProject }
        }
    }
}

struct RegionDictationRecord: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case prepared, recording, finished, failed }
    let schemaVersion: Int
    let id: UUID
    let draftID: UUID
    let request: FrameCommentRequest
    let region: FrameEllipse
    let frameSHA256: String
    let width: Int
    let height: Int
    let actualFrameTime: ReviewClockTime
    let locale: String
    let deviceUID: String
    let created: Date
    var state: State = .prepared
    var revisions: [RegionSpeechRevision] = []
    var failure: String?
    // Recognition can revise a partial segment. Stable arrival order is kept;
    // a late provisional result never supersedes its committed final words.
    var transcript: String {
        var order: [String] = [], latest: [String:RegionSpeechRevision] = [:]
        for revision in revisions {
            if latest[revision.segmentID] == nil { order.append(revision.segmentID) }
            if latest[revision.segmentID]?.isFinal != true || revision.isFinal { latest[revision.segmentID] = revision }
        }
        return order.compactMap { latest[$0]?.text }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    func validate(project: UUID) throws {
        guard schemaVersion == 1, request.target.projectID == project,
              width > 0, height > 0, width <= 7680, height <= 7680, width*height <= 33_177_600,
              TranscriptCatalog.isSHA(frameSHA256), actualFrameTime == ReviewClockTime(value: request.frame.presentationValue,timescale: 24000),
              !locale.isEmpty, locale.utf8.count <= 128, !deviceUID.isEmpty, deviceUID.utf8.count <= 1024,
              created.timeIntervalSince1970.isFinite, revisions.count <= 1024, (failure?.utf8.count ?? 0) <= 4096 else { throw ProjectFailure.invalidProject }
        try request.frame.validate(duration: request.target.duration); try region.validate(width: width,height: height)
        for revision in revisions { try revision.validate() }
    }
    func sameAnchor(as other: Self) -> Bool {
        id == other.id && draftID == other.draftID && request == other.request && region == other.region &&
        frameSHA256 == other.frameSHA256 && width == other.width && height == other.height && actualFrameTime == other.actualFrameTime &&
        locale == other.locale && deviceUID == other.deviceUID && created == other.created && schemaVersion == other.schemaVersion
    }
    func follows(_ previous: Self) -> Bool {
        sameAnchor(as: previous) && revisions.starts(with: previous.revisions) &&
        (previous.state != .recording || state != .prepared) &&
        (![State.finished,.failed].contains(previous.state) || self == previous)
    }
}

/// Optimistic projection into one original draft/region. A user edit, deletion
/// or undo wins permanently; subsequent recognition remains in the raw ledger.
struct RegionDictationProjection {
    let draftID: UUID
    let regionID: UUID
    let base: String
    var applied: String
    var conflicted = false
    mutating func next(transcript: String,current: String?) -> String? {
        guard !conflicted, current?.utf8.elementsEqual(applied.utf8) == true else { conflicted = true; return nil }
        let value = base+(base.isEmpty || transcript.isEmpty ? "":" ")+transcript
        applied = value; return value
    }
}
