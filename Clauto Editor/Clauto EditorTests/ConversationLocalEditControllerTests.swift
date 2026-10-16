import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor LocalEditPhysicalProbe {
    struct Call: Sendable { let id: UUID;let request: ConversationLocalEditRequest }
    private(set) var calls: [Call] = []
    private(set) var cancellationRequests: [UUID] = []
    private var waiting: [UUID:CheckedContinuation<DerivedCut,Error>] = [:]
    func execute(_ id: UUID,request: ConversationLocalEditRequest) async throws -> DerivedCut {
        calls.append(.init(id: id,request: request))
        return try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }
    func cancel(_ id: UUID) { cancellationRequests.append(id) }
    func abortAll() {
        let values = Array(waiting.values);waiting.removeAll()
        for value in values { value.resume(throwing: CancellationError()) }
    }
    func complete(_ id: UUID) throws {
        guard let call = calls.first(where: { $0.id==id }),let continuation = waiting.removeValue(forKey: id) else { throw ProjectFailure.invalidProject }
        continuation.resume(returning: .init(id: UUID(),projectID: call.request.projectID,parentVersionID: call.request.target.versionID,
            parentTimelineSHA256: call.request.target.timelineSHA256,request: call.request.output,recipeSHA256: String(repeating: "e",count: 64)))
    }
}
private struct ControlledLocalEditWorker: ConversationLocalEditExecuting {
    let probe: LocalEditPhysicalProbe
    let id = UUID()
    func execute(_ request: ConversationLocalEditRequest,project: Project,engine: URL,onLine: @escaping @Sendable (ProcessLine) async -> Void) async throws -> DerivedCut {
        // Protocol fixture intentionally stays physically occupied after cancel,
        // until the test releases it. This is not codec/media verification.
        try await probe.execute(id,request: request)
    }
    func cancel() async { await probe.cancel(id) }
}

