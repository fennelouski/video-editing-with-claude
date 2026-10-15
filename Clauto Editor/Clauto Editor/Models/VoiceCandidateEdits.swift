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
/// Derived constraints follow retained frames; original comments never move.
struct VoiceProtectionConstraint: Codable, Equatable, Sendable {
    let noteID: UUID
    let revision: Int
    let originTargetID: UUID
    let originStartFrame: Int
    let originEndFrame: Int
    let startFrame: Int
    let endFrame: Int
    static func projected(through plan: VoiceCandidateEditPlan) throws -> [Self] {
        let inherited = plan.parent.candidateOrigin?.protections ?? []
        let local = plan.operations.filter { $0.action == .protect }.map {
            Self(noteID: $0.noteID,revision: $0.revision,originTargetID: plan.parent.id,
                originStartFrame: $0.startFrame,originEndFrame: $0.endFrame,startFrame: $0.startFrame,endFrame: $0.endFrame)
        }
        var result: [Self] = []
        for protection in inherited + local {
            guard protection.revision > 0, protection.originStartFrame >= 0, protection.originEndFrame > protection.originStartFrame,
                  protection.startFrame >= 0, protection.endFrame > protection.startFrame, protection.endFrame <= plan.parentFrames else { throw ProjectFailure.invalidProject }
            var retained = 0
            for fragment in plan.fragments {
                let start = max(protection.startFrame,fragment.parentStartFrame), end = min(protection.endFrame,fragment.parentEndFrame)
                guard end > start else { continue }
                retained += end-start
                result.append(.init(noteID: protection.noteID,revision: protection.revision,originTargetID: protection.originTargetID,
                    originStartFrame: protection.originStartFrame,originEndFrame: protection.originEndFrame,
                    startFrame: fragment.candidateStartFrame+start-fragment.parentStartFrame,
                    endFrame: fragment.candidateStartFrame+end-fragment.parentStartFrame))
            }
            guard retained == protection.endFrame-protection.startFrame else { throw WorkflowFailure.invalid("A candidate cannot discard previously protected frames.") }
        }
        guard result.count <= 1_024 else { throw WorkflowFailure.invalid("This review has too many inherited protected ranges. Keep its history and start a new saved version.") }
        return result
    }
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
    var inheritedProtections: [VoiceProtectionConstraint]? = nil
    var semanticProposals: [VoiceSemanticEditProposal]? = nil
    static let mode = "watched_master_review_candidate_v1"
    static func compile(_ candidate: VoiceRevisionCandidate) throws -> Self {
        guard let instructions = candidate.instructionsSHA256 else { throw ProjectFailure.invalidProject }
        let frameCount = candidate.parent.duration * 24000 / 1001
        guard frameCount.isFinite, frameCount >= 1, frameCount <= 86_400,
              abs(frameCount - frameCount.rounded()) < 0.002 else { throw WorkflowFailure.invalid("This watched movie does not have a supported 24000/1001 frame grid.") }
        let frames = Int(frameCount.rounded())
        var operations: [VoiceFrameOperation] = [], issues: [String] = [], proposals: [VoiceSemanticEditProposal] = []
        for directive in candidate.directives {
            var action = directive.action, anchor = directive.anchor
            if action == nil || anchor.endSeconds == nil {
                if let proposal = VoiceSemanticEditInterpreter.propose(directive,parent: candidate.parent) {
                    if let end = anchor.endSeconds, abs(anchor.seconds-proposal.start) > 0.000001 || abs(end-proposal.end) > 0.000001 {
                        issues.append("Your comment's times and selected range disagree for note \(directive.noteID). Clarify which range you want."); continue
                    }
                    proposals.append(proposal); action = proposal.action
                    anchor = .init(targetID: directive.anchor.targetID,seconds: proposal.start,endSeconds: proposal.end)
                }
            }
            guard let action else { issues.append("Choose a range for note \(directive.noteID), or say ‘remove from 0:12 to 0:15’ or ‘keep the next five seconds’. Review the proposed cuts before approving."); continue }
            guard (action == .protect && directive.intent == .protect) || (action == .remove && directive.intent == .change) else { issues.append("The action and feedback meaning conflict for note \(directive.noteID)."); continue }
            guard anchor.targetID == candidate.parent.id, let end = anchor.endSeconds,
                  end.isFinite, anchor.seconds.isFinite, end > anchor.seconds,
                  anchor.seconds >= 0, end <= candidate.parent.duration else { issues.append("Choose a start and end inside this movie, or state an exact range in note \(directive.noteID)."); continue }
            let a = anchor.seconds * 24000 / 1001, b = end * 24000 / 1001
            // Proposed removals round inward; protections round outward. The exact
            // proposed frames are displayed and require separate plan approval.
            func boundary(_ value: Double, up: Bool) -> Int {
                if abs(value - value.rounded()) < 0.0001 { return Int(value.rounded()) }
                return Int(up ? value.rounded(.up) : value.rounded(.down))
            }
            let start = boundary(a, up: action == .remove), finish = min(frames,boundary(b, up: action == .protect))
            guard start >= 0, finish > start, finish <= frames else { issues.append("The selected range has no complete video frame for note \(directive.noteID)."); continue }
            operations.append(.init(noteID: directive.noteID, revision: directive.revision, action: action,
                requestedStart: anchor.seconds, requestedEnd: end, startFrame: start, endFrame: finish))
        }
        guard operations.count <= 64 else { throw WorkflowFailure.invalid("A candidate supports at most 64 reviewed ranges.") }
        let removals = operations.filter { $0.action == .remove }.sorted { ($0.startFrame,$0.endFrame) < ($1.startFrame,$1.endFrame) }
        let inherited = candidate.parent.candidateOrigin?.protections ?? []
        guard inherited.count <= 1_024, inherited.allSatisfy({ $0.startFrame >= 0 && $0.endFrame > $0.startFrame && $0.endFrame <= frames }) else { throw ProjectFailure.invalidProject }
        for removal in removals {
            for protection in operations where protection.action == .protect && max(removal.startFrame,protection.startFrame) < min(removal.endFrame,protection.endFrame) {
                issues.append("Removal \(removal.noteID) overlaps protected frames from \(protection.noteID). Resolve this conflict before approval.")
            }
            for protection in inherited where max(removal.startFrame,protection.startFrame) < min(removal.endFrame,protection.endFrame) {
                issues.append("This removal overlaps an earlier protection from note \(protection.noteID). Revise that source feedback and create a new source candidate to change the protection.")
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
            issues: issues, mode: Self.mode, productionAuthorized: false,inheritedProtections: inherited.isEmpty ? nil:inherited,
            semanticProposals: proposals.isEmpty ? nil:proposals)
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


/// A local proposal derived from the complete command. It never replaces the
/// original transcript, onset or directive, and never grants render approval.
struct VoiceSemanticEditProposal: Codable, Equatable, Sendable {
    let noteID: UUID
    let revision: Int
    let originalAnchor: VoiceNoteAnchor
    let action: VoiceRangeAction
    let start: Double
    let end: Double
    let rule: String
    var explanation: String {
        rule == "absolute_times_v1" ? "Times stated in your comment" : "Range measured from your original speech onset"
    }
}

enum VoiceSemanticEditInterpreter {
    private enum Span { case absolute(Double,Double), next(Double), previous(Double) }
    private struct Command { let action: VoiceRangeAction; let span: Span }
    static func intent(_ text: String) -> VoiceIntent? {
        command(text).map { $0.action == .protect ? .protect:.change }
    }
    static func propose(_ directive: VoiceCandidateDirective,parent: VoiceReviewTarget) -> VoiceSemanticEditProposal? {
        guard directive.anchor.targetID == parent.id, directive.anchor.seconds.isFinite,
              parent.duration.isFinite, parent.duration > 0, directive.anchor.seconds >= 0, directive.anchor.seconds <= parent.duration,
              directive.anchor.endSeconds == nil || (directive.anchor.endSeconds!.isFinite && directive.anchor.endSeconds! > directive.anchor.seconds && directive.anchor.endSeconds! <= parent.duration),
              let command = command(directive.text),
              directive.action == nil || directive.action == command.action,
              directive.intent == (command.action == .protect ? .protect:.change) else { return nil }
        let start: Double, end: Double, rule: String
        switch command.span {
        case .absolute(let a,let b): start = a; end = b; rule = "absolute_times_v1"
        case .next(let length): start = directive.anchor.seconds; end = start+length; rule = "next_from_onset_v1"
        case .previous(let length): end = directive.anchor.seconds; start = end-length; rule = "previous_from_onset_v1"
        }
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= parent.duration else { return nil }
        return .init(noteID: directive.noteID,revision: directive.revision,originalAnchor: directive.anchor,
                     action: command.action,start: start,end: end,rule: rule)
    }
    private static func command(_ original: String) -> Command? {
        guard original.count <= 20_000 else { return nil }
        var text = original.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = text.last, ".!?".contains(last) { text.removeLast(); text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let prefix = #"^(?:please[ ,]+)?(remove|cut out|cut|delete|keep|protect|preserve)\s+"#
        let noun = #"(?:(?:the\s+)?(?:range|section|part|footage|bit)\s+)?"#
        if let values = captures(prefix+noun+#"(?:from\s+)?(.+?)\s+(?:to|through|until)\s+(.+?)$"#,text),
           let a = time(values[1]), let b = time(values[2]) {
            return .init(action: action(values[0]),span: .absolute(a,b))
        }
        if let values = captures(prefix+#"(?:the\s+)?(next|previous)\s+(.+?)\s+seconds?$"#,text), let length = number(values[2]), length > 0 {
            return .init(action: action(values[0]),span: values[1] == "next" ? .next(length):.previous(length))
        }
        if let values = captures(prefix+#"from here for\s+(.+?)\s+seconds?$"#,text), let length = number(values[1]), length > 0 {
            return .init(action: action(values[0]),span: .next(length))
        }
        return nil
    }
    private static func action(_ value: String) -> VoiceRangeAction { ["keep","protect","preserve"].contains(value) ? .protect:.remove }
    private static func captures(_ pattern: String,_ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text,range: NSRange(text.startIndex...,in: text)), match.range.length == text.utf16.count else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0),in: text).map { String(text[$0]) } }
    }
    private static func time(_ value: String) -> Double? {
        if let values = captures(#"^([0-9]{1,3}):([0-5][0-9]):([0-5][0-9](?:\.[0-9]{1,6})?)$"#,value),
           let h = Double(values[0]), let m = Double(values[1]), let s = Double(values[2]) { return h*3600+m*60+s }
        if let values = captures(#"^([0-9]{1,4}):([0-5][0-9](?:\.[0-9]{1,6})?)$"#,value),
           let m = Double(values[0]), let s = Double(values[1]) { return m*60+s }
        if let values = captures(#"^(.+?)\s+minutes?(?:\s+(.+?)\s+seconds?)?$"#,value), let m = number(values[0]) {
            if values.count == 1 { return m*60 }
            guard let s = number(values[1]), s < 60 else { return nil }; return m*60+s
        }
        if let values = captures(#"^(.+?)\s+seconds?$"#,value) { return number(values[0]) }
        guard value.range(of: #"^[0-9]+(?:\.[0-9]{1,6})?$"#,options: .regularExpression) != nil else { return nil }
        return number(value)
    }
    private static func number(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^[0-9]{1,5}(?:\.[0-9]{1,6})?$"#,options: .regularExpression) != nil { return Double(text) }
        let small = ["zero":0,"one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,"eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12,"thirteen":13,"fourteen":14,"fifteen":15,"sixteen":16,"seventeen":17,"eighteen":18,"nineteen":19]
        let tens = ["twenty":20,"thirty":30,"forty":40,"fifty":50,"sixty":60,"seventy":70,"eighty":80,"ninety":90]
        if text.contains("-") {
            let pair = text.split(separator: "-",omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2, let ten = tens[pair[0]], let unit = small[pair[1]], (1...9).contains(unit) else { return nil }
            return Double(ten+unit)
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count == 1, let number = small[words[0]] ?? tens[words[0]] { return Double(number) }
        if words.count == 2, let ten = tens[words[0]], let unit = small[words[1]], (1...9).contains(unit) { return Double(ten+unit) }
        return nil
    }
}
