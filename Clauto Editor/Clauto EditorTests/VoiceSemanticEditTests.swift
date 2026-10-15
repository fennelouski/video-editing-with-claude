import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct VoiceSemanticEditTests {
    private let sha = String(repeating: "a",count: 64)
    private func target() -> VoiceReviewTarget {
        let signature = SourceFileSignature(device: 1,inode: 1,size: 1,modifiedSeconds: 1,modifiedNanoseconds: 0,changedSeconds: 1,changedNanoseconds: 0)
        let movie = VoiceArtifact(relativePath: "synthetic.mov",sha256: sha,signature: signature)
        return .init(id: UUID(),projectID: UUID(),versionID: UUID(),versionNumber: 1,versionMetadataSHA256: sha,timeline: movie,preview: movie,
            approvedPlanSHA256: sha,approvedPlanPath: "plan.json",approvedScriptSHA256: sha,approvedScriptPath: "script.md",
            approvedBriefSHA256: sha,engineVersion: "synthetic",duration: 2400*1001/24000.0)
    }
    private func directive(_ text: String,target: VoiceReviewTarget,onset: Double = 20) -> VoiceCandidateDirective {
        .init(noteID: UUID(),revision: 3,intent: VoiceIntent.infer(text),anchor: .init(targetID: target.id,seconds: onset),text: text)
    }
    private func candidate(_ target: VoiceReviewTarget,_ directives: [VoiceCandidateDirective]) -> VoiceRevisionCandidate {
        var result = VoiceRevisionCandidate(id: UUID(),parent: target,noteRevisions: directives.map { .init(id: $0.noteID,revision: $0.revision) },ownerProcessID: 0,created: Date(),renderNotBefore: Date())
        result.directives = directives; result.instructionsSHA256 = sha; result.state = .prepared; return result
    }
    @Test func explicitSpokenTimesBecomeSeparateProposalsWithoutRewritingTheOnset() throws {
        let target = target(), note = directive("Please cut from 1:12 to 1:16.",target: target)
        let proposal = try #require(VoiceSemanticEditInterpreter.propose(note,parent: target))
        #expect(proposal.start == 72 && proposal.end == 76 && proposal.action == .remove)
        #expect(proposal.originalAnchor == note.anchor && note.anchor.seconds == 20 && note.anchor.endSeconds == nil && note.action == nil)
        let source = candidate(target,[note]), plan = try VoiceCandidateEditPlan.compile(source)
        #expect(plan.issues.isEmpty && plan.semanticProposals == [proposal])
        #expect(plan.operations.first?.requestedStart == 72 && plan.operations.first?.requestedEnd == 76)
        #expect(source.directives == [note] && !plan.productionAuthorized)
    }
    @Test(arguments: ["Remove the section from one minute twelve seconds until one minute sixteen seconds", "Delete from 72 seconds to 76 seconds", "cut out 72 to 76", "Remove from 0:01:12 through 0:01:16!"])
    func absoluteGrammarIsGroundedInTheSameSelectedMovie(_ text: String) throws {
        let target = target(), proposal = try #require(VoiceSemanticEditInterpreter.propose(directive(text,target: target),parent: target))
        #expect(proposal.start == 72 && proposal.end == 76 && proposal.rule == "absolute_times_v1")
    }
    @Test func relativeRequestsUseOriginalOnsetAndNeverCompletionOrTheLatestPlayerTime() throws {
        let target = target()
        let keep = try #require(VoiceSemanticEditInterpreter.propose(directive("Keep the previous five seconds",target: target,onset: 20),parent: target))
        let remove = try #require(VoiceSemanticEditInterpreter.propose(directive("Remove the next twenty-one seconds",target: target,onset: 30),parent: target))
        let here = try #require(VoiceSemanticEditInterpreter.propose(directive("Please remove from here for 2.5 seconds",target: target,onset: 30),parent: target))
        #expect(keep.start == 15 && keep.end == 20 && keep.action == .protect)
        #expect(remove.start == 30 && remove.end == 51)
        #expect(here.start == 30 && here.end == 32.5)
    }
    @Test(arguments: ["remove that", "maybe remove from 12 to 15", "don't remove from 12 to 15", "remove from 12 to 15 but keep the shot", "remove from 1:72 to 1:76", "remove from -1 to 3", "remove from 15 to 12", "remove from 1 to 999999", "keep the previous twenty seconds", "remove from -one seconds to three seconds", "remove the next -five seconds", "remove from one minute -two seconds to one minute three seconds", "remove the next five- seconds", "remove the next twenty--one seconds", "remove the next twenty- one seconds", "remove the next twenty - one seconds"])
    func ambiguousNegatedCompoundAndOutOfBoundsRequestsNeedClarification(_ text: String) {
        let target = target()
        #expect(VoiceSemanticEditInterpreter.propose(directive(text,target: target,onset: 10),parent: target) == nil)
    }
    @Test func explicitSelectionRemainsAuthoritativeAndActionConflictsDoNotGuess() throws {
        let target = target()
        var manual = directive("Please remove from 72 to 76",target: target)
        manual = .init(noteID: manual.noteID,revision: manual.revision,intent: .change,anchor: .init(targetID: target.id,seconds: 3,endSeconds: 4),text: manual.text,action: .remove)
        let plan = try VoiceCandidateEditPlan.compile(candidate(target,[manual]))
        #expect(plan.issues.isEmpty && plan.semanticProposals == nil)
        #expect(plan.operations.first?.requestedStart == 3 && plan.operations.first?.requestedEnd == 4)
        let conflicting = VoiceCandidateDirective(noteID: UUID(),revision: 1,intent: .protect,anchor: .init(targetID: target.id,seconds: 20),text: "Remove from 12 to 15",action: .protect)
        #expect(VoiceSemanticEditInterpreter.propose(conflicting,parent: target) == nil)
        let blocked = try VoiceCandidateEditPlan.compile(candidate(target,[conflicting]))
        #expect(!blocked.issues.isEmpty)
    }
    @Test func proposedRemovalsRespectNaturalAndInheritedProtections() throws {
        var target = target()
        let remove = directive("Remove from 12 to 15",target: target), protect = directive("Keep from 13 to 14",target: target)
        #expect(try VoiceCandidateEditPlan.compile(candidate(target,[remove,protect])).issues.contains { $0.contains("overlaps protected") })
        target.candidateOrigin = .init(candidateID: UUID(),renderID: target.versionID,protections: [.init(noteID: UUID(),revision: 1,originTargetID: UUID(),originStartFrame: 200,originEndFrame: 400,startFrame: 200,endFrame: 400)])
        #expect(try VoiceCandidateEditPlan.compile(candidate(target,[remove])).issues.contains { $0.contains("earlier protection") })
        let another = self.target()
        #expect(VoiceSemanticEditInterpreter.propose(remove,parent: another) == nil)
    }
}