@MainActor struct ConversationLocalEditControllerTests {
    private func fixture() async throws -> (URL,URL,Project,ConversationLocalEditTarget) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-local-controller-protocol-"+UUID().uuidString),engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine,withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic local controller protocol",root: root.appendingPathComponent("projects"),engine: engine,engineVersion: "synthetic-engine")
        return (root,engine,project,.init(projectID: project.id,versionID: UUID(),versionNumber: 2,timelineSHA256: String(repeating: "a",count: 64),engineVersion: "synthetic-engine",duration: 30,aspect: "16:9",resolution: .fullHD))
    }
    private func send(_ text: String,target: ConversationLocalEditTarget,to repository: LiveConversationRepository) async throws -> LiveConversationDocument {
        let instruction = ConversationLocalEditInstruction(target: target,textSHA256: TranscriptSourceMap.sha(Data(text.utf8)),patches: try #require(ConversationLocalEditInterpreter.parse(text)))
        return try await repository.enqueue(text,id: UUID(),created: Date().addingTimeInterval(-1),localEdit: instruction)
    }
    private func wait(_ ready: @MainActor () async -> Bool) async throws {
        for _ in 0..<1000 { if await ready() { return };try await Task.sleep(for: .milliseconds(5)) }
        throw WorkflowFailure.invalid("Synthetic local controller timed out")
    }
    private func withCleanup(_ probe: LocalEditPhysicalProbe,controller: ConversationLocalEditController,body: @MainActor () async throws -> Void) async throws {
        do { try await body() }
        catch { await probe.abortAll();_ = await controller.flushForExit();throw error }
    }
    @Test func steeringCancelsAndJoinsTheOwnedPhysicalAttemptBeforeStartingTheNextIdleVersion() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),probe = LocalEditPhysicalProbe();var outputs: [DerivedCut] = []
        let controller = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,
            factory: { ControlledLocalEditWorker(probe: probe) },onExport: { outputs.append($0) })
        try await withCleanup(probe,controller: controller) {
        await controller.load();controller.observe(try await send("make it portrait",target: target,to: conversation),hasUnsentDraft: false)
        try await wait { await probe.calls.count==1 }
        let first = try #require(await probe.calls.first)
        controller.observe(try await send("make it landscape at 720p",target: target,to: conversation),hasUnsentDraft: false)
        try await wait { !(await probe.cancellationRequests).isEmpty }
        try await Task.sleep(for: .milliseconds(30))
        let heldCount = await probe.calls.count;#expect(heldCount==1 && controller.running)
        try await probe.complete(first.id)
        try await wait { await probe.calls.count==2 }
        let second = try #require(await probe.calls.last)
        #expect(second.request.output.aspect=="16:9" && second.request.output.resolution == .hd)
        try await probe.complete(second.id)
        try await wait { !controller.running && outputs.count==1 }
        #expect(controller.ledger?.jobs.map(\.state)==[.cancelled,.succeeded])
        #expect(controller.ledger?.jobs.first?.request.output.aspect=="9:16")
        #expect(await controller.flushForExit())
        }
    }
    @Test func unsentFeedbackPreventsIdleRenderingAndTheGlobalSlotCannotBeStolen() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),probe = LocalEditPhysicalProbe();var occupied = true;var admitted: UUID?;var released: UUID?
        let controller = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,
            factory: { ControlledLocalEditWorker(probe: probe) },admit: { id in guard !occupied else { return false };occupied = true;admitted = id;return true },release: { id in released = id;occupied = false })
        try await withCleanup(probe,controller: controller) {
        let document = try await send("make it portrait",target: target,to: conversation)
        await controller.load();controller.observe(document,hasUnsentDraft: true)
        try await Task.sleep(for: .milliseconds(30));#expect(await probe.calls.isEmpty)
        controller.observe(document,hasUnsentDraft: false)
        try await wait { controller.ledger?.jobs.first?.state == .queued }
        let notStarted = await probe.calls.isEmpty;#expect(notStarted && admitted==nil)
        occupied = false;controller.observe(document,hasUnsentDraft: false)
        try await wait { await probe.calls.count==1 }
        let call = try #require(await probe.calls.first);try await probe.complete(call.id)
        try await wait { !controller.running && released != nil }
        #expect(admitted==released && !occupied)
        #expect(await controller.flushForExit())
        }
    }
    @Test func failedTerminalPersistenceRetainsTheExactResultAndBlocksQuitUntilItsOriginalRootReturns() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),probe = LocalEditPhysicalProbe()
        let controller = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,factory: { ControlledLocalEditWorker(probe: probe) })
        try await withCleanup(probe,controller: controller) {
        await controller.load();controller.observe(try await send("make it portrait",target: target,to: conversation),hasUnsentDraft: false)
        try await wait { await probe.calls.count==1 }
        let call = try #require(await probe.calls.first),preserved = project.folder.appendingPathExtension("preserved")
        try FileManager.default.moveItem(at: project.folder,to: preserved);try FileManager.default.copyItem(at: preserved,to: project.folder)
        let replacementLedger = try Data(contentsOf: project.folder.appendingPathComponent(".clauto/local-edit-jobs.json"))
        try await probe.complete(call.id)
        try await wait { !controller.running && controller.savingPendingResult }
        #expect(!(await controller.flushForExit()))
        #expect(try Data(contentsOf: project.folder.appendingPathComponent(".clauto/local-edit-jobs.json"))==replacementLedger)
        let replacement = project.folder.appendingPathExtension("replacement")
        try FileManager.default.moveItem(at: project.folder,to: replacement);try FileManager.default.moveItem(at: preserved,to: project.folder)
        await controller.retrySaving()
        #expect(!controller.savingPendingResult && controller.ledger?.jobs.last?.state == .succeeded)
        #expect(await controller.flushForExit())
        }
    }
    @Test func composerSubmitsExactCommandsToLocalWorkEvenWhenTheProviderIsUnavailable() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let probe = LocalEditPhysicalProbe();var outputs: [DerivedCut] = []
        let updates = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,
            factory: { ControlledLocalEditWorker(probe: probe) },onExport: { outputs.append($0) })
        let conversation = LiveConversationController(project: project,clientLocator: { nil },localUpdates: updates,localTarget: { target })
        try await withCleanup(probe,controller: updates) {
            await conversation.load();conversation.edit("make it portrait at 720p")
            #expect(await conversation.submit())
            try await wait { await probe.calls.count==1 }
            let call = try #require(await probe.calls.first)
            #expect(call.request.target==target && call.request.output.aspect=="9:16" && call.request.output.resolution == .hd)
            #expect(!conversation.connected && conversation.document?.messages.first?.localEdit?.target==target)
            #expect(conversation.draft.text.isEmpty)
            try await probe.complete(call.id);try await wait { !updates.running && outputs.count==1 }
            #expect(await conversation.flushForExit())
        }
    }
    @Test func textOnlyFeedbackIsNotAnEditAndTypingANewerDraftImmediatelySteersTheOwnedWorker() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let probe = LocalEditPhysicalProbe()
        let updates = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,factory: { ControlledLocalEditWorker(probe: probe) })
        let conversation = LiveConversationController(project: project,clientLocator: { nil },localUpdates: updates,localTarget: { target })
        try await withCleanup(probe,controller: updates) {
            await conversation.load();conversation.edit("Please make the story more interesting")
            #expect(await conversation.submit());try await Task.sleep(for: .milliseconds(25))
            #expect(conversation.document?.messages.first?.localEdit==nil)
            #expect(await probe.calls.isEmpty)
            conversation.edit("make it portrait");#expect(await conversation.submit())
            try await wait { await probe.calls.count==1 };let call = try #require(await probe.calls.first)
            conversation.edit("New unsent words remain in the composer")
            try await wait { !(await probe.cancellationRequests).isEmpty }
            try await probe.complete(call.id);try await wait { !updates.running }
            #expect(updates.ledger?.jobs.last?.state == .cancelled)
            #expect(conversation.draft.text=="New unsent words remain in the composer")
            #expect(await conversation.flushForExit())
            #expect(try await LiveConversationRepository(project: project).load().draft?.text==conversation.draft.text)
        }
    }
    @Test func explicitRetryUsesTheSameSavedRequestAndRefusesToSkipNewerFeedback() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),repository = ConversationLocalEditRepository(project: project)
        _ = try await send("make it portrait",target: target,to: conversation)
        let queued = try await repository.enqueueIdle(idleInterval: 0),first = try #require(queued.jobs.first),owner = UUID()
        _ = try await repository.claim(first.id,owner: owner)
        _ = try await repository.finish(first.id,owner: owner,failure: "Synthetic failure")
        let retried = try await repository.retry(first.id)
        #expect(retried.jobs.count==2 && retried.jobs.last?.state == .queued && retried.jobs.last?.request==first.request)
        let second = try #require(retried.jobs.last);_ = try await repository.claim(second.id,owner: owner)
        _ = try await repository.finish(second.id,owner: owner,cancelled: true)
        _ = try await send("make it landscape",target: target,to: conversation)
        await #expect(throws: (any Error).self) { _ = try await repository.retry(second.id) }
    }

    @Test func retryOfAnAlreadyPublishedMessageReportsItsOriginalCutRatherThanANewerTarget() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let newer = ConversationLocalEditTarget(projectID: project.id,versionID: UUID(),versionNumber: 3,timelineSHA256: String(repeating: "b",count: 64),engineVersion: target.engineVersion,duration: 30,aspect: "16:9",resolution: .fullHD)
        let updates = ConversationLocalEditController(project: project,engine: engine)
        let controller = LiveConversationController(project: project,clientLocator: { nil },localUpdates: updates,localTarget: { newer })
        await controller.load();controller.edit("make it portrait")
        let snapshot = controller.draft,instruction = ConversationLocalEditInstruction(target: target,textSHA256: TranscriptSourceMap.sha(Data(snapshot.text.utf8)),patches: try #require(ConversationLocalEditInterpreter.parse(snapshot.text)))
        _ = try await LiveConversationRepository(project: project).submitDraft(snapshot,expected: nil,localEdit: instruction)
        #expect(await controller.submit())
        #expect(controller.document?.messages.first?.localEdit?.target==target)
        #expect(controller.localEditNotice?.contains("saved v2")==true)
        #expect(await controller.flushForExit())
    }

    @Test func quitJoinsAnOwnedRetryAndItsLateAcknowledgementCannotResumeRendering() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),repository = ConversationLocalEditRepository(project: project),probe = LocalEditPhysicalProbe()
        let document = try await send("make it portrait",target: target,to: conversation)
        let job = try #require(try await repository.enqueueIdle(idleInterval: 0).jobs.last),owner = UUID()
        _ = try await repository.claim(job.id,owner: owner);_ = try await repository.finish(job.id,owner: owner,failure: "Synthetic retry fixture")
        let updates = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,factory: { ControlledLocalEditWorker(probe: probe) })
        try await withCleanup(probe,controller: updates) {
            await updates.load();updates.observe(document,hasUnsentDraft: false)
            var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project)
            let retry = Task { await updates.retryExport() }
            try await Task.sleep(for: .milliseconds(25));#expect(updates.hasPendingWork)
            var quitFinished = false
            let quit = Task { let value = await updates.flushForExit();quitFinished = true;return value }
            try await Task.sleep(for: .milliseconds(25));#expect(!quitFinished)
            await updates.retryExport() // duplicate click cannot append another job
            withExtendedLifetime(lease) {};lease = nil
            await retry.value;#expect(await quit.value)
            try await Task.sleep(for: .milliseconds(25))
            #expect(updates.paused && !updates.hasPendingWork && updates.error==nil)
            #expect(await probe.calls.isEmpty)
            let after = try await repository.load();#expect(after.jobs.count==2 && after.jobs.last?.state == .queued)
        }
    }
    @Test func unsentSteeringDuringAWaitingTerminalSaveCannotPublishAnOldCurrentResult() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let probe = LocalEditPhysicalProbe();var outputs: [DerivedCut] = []
        let updates = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,
            factory: { ControlledLocalEditWorker(probe: probe) },onExport: { outputs.append($0) })
        let conversation = LiveConversationController(project: project,clientLocator: { nil },localUpdates: updates,localTarget: { target })
        try await withCleanup(probe,controller: updates) {
            await conversation.load();conversation.edit("make it portrait");#expect(await conversation.submit())
            try await wait { await probe.calls.count==1 };let call = try #require(await probe.calls.first)
            var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project)
            try await probe.complete(call.id);try await wait { updates.savingPendingResult }
            conversation.edit("Newer unsent feedback") // its 250ms autosave is not the admission gate
            withExtendedLifetime(lease) {};lease = nil
            try await wait { !updates.running }
            #expect(outputs.isEmpty && updates.ledger?.jobs.last?.state == .cancelled)
            #expect(!updates.latestMatchesFeedback && conversation.draft.text=="Newer unsent feedback")
            #expect(await conversation.flushForExit())
            #expect(try await LiveConversationRepository(project: project).load().draft?.text=="Newer unsent feedback")
        }
    }
    @Test func quitWhileACompletedResultWaitsForItsSaveJoinsAndRetainsTheResult() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let probe = LocalEditPhysicalProbe();var outputs: [DerivedCut] = []
        let conversation = LiveConversationRepository(project: project)
        let updates = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,
            factory: { ControlledLocalEditWorker(probe: probe) },onExport: { outputs.append($0) })
        try await withCleanup(probe,controller: updates) {
            await updates.load();updates.observe(try await send("make it portrait",target: target,to: conversation),hasUnsentDraft: false)
            try await wait { await probe.calls.count==1 };let call = try #require(await probe.calls.first)
            var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project)
            try await probe.complete(call.id);try await wait { updates.savingPendingResult }
            var quitFinished = false
            let quit = Task { let value = await updates.flushForExit();quitFinished = true;return value }
            try await Task.sleep(for: .milliseconds(25));#expect(!quitFinished)
            withExtendedLifetime(lease) {};lease = nil
            #expect(await quit.value)
            #expect(outputs.count==1 && updates.ledger?.jobs.last?.state == .succeeded)
        }
    }

    @Test func overlappingResultSaveRetriesShareOneAcknowledgementAndQuitJoinsIt() async throws {
        let (root,engine,project,target) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let conversation = LiveConversationRepository(project: project),probe = LocalEditPhysicalProbe();var outputs: [DerivedCut] = []
        let controller = ConversationLocalEditController(project: project,engine: engine,idleInterval: 0.01,
            factory: { ControlledLocalEditWorker(probe: probe) },onExport: { outputs.append($0) })
        try await withCleanup(probe,controller: controller) {
            await controller.load();controller.observe(try await send("make it portrait",target: target,to: conversation),hasUnsentDraft: false)
            try await wait { await probe.calls.count==1 };let call = try #require(await probe.calls.first)
            let preserved = project.folder.appendingPathExtension("preserved"),replacement = project.folder.appendingPathExtension("replacement")
            try FileManager.default.moveItem(at: project.folder,to: preserved);try FileManager.default.copyItem(at: preserved,to: project.folder)
            let foreignLedger = try Data(contentsOf: project.folder.appendingPathComponent(".clauto/local-edit-jobs.json"))
            try await probe.complete(call.id);try await wait { !controller.running && controller.savingPendingResult }
            try FileManager.default.moveItem(at: project.folder,to: replacement);try FileManager.default.moveItem(at: preserved,to: project.folder)
            var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project)
            let first = Task { await controller.retrySaving() }
            try await Task.sleep(for: .milliseconds(25))
            let second = Task { await controller.retrySaving() }
            var quitFinished = false
            let quit = Task { let value = await controller.flushForExit();quitFinished = true;return value }
            try await Task.sleep(for: .milliseconds(25));#expect(!quitFinished && controller.hasPendingWork)
            withExtendedLifetime(lease) {};lease = nil
            await first.value;await second.value;#expect(await quit.value)
            #expect(outputs.count==1 && controller.ledger?.jobs.last?.state == .succeeded)
            #expect(!controller.hasPendingWork && !controller.savingPendingResult)
            #expect(try Data(contentsOf: replacement.appendingPathComponent(".clauto/local-edit-jobs.json"))==foreignLedger)
        }
    }

}
