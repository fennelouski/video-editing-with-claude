import Foundation

enum VoiceRangeAction: String, Codable, CaseIterable, Sendable { case remove, protect }
struct VoiceFrameOperation: Codable, Equatable, Sendable {
    let noteID: UUID
    let revision: Int
    let action: VoiceRangeAction
    let requestedStart: Double
    let requestedEnd: Double
    let startFrame: Int
    let endFrame: Int
}
struct VoiceCandidateFragment: Codable, Equatable, Sendable {
    let id: String
    let masterSHA256: String
    let parentStartFrame: Int
    let parentEndFrame: Int
    let candidateStartFrame: Int
    var frames: Int { parentEndFrame - parentStartFrame }
}
struct VoiceCandidateEditPlan: Codable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let candidateID: UUID
    let parent: VoiceReviewTarget
    let instructionsSHA256: String
    let parentFrames: Int
    let operations: [VoiceFrameOperation]
    let fragments: [VoiceCandidateFragment]
    let issues: [String]
    let mode: String
    let productionAuthorized: Bool
    static let mode = "watched_master_review_candidate_v1"
    static func compile(_ candidate: VoiceRevisionCandidate) throws -> Self {
        guard let instructions = candidate.instructionsSHA256 else { throw ProjectFailure.invalidProject }
        let frameCount = candidate.parent.duration * 24000 / 1001
        guard frameCount.isFinite, frameCount >= 1, frameCount <= 86_400,
              abs(frameCount - frameCount.rounded()) < 0.002 else { throw WorkflowFailure.invalid("This watched movie does not have a supported 24000/1001 frame grid.") }
        let frames = Int(frameCount.rounded())
        var operations: [VoiceFrameOperation] = [], issues: [String] = []
        for directive in candidate.directives {
            guard let action = directive.action else { issues.append("Choose an explicit Remove range or Protect range action for note \(directive.noteID). Spoken text alone does not authorize an edit."); continue }
            guard (action == .protect && directive.intent == .protect) || (action == .remove && directive.intent == .change) else { issues.append("The action and feedback meaning conflict for note \(directive.noteID)."); continue }
            guard directive.anchor.targetID == candidate.parent.id, let end = directive.anchor.endSeconds,
                  end.isFinite, directive.anchor.seconds.isFinite, end > directive.anchor.seconds,
                  directive.anchor.seconds >= 0, end <= candidate.parent.duration else { issues.append("Choose an explicit start and end inside the watched version for note \(directive.noteID)."); continue }
            let a = directive.anchor.seconds * 24000 / 1001, b = end * 24000 / 1001
            // Proposed removals round inward; protections round outward. The exact
            // proposed frames are displayed and require separate plan approval.
            func boundary(_ value: Double, up: Bool) -> Int {
                if abs(value - value.rounded()) < 0.0001 { return Int(value.rounded()) }
                return Int(up ? value.rounded(.up) : value.rounded(.down))
            }
            let start = boundary(a, up: action == .remove), finish = min(frames,boundary(b, up: action == .protect))
            guard start >= 0, finish > start, finish <= frames else { issues.append("The selected range has no complete video frame for note \(directive.noteID)."); continue }
            operations.append(.init(noteID: directive.noteID, revision: directive.revision, action: action,
                requestedStart: directive.anchor.seconds, requestedEnd: end, startFrame: start, endFrame: finish))
        }
        guard operations.count <= 64 else { throw WorkflowFailure.invalid("A candidate supports at most 64 reviewed ranges.") }
        let removals = operations.filter { $0.action == .remove }.sorted { ($0.startFrame,$0.endFrame) < ($1.startFrame,$1.endFrame) }
        for removal in removals {
            for protection in operations where protection.action == .protect && max(removal.startFrame,protection.startFrame) < min(removal.endFrame,protection.endFrame) {
                issues.append("Removal \(removal.noteID) overlaps protected frames from \(protection.noteID). Resolve this conflict before approval.")
            }
        }
        var union: [(Int,Int)] = []
        for removal in removals {
            if let last = union.last, removal.startFrame <= last.1 { union[union.count-1].1 = max(last.1, removal.endFrame) }
            else { union.append((removal.startFrame,removal.endFrame)) }
        }
        var cursor = 0, at = 0, fragments: [VoiceCandidateFragment] = []
        for range in union + [(frames,frames)] {
            if range.0 > cursor {
                fragments.append(.init(id: "master-\(cursor)-\(range.0)", masterSHA256: candidate.parent.preview.sha256,
                    parentStartFrame: cursor, parentEndFrame: range.0, candidateStartFrame: at))
                at += range.0-cursor
            }
            cursor = max(cursor,range.1)
        }
        if removals.isEmpty { issues.append("Choose at least one explicit removal before preparing a changed preview.") }
        if fragments.isEmpty { issues.append("A candidate cannot remove the entire watched movie.") }
        if fragments.count > 32 { issues.append("Reduce this candidate to at most 32 retained ranges.") }
        return .init(schemaVersion: 1, id: UUID(), candidateID: candidate.id, parent: candidate.parent,
            instructionsSHA256: instructions, parentFrames: frames, operations: operations, fragments: fragments,
            issues: issues, mode: Self.mode, productionAuthorized: false)
    }
}
struct VoiceCandidateEditApproval: Codable, Sendable {
    let id: UUID
    let planID: UUID
    let planSHA256: String
    let created: Date
    let scope: String
    let productionAuthorized: Bool
}
struct VoiceCandidatePreview: Codable, Sendable {
    let id: UUID
    let relativeFolder: String
    let planSHA256: String
    let approvalID: UUID
    let proofSHA256: String
    let folderIdentity: RenderDirectoryIdentity
    var completionSHA256: String? = nil
    let artifactsSHA256: [String: String]
    let frames: Int
    let audioSamplesPerChannel: Int
    let productionAuthorized: Bool
    let appliedToWatchedVersion: Bool
}
struct VoiceApprovedEditSnapshot: Sendable {
    let candidate: VoiceRevisionCandidate
    let plan: VoiceCandidateEditPlan
    let planSHA256: String
    let approval: VoiceCandidateEditApproval
    let approvalSHA256: String
}
