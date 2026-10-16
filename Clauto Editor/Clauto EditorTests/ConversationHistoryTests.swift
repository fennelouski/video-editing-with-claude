import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor HistoryReplyFixture: ClaudeTurnTransport {
    nonisolated let isSyntheticFixture = true
    private(set) var requests: [ClaudeTurnRequest] = []
    func turn(_ request: ClaudeTurnRequest,onLine: @escaping @Sendable (String) async throws -> Void) async throws {
        requests.append(request)
        try await onLine("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\(request.sessionID)\"}")
        try await onLine(#"{"type":"result","subtype":"success","is_error":false,"result":"Synthetic resumed response"}"#)
    }
    func cancel() {}
}

@Suite(.serialized) struct ConversationHistoryTests {
    private func fixture() async throws -> (URL,Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-history-synthetic-"+UUID().uuidString)
        let engine = root.appendingPathComponent("engine");try FileManager.default.createDirectory(at: engine,withIntermediateDirectories: true)
        return (root,try await ProjectRepository().create(name: "Synthetic history",root: root.appendingPathComponent("projects"),engine: engine))
    }
    private func reply(_ session: UUID,text: String = "Synthetic reply 🥖") throws -> LiveConversationReply {
        var value = LiveConversationReply(sessionID: session)
        try value.receive("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\(session)\"}")
        let bytes = try JSONSerialization.data(withJSONObject: ["type":"result","subtype":"success","is_error":false,"result":text])
        try value.receive(String(decoding: bytes,as: UTF8.self));return value
    }
    private func settle(_ repo: LiveConversationRepository,count: Int) async throws -> LiveConversationDocument {
        var value = try await repo.load(),remaining = count
        // Boundary tests start from a fully validated closed fixture instead of
        // replaying the same128 writes in every case. The390-exchange test starts
        // with one real message, so every one of its exchanges still uses the
        // actual repository. Explicit two-writer/task interleavings stay real.
        if count>=128,value.messages.isEmpty,value.turns.isEmpty,value.history==nil,value.draft==nil {
            let savedReply = try reply(value.sessionID)
            for n in 0..<128 {
                let id = UUID()
                value.messages.append(.init(id: id,text: "Synthetic feedback \(n) 🥖",created: Date(),explicitlySubmitted: true))
                value.turns.append(.init(id: UUID(),messageIDs: [id],created: Date(),ownerPID: ProcessInfo.processInfo.processIdentifier,state: .succeeded,text: savedReply.text,events: savedReply.events,failure: nil))
            }
            value.revision += 384;try value.validate(project: value.projectID)
            let fixtureProject = await repo.project
            do {
                let lease = try ProjectMutationLease.acquire(fixtureProject);defer { withExtendedLifetime(lease) {} }
                try lease.root.child(".clauto").replacePointer(ConversationHistoryStore.encode(value),name: "live-conversation.json")
            }
            value = try await repo.load() // Match the production millisecond date roundtrip.
            remaining -= 128
        }
        for n in 0..<remaining {
            value = try await repo.enqueue("Synthetic feedback \(n) 🥖",id: UUID(),created: Date(),historyEpoch: value.historyEpoch)
            let id = UUID();value = try await repo.beginTurn(id: id)
            value = try await repo.updateTurn(id,reply: reply(value.sessionID),state: .succeeded,historyEpoch: value.historyEpoch)
        }
        return value
    }
    @Test func hundredsOfExchangesRollAutomaticallyWithExactLocalHistoryAndStableSession() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project),initial = try await settle(repo,count: 1)
        let value = try await settle(repo,count: 389)
        #expect(value.historyEpoch==3 && value.messages.count==6 && value.sessionID==initial.sessionID)
        #expect(value.history?.identifiedSession==true && value.revision>1100)
        var total = value.messages.count
        for epoch in 0..<3 {
            let archived = try await LiveConversationRepository(project: project).archivedWindow(epoch: epoch)
            #expect(archived.historyEpoch==epoch && archived.messages.count==128 && archived.turns.count==128)
            #expect(archived.turns.allSatisfy { $0.text=="Synthetic reply 🥖" && $0.state == .succeeded })
            #expect(try archived.prompt(for: [archived.messages[0].id])==archived.messages[0].text)
            total += archived.messages.count
        }
        #expect(total==390)
        #expect(try await LiveConversationRepository(project: project).load()==value)
    }
    @Test func queuedMessagesRunningRepliesAndUnsentWordsNeverRollOutOfTheActiveWindow() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project)
        for n in 0..<130 { _ = try await repo.enqueue("Unanswered \(n)",id: UUID(),created: Date()) }
        let id = UUID(),claimed = try await repo.beginTurn(id: id)
        _ = try await repo.enqueue("Steering during reply",id: UUID(),created: Date())
        #expect(try await repo.load().historyEpoch==0)
        _ = try await repo.updateTurn(id,reply: reply(claimed.sessionID),state: .succeeded)
        #expect(try await repo.load().queued.count==127)
        let second = LiveConversationRepository(project: project)
        let before = try await second.load();var draft = LiveConversationDocument.Draft.empty();draft.text = "Unsent exact words 🥖"
        _ = try await second.saveDraft(draft)
        #expect(try await second.load().draft==draft && before.historyEpoch==0)
    }
    @Test func submittedDraftReplayAndOldAutosavesCannotResurrectArchivedWords() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project)
        _ = try await settle(repo,count: 128)
        var draft = LiveConversationDocument.Draft.empty();draft.text = "Exact boundary words"
        _ = try await repo.saveDraft(draft)
        let next = try await repo.submitDraft(draft,expected: draft)
        #expect(next.historyEpoch==1 && next.messages.map(\.id)==[draft.submissionID] && next.draft==nil)
        #expect(try await repo.saveDraft(draft,expected: draft).revision==next.revision)
        #expect(try await repo.submitDraft(draft,expected: draft).revision==next.revision)
        let id = UUID();_ = try await repo.beginTurn(id: id);_ = try await repo.updateTurn(id,reply: reply(next.sessionID),state: .succeeded,historyEpoch: 1)
        _ = try await settle(repo,count: 128)
        let current = try await repo.load();#expect(current.historyEpoch==2)
        #expect(try await repo.submitDraft(draft,expected: nil).revision==current.revision)
        #expect(try await repo.saveDraft(draft).revision==current.revision)
        var changed = draft;changed.text = "Changed same identity"
        await #expect(throws: (any Error).self) { _ = try await repo.submitDraft(changed,expected: nil) }
        var other = LiveConversationDocument.Draft.empty();other.text = "Never submitted old-window words"
        await #expect(throws: LiveConversationDraftConflict.self) { _ = try await repo.saveDraft(other) }
        _ = try await repo.preserveLocalDraft(other)
        #expect(try await repo.load().recoveredDrafts?.last?.draft==other)
    }
    @Test func archivedTerminalAcknowledgementsAreExactAndArchivesAreNeverMutated() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project),value = try await settle(repo,count: 128),last = try #require(value.turns.last)
        let next = try await repo.enqueue("New window",id: UUID(),created: Date())
        let ref = try #require(next.history?.references.first),path = project.folder.appendingPathComponent(".clauto/conversation-history/"+ref.id.uuidString+".json"),bytes = try Data(contentsOf: path)
        let exact = try reply(value.sessionID)
        #expect(try await repo.updateTurn(last.id,reply: exact,state: .succeeded).revision==next.revision)
        await #expect(throws: (any Error).self) { _ = try await repo.updateTurn(last.id,reply: reply(value.sessionID,text: "Different result"),state: .succeeded) }
        await #expect(throws: (any Error).self) { _ = try await repo.updateTurn(last.id,reply: exact,state: .running) }
        #expect(try Data(contentsOf: path)==bytes)
        var corrupt = bytes;corrupt[corrupt.startIndex] = 0;try corrupt.write(to: path)
        await #expect(throws: (any Error).self) { _ = try await repo.archivedWindow(epoch: 0) }
        await #expect(throws: (any Error).self) { _ = try await repo.load() }
    }
    @Test func recoveredDraftsRemainAvailableAndRestoreAlongsideNewerWordsAfterRollover() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project)
        var old = LiveConversationDocument.Draft.empty();old.text = "Earlier unsent 🥖"
        _ = try await repo.preserveLocalDraft(old)
        _ = try await settle(repo,count: 129)
        let archive = try await repo.archivedWindow(epoch: 0),entry = try #require(archive.recoveredDrafts?.first)
        var local = LiveConversationDocument.Draft.empty(epoch: 1);local.text = "Newer exact words"
        _ = try await repo.saveDraft(local)
        let restored = try await repo.restoreRecoveredDraft(entry.id,newID: UUID(),local: local,historyEpoch: 0)
        #expect(restored.draft?.text==old.text && restored.draft?.historyEpoch==1)
        #expect(restored.recoveredDrafts?.contains(where: { $0.draft==local })==true)
        #expect(restored.messages.count==1 && restored.queued.isEmpty)
    }
    @Test func earlierCommandsFoldAcrossHistoryAndChangingCutsStartsFresh() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project),jobs = ConversationLocalEditRepository(project: project)
        let target = ConversationLocalEditTarget(projectID: project.id,versionID: UUID(),versionNumber: 1,timelineSHA256: String(repeating: "a",count: 64),engineVersion: "synthetic",duration: 120,aspect: "16:9",resolution: .fullHD)
        let text = "trim from 2 to 8; make it portrait at 720p"
        let command = ConversationLocalEditInstruction(target: target,textSHA256: TranscriptSourceMap.sha(Data(text.utf8)),patches: try #require(ConversationLocalEditInterpreter.parse(text)))
        let initial = try await repo.enqueue(text,id: UUID(),created: Date(),localEdit: command),id = UUID()
        _ = try await repo.beginTurn(id: id);_ = try await repo.updateTurn(id,reply: reply(initial.sessionID),state: .succeeded)
        _ = try await settle(repo,count: 127)
        let first = try #require(try await jobs.enqueueIdle(now: Date().addingTimeInterval(121)).jobs.last)
        let owner = UUID();_ = try await jobs.claim(first.id,owner: owner)
        let after = try await repo.enqueue("Make the pacing warmer",id: UUID(),created: Date())
        #expect(after.historyEpoch==1 && after.history?.localBase?.output.start==2)
        #expect(!first.request.matches(after))
        let superseded = try await jobs.finish(first.id,owner: owner,failure: "Synthetic late old attempt")
        #expect(superseded.jobs.first?.state == .superseded)
        let carried = try #require(try await jobs.enqueueIdle(now: Date().addingTimeInterval(121)).jobs.last)
        #expect(carried.request.output.start==2 && carried.request.output.end==8 && carried.request.output.aspect=="9:16" && carried.request.output.resolution == .hd)
        #expect(carried.request.commandIDs.isEmpty && carried.request.inherited != nil && carried.request.matches(after))
        let text2 = "use 1080p",command2 = ConversationLocalEditInstruction(target: target,textSHA256: TranscriptSourceMap.sha(Data(text2.utf8)),patches: try #require(ConversationLocalEditInterpreter.parse(text2)))
        _ = try await repo.enqueue(text2,id: UUID(),created: Date(),localEdit: command2,historyEpoch: 1)
        let folded = try #require(try await jobs.enqueueIdle(now: Date().addingTimeInterval(121)).jobs.last)
        #expect(folded.request.output.start==2 && folded.request.output.end==8 && folded.request.output.aspect=="9:16" && folded.request.output.resolution == .fullHD)
        let other = ConversationLocalEditTarget(projectID: project.id,versionID: UUID(),versionNumber: 2,timelineSHA256: String(repeating: "b",count: 64),engineVersion: "synthetic",duration: 120,aspect: "16:9",resolution: .fullHD)
        let command3 = ConversationLocalEditInstruction(target: other,textSHA256: TranscriptSourceMap.sha(Data(text2.utf8)),patches: try #require(ConversationLocalEditInterpreter.parse(text2)))
        _ = try await repo.enqueue(text2,id: UUID(),created: Date(),localEdit: command3,historyEpoch: 1)
        let fresh = try #require(try await jobs.enqueueIdle(now: Date().addingTimeInterval(121)).jobs.last)
        #expect(fresh.request.output.start==0 && fresh.request.output.end==nil && fresh.request.output.aspect=="16:9" && fresh.request.inherited==nil)
        _ = try await repo.enqueue(text2,id: UUID(),created: Date(),localEdit: command2,historyEpoch: 1)
        let backToA = try #require(try await jobs.enqueueIdle(now: Date().addingTimeInterval(121)).jobs.last)
        #expect(backToA.request.target==target && backToA.request.output.start==0 && backToA.request.output.end==nil && backToA.request.output.aspect=="16:9" && backToA.request.inherited==nil)

    }
    @Test func onlyExactConsumedDraftLineageCanContinueAcrossItsOwnRollover() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project);_ = try await settle(repo,count: 128)
        var submitted = LiveConversationDocument.Draft.empty();submitted.text = "Submitted boundary"
        _ = try await repo.saveDraft(submitted);_ = try await repo.submitDraft(submitted,expected: submitted)
        var newer = submitted;newer.revision += 1;newer.text = "Typed during boundary save"
        let saved = try await repo.saveDraft(newer,expected: submitted),normalized = try #require(saved.draft)
        #expect(normalized.historyEpoch==1 && normalized.sameWordsAndRevision(as: newer))
        #expect(try await repo.saveDraft(newer,expected: submitted).revision==saved.revision)
        var newest = newer;newest.revision += 1;newest.text = "Typed during normalized acknowledgement"
        let next = try await repo.saveDraft(newest,expected: normalized)
        #expect(next.draft?.text==newest.text && next.draft?.historyEpoch==1)
        var unknown = LiveConversationDocument.Draft.empty();unknown.text = "Unrelated old window"
        await #expect(throws: LiveConversationDraftConflict.self) { _ = try await repo.saveDraft(unknown) }
        var forged = submitted;forged.text = "Incorrect consumed words"
        await #expect(throws: LiveConversationDraftConflict.self) { _ = try await repo.saveDraft(newer,expected: forged) }
        #expect(try await repo.load().draft==next.draft)
    }
    @Test func invalidIncomingEpochsRefuseWithoutIndexingArchivesOrChangingWords() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project),saved = try await settle(repo,count: 129)
        for epoch in [-1,Int.min,4097,Int.max] {
            var draft = LiveConversationDocument.Draft.empty();draft.text = "Refused invalid epoch";draft.historyEpoch = epoch
            await #expect(throws: (any Error).self) { _ = try await repo.saveDraft(draft) }
            await #expect(throws: (any Error).self) { _ = try await repo.submitDraft(draft,expected: nil) }
        }
        #expect(try await repo.load()==saved)
    }
    @Test func abortAfterArchiveBeforeHeadPublicationLeavesOldHistoryUsableAndRetryPublishesOnlyItsOwnArchive() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project),before = try await settle(repo,count: 128)
        let pointer = project.folder.appendingPathComponent(".clauto/live-conversation.json"),bytes = try Data(contentsOf: pointer)
        var prepared = before
        do {
            let lease = try ProjectMutationLease.acquire(project);defer { withExtendedLifetime(lease) {} }
            try ConversationHistoryStore.rollIfNeeded(&prepared,state: lease.root.child(".clauto"))
            // Simulated process abort at this exact boundary: do not publish.
        }
        let orphan = try #require(prepared.history?.references.last)
        #expect(try Data(contentsOf: pointer)==bytes && prepared.historyEpoch==1)
        #expect(try await LiveConversationRepository(project: project).load()==before)
        let committed = try await repo.enqueue("Retry after simulated abort",id: UUID(),created: Date())
        #expect(committed.history?.references.last?.sha256==orphan.sha256 && committed.history?.references.last?.id != orphan.id && committed.messages.count==1)
        #expect(try await repo.archivedWindow(epoch: 0).messages==before.messages)
    }
    @Test func bytePressureRollsBeforeCountLimitAndRetainsEveryReply() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project)
        for n in 0..<3 {
            let current = try await repo.enqueue("Large synthetic response \(n)",id: UUID(),created: Date()),id = UUID()
            _ = try await repo.beginTurn(id: id)
            _ = try await repo.updateTurn(id,reply: reply(current.sessionID,text: String(repeating: "x",count: 850_000)),state: .succeeded)
        }
        let before = try await repo.load();#expect(before.messages.count==3 && before.historyEpoch==0)
        let next = try await repo.enqueue("After large replies",id: UUID(),created: Date())
        #expect(next.historyEpoch==1 && next.messages.count==1 && next.schemaVersion==2)
        #expect(try await repo.archivedWindow(epoch: 0).turns.map(\.text)==before.turns.map(\.text))
    }

    @MainActor @Test func newTypingDuringOwnedRolloverStaysEditableAndSavedWithoutFalseWindowConflict() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project);_ = try await settle(repo,count: 128)
        var targetRequested = false,releaseTarget = false
        let target = ConversationLocalEditTarget(projectID: project.id,versionID: UUID(),versionNumber: 1,timelineSHA256: String(repeating: "a",count: 64),engineVersion: "synthetic",duration: 120,aspect: "16:9",resolution: .fullHD)
        let controller = LiveConversationController(project: project,clientLocator: { nil },localTarget: {
            targetRequested = true
            while !releaseTarget { try await Task.sleep(for: .milliseconds(2)) };return target
        })
        await controller.load();controller.edit("use 720p")
        let sending = Task { await controller.submit() }
        for _ in 0..<1000 { if targetRequested { break };try await Task.sleep(for: .milliseconds(2)) }
        #expect(targetRequested)
        controller.edit("use 1080p");releaseTarget = true
        #expect(await sending.value)
        await controller.retryStorage()
        #expect(!controller.draftConflict && !controller.draftDirty && controller.draft.text=="use 1080p" && controller.draft.historyEpoch==1)
        #expect(try await repo.load().draft==controller.draft)
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func reopenedComposerUsesCurrentEpochAndProviderResumesWithoutResendingArchives() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project),prior = try await settle(repo,count: 128),transport = HistoryReplyFixture()
        let controller = LiveConversationController(project: project,syntheticFactory: { transport })
        #expect(!controller.canSend)
        await controller.load();controller.edit("Only this new explicit message")
        #expect(await controller.submit())
        for _ in 0..<2000 {
            if controller.document?.turns.last?.state == .succeeded { break };try await Task.sleep(for: .milliseconds(2))
        }
        let request = try #require(await transport.requests.first)
        #expect(request.sessionID==prior.sessionID && request.resume && request.prompt=="Only this new explicit message")
        #expect(controller.document?.historyEpoch==1 && controller.document?.messages.count==1)
        #expect(await controller.flushForExit())
        let reopened = LiveConversationController(project: project,clientLocator: { nil });await reopened.load()
        reopened.edit("Fresh current-epoch draft");await reopened.retryStorage()
        #expect(reopened.draft.historyEpoch==1 && !reopened.draftConflict && !reopened.draftDirty)
        #expect(await reopened.flushForExit())
    }

    @MainActor @Test func aRetiredRevisionCannotAcknowledgeDifferentUnsubmittedWords() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project);_ = try await settle(repo,count: 128)
        var base = LiveConversationDocument.Draft.empty();base.text = "Shared unsent base"
        _ = try await repo.saveDraft(base)
        let a = LiveConversationController(project: project,clientLocator: { nil }),b = LiveConversationController(project: project,clientLocator: { nil })
        await a.load();await b.load();a.edit("A's unsaved unique words")
        b.edit("B's second revision");b.edit("B's submitted third revision")
        #expect(await b.submit())
        #expect(b.document?.historyEpoch==1)
        await a.retryStorage()
        #expect(a.draftDirty && a.draftConflict && a.draft.text=="A's unsaved unique words")
        #expect(!(await a.flushForExit()))
        await a.keepBothDrafts()
        #expect(try await repo.load().recoveredDrafts?.contains(where: { $0.draft.text=="A's unsaved unique words" })==true)
        #expect(await a.flushForExit());#expect(await b.flushForExit())
    }

}
