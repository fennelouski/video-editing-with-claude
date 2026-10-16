import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct ConversationLocalEditRepositoryTests {
    private func fixture() async throws -> (URL,Project,ConversationLocalEditTarget) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-local-job-protocol-"+UUID().uuidString)
        let engine = root.appendingPathComponent("engine");try FileManager.default.createDirectory(at: engine,withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic local job protocol",root: root.appendingPathComponent("projects"),engine: engine,engineVersion: "synthetic-engine")
        let target = ConversationLocalEditTarget(projectID: project.id,versionID: UUID(),versionNumber: 4,timelineSHA256: String(repeating: "a",count: 64),engineVersion: "synthetic-engine",duration: 120,aspect: "16:9",resolution: .fullHD)
        return (root,project,target)
    }
    private func send(_ text: String,target: ConversationLocalEditTarget,to repository: LiveConversationRepository,at: Date) async throws {
        let instruction = ConversationLocalEditInstruction(target: target,textSHA256: TranscriptSourceMap.sha(Data(text.utf8)),patches: try #require(ConversationLocalEditInterpreter.parse(text)))
        _ = try await repository.enqueue(text,id: UUID(),created: at,localEdit: instruction)
    }
    @Test func offlineIdleBatchFoldsSubmittedCommandsAndNewSteeringSupersedesOnlyTheOldAttempt() async throws {
        let (root,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),jobs = ConversationLocalEditRepository(project: project),now = Date()
        try await send("trim from 2 to 8",target: target,to: conversation,at: now.addingTimeInterval(-122))
        try await send("make it portrait at 720p",target: target,to: conversation,at: now.addingTimeInterval(-121))
        #expect(try await conversation.load().queued.count==2) // No provider turn required.
        let first = try await jobs.enqueueIdle(now: now),job = try #require(first.jobs.first)
        #expect(job.request.output.start==2 && job.request.output.end==8 && job.request.output.aspect=="9:16" && job.request.output.resolution == .hd)
        #expect(try await jobs.enqueueIdle(now: now).revision==first.revision)
        let owner = UUID(),claimed = try await jobs.claim(job.id,owner: owner,now: now)
        #expect(try await jobs.claim(job.id,owner: owner,now: now).revision==claimed.revision)
        try await send("make it landscape",target: target,to: conversation,at: now)
        let fake = DerivedCut(id: UUID(),projectID: project.id,parentVersionID: target.versionID,parentTimelineSHA256: target.timelineSHA256,request: job.request.output,recipeSHA256: String(repeating: "b",count: 64))
        let finished = try await jobs.finish(job.id,owner: owner,export: fake,now: now)
        #expect(finished.jobs[0].state == .superseded && finished.jobs[0].events.last?.exportID==nil)
        let next = try await jobs.enqueueIdle(now: now.addingTimeInterval(121)),new = try #require(next.jobs.last)
        #expect(next.jobs.count==2 && new.request.output.aspect=="16:9" && new.request.output.start==2 && new.request.output.end==8)
        #expect(next.jobs[0].requestSHA256==job.requestSHA256 && new.request.commandIDs.count==3)
    }
    @Test func resultOwnershipExactAcknowledgementRetryAndWrongResultRefusalRemainDurable() async throws {
        let (root,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),jobs = ConversationLocalEditRepository(project: project),now = Date()
        try await send("make it portrait",target: target,to: conversation,at: now.addingTimeInterval(-121))
        let job = try #require(try await jobs.enqueueIdle(now: now).jobs.first),owner = UUID()
        _ = try await jobs.claim(job.id,owner: owner)
        let fake = DerivedCut(id: UUID(),projectID: project.id,parentVersionID: target.versionID,parentTimelineSHA256: target.timelineSHA256,request: job.request.output,recipeSHA256: String(repeating: "c",count: 64))
        await #expect(throws: (any Error).self) { _ = try await jobs.finish(job.id,owner: UUID(),export: fake) }
        var changed = fake;changed.parentVersionID = UUID()
        await #expect(throws: (any Error).self) { _ = try await jobs.finish(job.id,owner: owner,export: changed) }
        let saved = try await jobs.finish(job.id,owner: owner,export: fake)
        #expect(saved.jobs.first?.state == .succeeded && saved.jobs.first?.events.last?.exportID==fake.id)
        #expect(try await jobs.finish(job.id,owner: owner,export: fake).revision==saved.revision)
        changed = fake;changed.id = UUID()
        await #expect(throws: (any Error).self) { _ = try await jobs.finish(job.id,owner: owner,export: changed) }
        #expect(try await ConversationLocalEditRepository(project: project).load().jobs.first?.requestSHA256==job.requestSHA256)
    }
    @Test func unsentDraftDefersIdleWorkAndDifferentSavedCutStartsItsOwnCommandSequence() async throws {
        let (root,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),jobs = ConversationLocalEditRepository(project: project),now = Date()
        try await send("trim from 2 to 8",target: target,to: conversation,at: now.addingTimeInterval(-121))
        var draft = LiveConversationDocument.Draft.empty();draft.text = "unsent steering";draft.updated = now.addingTimeInterval(-121)
        _ = try await conversation.saveDraft(draft)
        #expect(try await jobs.enqueueIdle(now: now).jobs.isEmpty)
        var empty = draft;empty.text = "";empty.revision += 1
        _ = try await conversation.saveDraft(empty,expected: draft)
        let other = ConversationLocalEditTarget(projectID: project.id,versionID: UUID(),versionNumber: 5,timelineSHA256: String(repeating: "d",count: 64),engineVersion: "synthetic-engine",duration: 30,aspect: "16:9",resolution: .fullHD)
        try await send("make it portrait",target: other,to: conversation,at: now.addingTimeInterval(-121))
        let job = try #require(try await jobs.enqueueIdle(now: now).jobs.first)
        #expect(job.request.target.versionID==other.versionID && job.request.commandIDs.count==1)
        #expect(job.request.output.start==0 && job.request.output.end==nil)
    }
    @Test func replacedProjectCannotAcquireOrRewriteTheLocalJobLedgerThroughItsOldHandle() async throws {
        let (root,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),jobs = ConversationLocalEditRepository(project: project),now = Date()
        try await send("make it portrait",target: target,to: conversation,at: now.addingTimeInterval(-121))
        _ = try await jobs.enqueueIdle(now: now)
        let relative = ".clauto/local-edit-jobs.json",before = try Data(contentsOf: project.folder.appendingPathComponent(relative))
        let original = project.folder.appendingPathExtension("preserved")
        try FileManager.default.moveItem(at: project.folder,to: original);try FileManager.default.copyItem(at: original,to: project.folder)
        await #expect(throws: (any Error).self) { _ = try await jobs.enqueueIdle(now: now.addingTimeInterval(121)) }
        await #expect(throws: (any Error).self) { _ = try await jobs.load() }
        for folder in [original,project.folder] { #expect(try Data(contentsOf: folder.appendingPathComponent(relative))==before) }
        let reopened = try await ProjectRepository().open(project.folder)
        #expect(try await ConversationLocalEditRepository(project: reopened).load().jobs.count==1)
    }
}
