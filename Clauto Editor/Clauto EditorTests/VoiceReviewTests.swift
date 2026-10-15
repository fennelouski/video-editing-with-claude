import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor PausedVoiceProcessor: VoiceCandidateProcessing {
    var calls = 0
    var waiting: CheckedContinuation<Void, Never>?
    func prepare(_ candidate: VoiceRevisionCandidate, directives: [VoiceCandidateDirective]) async throws -> [VoiceCandidateDirective] {
        calls += 1
        if calls == 1 { await withCheckedContinuation { waiting = $0 } }
        return directives
    }
    func release() { waiting?.resume(); waiting = nil }
}
private actor FailsOnceVoiceProcessor: VoiceCandidateProcessing {
    var calls = 0
    func prepare(_ candidate: VoiceRevisionCandidate, directives: [VoiceCandidateDirective]) async throws -> [VoiceCandidateDirective] {
        calls += 1
        if calls == 1 { throw WorkflowFailure.invalid("Mock local preparation failed") }
        return directives
    }
}

private actor MockVoiceProvider: VoiceReviewDictating {
    var starts = 0
    var microphoneRequests = 0
    var speechRequests = 0
    var stops = 0
    var holdStart = false
    var holdStop = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var stopWaiter: CheckedContinuation<Void, Never>?
    var output: AsyncStream<VoiceDictationEvent>.Continuation?
    var finalEvents: [VoiceDictationEvent] = []
    func access(locale: String) async -> VoiceReviewAccess { .init(microphone: .authorized, speech: .authorized, installedModel: true, locale: locale) }
    func devices() async -> [VoiceInputDevice] { [.init(id: "mock-device", name: "Mock microphone")] }
    func requestMicrophonePermission() async -> Bool { microphoneRequests += 1; return true }
    func requestSpeechPermission() async -> Bool { speechRequests += 1; return true }
    func configure(holdStart: Bool = false, holdStop: Bool = false, finals: [VoiceDictationEvent] = []) { self.holdStart = holdStart; self.holdStop = holdStop; finalEvents = finals }
    func start(session: UUID, deviceUID: String, locale: String) async throws -> AsyncStream<VoiceDictationEvent> {
        starts += 1
        if holdStart { await withCheckedContinuation { startWaiter = $0 } }
        let (stream, continuation) = AsyncStream<VoiceDictationEvent>.makeStream(); output = continuation
        return stream
    }
    func stop(session: UUID, cancel: Bool) async {
        stops += 1
        if holdStop { await withCheckedContinuation { stopWaiter = $0 } }
        if !cancel { for event in finalEvents { output?.yield(event) } }
        output?.yield(.ended); output?.finish(); output = nil
    }
    func emit(_ event: VoiceDictationEvent) { output?.yield(event) }
    func releaseStart() { holdStart = false; startWaiter?.resume(); startWaiter = nil }
    func releaseStop() { holdStop = false; stopWaiter?.resume(); stopWaiter = nil }
}

private actor VoiceRelayProbe {
    var values: [Int] = []
    var timedOut = false
    func append(_ value: Int) { values.append(value) }
    func timeout() { timedOut = true }
}

struct VoiceReviewTests {
    private func target(project: Project, number: Int = 1) throws -> VoiceReviewTarget {
        let base = String(format: "cuts/v%03d/", number)
        for name in ["exports/cut.fcpxml","exports/cut.mp4","clauto-version.json","inputs/brief.md","inputs/script/approved.md","plan/cut.plan.json"] {
            let path = project.folder.appendingPathComponent(base+name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("Synthetic voice review \(number) "+name).utf8).write(to: path)
        }
        return .init(id: UUID(), projectID: project.id, versionID: UUID(), versionNumber: number,
            versionMetadataSHA256: try VoiceReviewProvenance.inspect(base+"clauto-version.json", project: project).sha256,
            timeline: try VoiceReviewProvenance.inspect(base+"exports/cut.fcpxml", project: project),
            preview: try VoiceReviewProvenance.inspect(base+"exports/cut.mp4", project: project),
            approvedPlanSHA256: try VoiceReviewProvenance.inspect(base+"plan/cut.plan.json", project: project).sha256, approvedPlanPath: base+"plan/cut.plan.json",
            approvedScriptSHA256: try VoiceReviewProvenance.inspect(base+"inputs/script/approved.md", project: project).sha256, approvedScriptPath: base+"inputs/script/approved.md",
            approvedBriefSHA256: try VoiceReviewProvenance.inspect(base+"inputs/brief.md", project: project).sha256, engineVersion: "synthetic", duration: 120)
    }
    private func fixture() async throws -> (URL, Project, VoiceReviewRepository, VoiceReviewTarget) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-voice-\(UUID())")
        let engine = root.appendingPathComponent("engine"); try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic voice review", root: root, engine: engine, engineVersion: "synthetic")
        let repository = try VoiceReviewRepository(project: project), bound = try target(project: project)
        _ = try await repository.register(bound)
        return (root,project,repository,bound)
    }
    private func session(target: VoiceReviewTarget) throws -> VoiceReviewSession {
        var value = VoiceReviewSession(id: UUID(), attemptID: UUID(), deviceUID: "mock microphone", locale: "en-US", ownerProcessID: 0, created: Date())
        let epoch = UUID()
        try value.observe(host: 100, seconds: 10, rate: 1, targetID: target.id, epoch: epoch, kind: .versionChanged)
        try value.observe(host: 110, seconds: 20, rate: 1, targetID: target.id, epoch: epoch, kind: .sample)
        try value.captured(audioStart: 0, duration: 10, hostStart: 100)
        return value
    }
    private func seed(_ repository: VoiceReviewRepository, target: VoiceReviewTarget) async throws -> (UUID, UUID) {
        let id = UUID(), attempt = UUID(), epoch = UUID()
        _ = try await repository.begin(id: id, attempt: attempt, deviceUID: "mock-microphone", locale: "en-US")
        _ = try await repository.observe(session: id, host: 100, seconds: 10, rate: 1, target: target.id, epoch: epoch, kind: .versionChanged)
        _ = try await repository.observe(session: id, host: 110, seconds: 20, rate: 1, target: target.id, epoch: epoch, kind: .sample)
        _ = try await repository.captured(session: id, attempt: attempt, audioStart: 0, duration: 10, hostStart: 100)
        return (id,attempt)
    }
    private func final(_ repository: VoiceReviewRepository, session: UUID, attempt: UUID, key: String = "one", start: Double = 2, text: String = "I like this moment") async throws -> VoiceReviewDocument {
        try await repository.speech(.init(segmentID: key, text: text, isFinal: true, audioStart: start, audioEnd: start+1), session: session, attempt: attempt)
    }

    @Test func delayedASRUsesCapturedSpeechOnsetAndStableIDRatherThanCompletionPlayhead() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        let partial = try await repository.speech(.init(segmentID: "same", text: "I like", isFinal: false, audioStart: 2, audioEnd: 2.5), session: id, attempt: attempt)
        let finished = try await final(repository, session: id, attempt: attempt, key: "same")
        #expect(finished.notes.count == 1 && finished.notes[0].id == partial.notes[0].id)
        #expect(finished.notes[0].onset?.seconds == 12 && finished.notes[0].onset?.targetID == target.id)
        #expect(finished.notes[0].state == .ready && finished.notes[0].intent == .protect)
        let repeated = try await final(repository, session: id, attempt: attempt, key: "same")
        #expect(repeated.notes[0].revision == finished.notes[0].revision)
        #expect(finished.sequence > partial.sequence)
    }

    @Test func speechAcrossSeekPauseAndVersionSwitchRequiresExplicitResolution() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let next = try self.target(project: project, number: 2)
        for kind in [VoiceTransportKind.seekRequested,.pause,.versionChanged] {
            var original = try session(target: target)
            try original.observe(host: 103, seconds: 80, rate: 0, targetID: next.id, epoch: UUID(), kind: kind)
            var document = VoiceReviewDocument(projectID: project.id, targets: [target,next], sessions: [original])
            try document.speech(.init(segmentID: "spanning", text: "I like this", isFinal: true, audioStart: 2, audioEnd: 5), sessionID: original.id, attemptID: original.attemptID, now: Date())
            #expect(document.notes[0].onset?.targetID == target.id && document.notes[0].onset?.seconds == 12)
            #expect(document.notes[0].state == .needsResolution && !document.notes[0].issues.isEmpty)
        }
    }

    @Test func captureGapsDroppedClockPacketsAndMissingTimingNeverClampOrShiftNotes() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for gap in [false,true] {
            var original = try session(target: target); original.audio = []
            try original.captured(audioStart: gap ? 0 : 2, duration: 1, hostStart: 100)
            try original.captured(audioStart: gap ? 1 : 4, duration: 1, hostStart: 105)
            var document = VoiceReviewDocument(projectID: project.id, targets: [target], sessions: [original])
            try document.speech(.init(segmentID: "gap", text: "Keep this", isFinal: true, audioStart: gap ? 0.5 : 0, audioEnd: gap ? 1.5 : 1), sessionID: original.id, attemptID: original.attemptID, now: Date())
            #expect(document.notes[0].onset == nil && document.notes[0].state == .needsResolution)
            try document.speech(.init(segmentID: "unknown", text: "Keep this", isFinal: true, audioStart: nil, audioEnd: nil), sessionID: original.id, attemptID: original.attemptID, now: Date())
            #expect(document.notes[1].onset == nil && document.notes[1].state == .needsResolution)
        }
    }

    @Test func unannouncedPlayheadJumpNeverInventsContinuousCoverage() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var original = VoiceReviewSession(id: UUID(), attemptID: UUID(), deviceUID: "mock", locale: "en-US", ownerProcessID: 0, created: Date())
        let epoch = UUID()
        try original.observe(host: 100, seconds: 10, rate: 1, targetID: target.id, epoch: epoch, kind: .sample)
        try original.observe(host: 103, seconds: 80, rate: 1, targetID: target.id, epoch: epoch, kind: .sample)
        try original.observe(host: 110, seconds: 87, rate: 1, targetID: target.id, epoch: epoch, kind: .sample)
        try original.captured(audioStart: 0, duration: 10, hostStart: 100)
        var document = VoiceReviewDocument(projectID: project.id, targets: [target], sessions: [original])
        try document.speech(.init(segmentID: "jump", text: "Keep this", isFinal: true, audioStart: 2, audioEnd: 5), sessionID: original.id, attemptID: original.attemptID, now: Date())
        #expect(document.notes[0].state == .needsResolution)
        #expect(document.notes[0].onset == nil)
    }

    @Test func lateFinalAfterStopOrWrongAttemptCannotAttachToNewSession() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (old,attempt) = try await seed(repository, target: target)
        _ = try await repository.end(session: old, state: .stopped)
        let (new,nextAttempt) = try await seed(repository, target: target)
        _ = try await final(repository, session: old, attempt: attempt)
        _ = try await final(repository, session: new, attempt: attempt)
        #expect(try await repository.load().notes.isEmpty)
        #expect(try await final(repository, session: new, attempt: nextAttempt).notes.count == 1)
    }

    @Test func editsAndCancellationRetainASRHistoryAndRejectLateOverwrite() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        let document = try await final(repository, session: id, attempt: attempt)
        let note = document.notes[0]
        _ = try await repository.edit(note: note.id, expectedRevision: note.revision, text: "Keep the approved yeast explanation", intent: .protect,
            anchor: .init(targetID: target.id, seconds: 15, endSeconds: 18))
        let late = try await final(repository, session: id, attempt: attempt, text: "Remove the explanation")
        #expect(late.notes[0].text == "Keep the approved yeast explanation" && late.notes[0].transcript == note.transcript)
        #expect(late.notes[0].onset?.seconds == 12 && late.notes[0].resolvedAnchor?.seconds == 15)
        #expect(late.notes[0].history.contains { $0.source == "Late ASR ignored" })
        _ = try await repository.cancel(note: note.id)
        #expect(try await final(repository, session: id, attempt: attempt).notes[0].state == .cancelled)
        await #expect(throws: (any Error).self) { try await repository.edit(note: note.id, expectedRevision: 1, text: "stale", intent: .change, anchor: nil) }
    }

    @Test func conflictingLikesAndChangesAreVisibleAndNeverClaimedUntilResolved() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        _ = try await final(repository, session: id, attempt: attempt)
        let conflict = try await final(repository, session: id, attempt: attempt, key: "two", start: 2.1, text: "Remove this moment")
        #expect(conflict.notes.allSatisfy { $0.state == .needsResolution })
        #expect(try await repository.claim() == nil)
        _ = try await repository.cancel(note: conflict.notes[1].id)
        #expect(try await repository.claim()?.noteRevisions.map(\.id) == [conflict.notes[0].id])
    }

    @Test func persistedNotesAndCandidatesSurviveReopenWithoutChangingReviewedVersion() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let current = project.folder.appendingPathComponent("cuts/current.json"); try Data("prior current".utf8).write(to: current)
        let original = try Data(contentsOf: VoiceReviewProvenance.url(target.preview.relativePath, project: project))
        let (id,attempt) = try await seed(repository, target: target)
        _ = try await final(repository, session: id, attempt: attempt)
        try await VoiceCandidateWorker(repository: repository).drain()
        let loaded = try await VoiceReviewRepository(project: project).load()
        #expect(loaded.notes.count == 1 && loaded.candidates.count == 1 && loaded.candidates[0].state == .prepared)
        #expect(loaded.candidates[0].parent == target && !loaded.candidates[0].appliedToCut && !loaded.candidates[0].productionAuthorized)
        #expect(try Data(contentsOf: current) == Data("prior current".utf8))
        #expect(try Data(contentsOf: VoiceReviewProvenance.url(target.preview.relativePath, project: project)) == original)
    }

    @Test func editWhileProcessorAwaitsSupersedesStaleResultAndPreparesLatestRevision() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target), first = try await final(repository, session: id, attempt: attempt)
        let processor = PausedVoiceProcessor(), worker = VoiceCandidateWorker(repository: repository, processor: processor)
        let task = Task { try await worker.drain() }
        for _ in 0..<100 { if await processor.calls > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(await processor.calls == 1)
        _ = try await repository.edit(note: first.notes[0].id, expectedRevision: first.notes[0].revision, text: "Keep the new instruction", intent: .protect, anchor: nil)
        await processor.release(); try await task.value
        let loaded = try await repository.load()
        #expect(loaded.candidates.count == 2 && loaded.candidates[0].state == .superseded && loaded.candidates[1].state == .prepared)
        #expect(loaded.candidates[1].directives[0].text == "Keep the new instruction")
    }

    @Test func cancelWhileProcessorAwaitsCannotReviveNoteOrPublishCandidate() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target), first = try await final(repository, session: id, attempt: attempt)
        let processor = PausedVoiceProcessor(), worker = VoiceCandidateWorker(repository: repository, processor: processor)
        let task = Task { try await worker.drain() }
        for _ in 0..<100 { if await processor.calls > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(await processor.calls == 1)
        _ = try await repository.cancel(note: first.notes[0].id)
        await processor.release(); try await task.value
        #expect(try await repository.load().notes[0].state == .cancelled)
        #expect(try await repository.load().candidates.allSatisfy { $0.state != .prepared })
    }

    @Test func actualWorkerTaskCancellationReleasesLeaseAndCanRetryInSameProcess() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target), first = try await final(repository, session: id, attempt: attempt)
        let processor = PausedVoiceProcessor(), worker = VoiceCandidateWorker(repository: repository, processor: processor)
        let task = Task { try await worker.drain() }
        for _ in 0..<100 { if await processor.calls > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try #require(await processor.calls == 1)
        task.cancel(); await processor.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let stopped = try await repository.load()
        #expect(stopped.processingJobID == nil && stopped.notes[0].state == .failed)
        _ = try await repository.retry(note: first.notes[0].id); try await worker.drain()
        #expect(try await repository.load().candidates.last?.state == .prepared)
    }

    @Test func batchRetryKeepsPreviouslyPreparedProtectionsAsCandidateContext() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        _ = try await final(repository, session: id, attempt: attempt)
        try await VoiceCandidateWorker(repository: repository).drain()
        let withChange = try await final(repository, session: id, attempt: attempt, key: "later", start: 7, text: "Change this ending")
        let processor = FailsOnceVoiceProcessor(), worker = VoiceCandidateWorker(repository: repository, processor: processor)
        try await worker.drain()
        _ = try await repository.retry(note: withChange.notes[1].id)
        try await worker.drain()
        let latest = try #require(try await repository.load().candidates.last)
        #expect(latest.state == .prepared && latest.directives.count == 2)
        #expect(latest.directives.contains { $0.noteID == withChange.notes[0].id && $0.intent == .protect })
    }

    @Test func processingFailureRetriesWithoutMicrophoneAndRendersAreDebounced() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target), first = try await final(repository, session: id, attempt: attempt)
        let processor = FailsOnceVoiceProcessor(), worker = VoiceCandidateWorker(repository: repository, processor: processor)
        try await worker.drain(); #expect(try await repository.load().notes[0].state == .failed)
        _ = try await repository.retry(note: first.notes[0].id); try await worker.drain()
        let candidate = try #require(try await repository.load().candidates.last)
        #expect(candidate.state == .prepared && candidate.renderRequested == false)
        #expect(try await repository.requestRender(candidate: candidate.id, now: candidate.created).candidates.last?.renderRequested == false)
        let ready = try await repository.requestRender(candidate: candidate.id, now: candidate.renderNotBefore)
        #expect(ready.candidates.last?.renderRequested == true && ready.candidates.last?.productionAuthorized == false)
    }

    @Test func diskCorruptionAndChangedVersionFailBeforeDispatchAndPreservePreviousLedger() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        _ = try await final(repository, session: id, attempt: attempt)
        let ledger = project.folder.appendingPathComponent("notes/voice-review/ledger.json"), before = try Data(contentsOf: ledger)
        try Data("Changed preview".utf8).write(to: VoiceReviewProvenance.url(target.preview.relativePath, project: project))
        await #expect(throws: (any Error).self) { try await repository.claim() }
        #expect(try Data(contentsOf: ledger) == before)
        try Data("{broken".utf8).write(to: ledger)
        await #expect(throws: (any Error).self) { try await VoiceReviewRepository(project: project).load() }
    }
    @MainActor private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw WorkflowFailure.invalid("Mock voice-review condition timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor private func controller(project: Project, provider: MockVoiceProvider, target: VoiceReviewTarget, token: UUID = UUID(), seconds: Double = 10) async throws -> VoiceReviewController {
        let defaults = UserDefaults(suiteName: "ClautoVoiceReviewTests-" + UUID().uuidString)!
        let controller = try VoiceReviewController(project: project, provider: provider, defaults: defaults)
        await controller.load(); controller.chooseDevice("mock-device"); controller.willAttach(token)
        await controller.attach(target, token: token, sampler: { .init(host: 100, seconds: seconds, rate: 0, available: true) })
        return controller
    }

    @Test @MainActor func candidatePlaybackLeaseBlocksCaptureAndCannotBeginDuringStartRecordingOrStop() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try await controller(project: project,provider: provider,target: target)
        let preview = UUID()
        #expect(controller.beginCandidatePlayback(preview))
        #expect(!controller.canStart && !controller.canPresentCandidate)
        controller.start(); #expect(await provider.starts == 0)
        controller.endCandidatePlayback(UUID()); #expect(!controller.canStart)
        controller.endCandidatePlayback(preview); #expect(controller.canStart)
        await provider.configure(holdStart: true)
        controller.start()
        #expect(!controller.beginCandidatePlayback(UUID()))
        try await waitFor { await provider.starts == 1 }
        #expect(!controller.beginCandidatePlayback(UUID()))
        await provider.releaseStart()
        try await waitFor { controller.mode == .recording }
        #expect(!controller.beginCandidatePlayback(UUID()))
        let stopping = Task { await controller.stop() }
        await Task.yield()
        if controller.active || controller.canStop { #expect(!controller.beginCandidatePlayback(UUID())) }
        #expect(await stopping.value)
        #expect(controller.beginCandidatePlayback(preview))
        #expect(!controller.canStart)
        controller.endCandidatePlayback(preview)
        #expect(controller.canStart)
    }

    @Test @MainActor func openingAndReloadingNeverRecordOrRequestPermissionAndDeviceIsExplicit() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try await controller(project: project, provider: provider, target: target)
        await controller.load(); await controller.refreshAccess()
        #expect(await provider.starts == 0)
        #expect(await provider.microphoneRequests == 0)
        #expect(await provider.speechRequests == 0)
        #expect(controller.canStart)
        controller.chooseDevice("disconnected-device"); controller.start()
        #expect(await provider.starts == 0 && !controller.active)
        controller.chooseDevice("mock-device"); controller.start()
        try await waitFor { controller.mode == .recording }
        #expect(await provider.starts == 1)
        #expect(await controller.stop())
        #expect(await provider.microphoneRequests == 0)
        #expect(await provider.speechRequests == 0)
    }

    @Test @MainActor func immediateStartStopAndDelayedProviderStartAlwaysReleaseStartReservation() async throws {
        for delayed in [false,true] {
            let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let provider = MockVoiceProvider(), controller = try await controller(project: project, provider: provider, target: target)
            await provider.configure(holdStart: delayed)
            controller.start()
            if delayed { try await waitFor { await provider.starts == 1 } }
            let stopping = Task { await controller.stop(cancel: true) }
            if delayed { await provider.releaseStart() }
            #expect(await stopping.value)
            #expect(controller.canStart && !controller.hasPendingWork)
            controller.start(); try await waitFor { controller.mode == .recording }; _ = await controller.stop()
        }
    }

    @Test @MainActor func explicitPlayerTokenPreventsComparisonPlayerFromSupplyingAnchor() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), first = UUID(), second = UUID()
        let controller = try await controller(project: project, provider: provider, target: target, token: first, seconds: 10)
        #expect(controller.isAttached(to: first) && !controller.isAttached(to: second))
        // Merely displaying/binding a comparison cannot select it.
        await controller.attach(target, token: second, sampler: { .init(host: 100, seconds: 80, rate: 0, available: true) })
        controller.record(.init(host: 105, seconds: 85, rate: 1, available: true), token: second)
        controller.start(); try await waitFor { controller.mode == .recording }
        await provider.emit(.clock(audioStart: 0, duration: 3, hostStart: 100))
        controller.record(.init(host: 103, seconds: 10, rate: 0, available: true), token: first)
        await provider.emit(.speech(.init(segmentID: "selected-player", text: "I like this moment", isFinal: true, audioStart: 1, audioEnd: 2)))
        try await waitFor { controller.document.notes.first?.onset != nil }
        #expect(controller.document.notes[0].onset?.seconds == 10)
        _ = await controller.stop()
        controller.willAttach(second)
        await controller.attach(target, token: second, sampler: { .init(host: 200, seconds: 80, rate: 0, available: true) })
        #expect(controller.isAttached(to: second) && !controller.isAttached(to: first))
    }

    @Test @MainActor func stopDrainsBufferedFinalSpeechAndClockBeforeDurableTombstone() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), token = UUID()
        let controller = try await controller(project: project, provider: provider, target: target, token: token)
        await provider.configure(finals: [.clock(audioStart: 0, duration: 3, hostStart: 100), .speech(.init(segmentID: "final-on-stop", text: "Keep this", isFinal: true, audioStart: 1, audioEnd: 2)), .failure("Mock final relay warning")])
        controller.start(); try await waitFor { controller.mode == .recording }
        controller.record(.init(host: 103, seconds: 10, rate: 0, available: true), token: token)
        #expect(await controller.stop())
        #expect(controller.document.sessions.last?.state == .stopped)
        #expect(controller.document.sessions.last?.failure == "Mock final relay warning")
        #expect(controller.document.notes.count == 1 && controller.document.notes[0].isFinal)
        #expect(controller.document.notes[0].onset?.seconds == 10)
        #expect(await controller.flushForExit())
        let reopened = try await self.controller(project: project, provider: provider, target: target)
        #expect(reopened.error == "Mock final relay warning")
    }

    @Test @MainActor func failedIngressRemainsRetryableBeforeSessionClosesAndFinalTextSurvives() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try await controller(project: project, provider: provider, target: target)
        await provider.configure(holdStop: true)
        controller.start(); try await waitFor { controller.mode == .recording && controller.pendingWrites == 0 }
        let moved = project.folder.deletingLastPathComponent().appendingPathComponent("temporarily-disconnected")
        try FileManager.default.moveItem(at: project.folder, to: moved)
        await provider.emit(.speech(.init(segmentID: "disk-failed-final", text: "Protect this exact feedback", isFinal: true, audioStart: 1, audioEnd: 2)))
        try await waitFor { let stops = await provider.stops; return controller.unsavedActions > 0 && stops > 0 }
        try FileManager.default.moveItem(at: moved, to: project.folder)
        await provider.releaseStop()
        try await waitFor { controller.mode == .failed }
        #expect(controller.hasPendingWork && !controller.canStart)
        #expect(try await controller.repository.load().sessions.last?.state == .recording)
        await controller.retryStorage()
        #expect(controller.unsavedActions == 0 && controller.document.notes.count == 1)
        #expect(controller.document.notes[0].text == "Protect this exact feedback")
        #expect(controller.document.notes[0].state == .needsResolution) // Missing mic clock is visible.
        #expect(controller.document.sessions.last?.state == .cancelled)
        #expect(await controller.flushForExit())
    }

    @Test @MainActor func staleDraftSaveFailsWithoutLosingDraftOrPoisoningStorageRetry() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        let original = try await final(repository, session: id, attempt: attempt).notes[0]
        _ = try await repository.end(session: id, state: .stopped)
        let provider = MockVoiceProvider(), controller = try await controller(project: project, provider: provider, target: target)
        #expect(await controller.edit(original, text: "Keep the edited moment", intent: .protect, anchor: nil))
        #expect(!(await controller.edit(original, text: "Keep stale draft", intent: .protect, anchor: nil)))
        #expect(controller.unsavedActions == 0 && controller.document.notes[0].text == "Keep the edited moment")
        #expect(controller.error != nil)
        _ = await controller.flushForExit()
    }

    @Test func candidateInstructionsAreSeparateImmutableAndTamperingBlocksRenderIntent() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        _ = try await final(repository, session: id, attempt: attempt)
        try await VoiceCandidateWorker(repository: repository).drain()
        let candidate = try #require(try await repository.load().candidates.last)
        let path = try #require(candidate.instructionsRelativePath)
        #expect(candidate.instructionsSHA256 == (try VoiceReviewProvenance.inspect(path, project: project).sha256))
        try Data("tampered synthetic instructions".utf8).write(to: project.folder.appendingPathComponent(path))
        await #expect(throws: (any Error).self) { _ = try await repository.requestRender(candidate: candidate.id, now: Date().addingTimeInterval(10)) }
        #expect(try await repository.load().candidates.last?.renderRequested == false)
    }

    @Test func reviewedIdentityCannotBeRegisteredAgainAfterVersionOrMediaMutation() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let oldDocument = try await repository.load()
        try Data("Changed synthetic movie".utf8).write(to: project.folder.appendingPathComponent(target.preview.relativePath))
        await #expect(throws: (any Error).self) { _ = try await repository.register(target) }
        #expect(try await repository.load().targets.count == oldDocument.targets.count)
    }

    @Test @MainActor func draftTextTimingAndRevisionSurviveReopenWithoutChangingFinalizedInstructions() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        let original = try await final(repository, session: id, attempt: attempt).notes[0]
        _ = try await repository.end(session: id, state: .stopped)
        let provider = MockVoiceProvider(), first = try await controller(project: project, provider: provider, target: target)
        let draft = VoiceTranscriptDraft(noteID: original.id, text: "Keep my unsubmitted draft", intent: .change, targetID: target.id, start: "14", end: "18", baseRevision: original.revision)
        first.retainDraft(draft)
        #expect(await first.flushForExit())
        let second = try await controller(project: project, provider: provider, target: target)
        #expect(second.drafts[original.id] == draft)
        #expect(second.document.notes[0].text == original.text)
        #expect(await provider.starts == 0)
        second.discardDraft(original.id)
        #expect(await second.flushForExit())
        #expect(try await repository.load().drafts?.isEmpty == true)
    }

    @Test @MainActor func failedTerminalSaveStaysPendingUntilExplicitRetrySucceeds() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try await controller(project: project, provider: provider, target: target)
        controller.start(); try await waitFor { controller.mode == .recording && controller.pendingWrites == 0 }
        let moved = project.folder.deletingLastPathComponent().appendingPathComponent("terminal-disconnected")
        try FileManager.default.moveItem(at: project.folder, to: moved)
        #expect(!(await controller.stop()))
        #expect(controller.hasPendingWork && controller.canStop && !controller.canStart)
        try FileManager.default.moveItem(at: moved, to: project.folder)
        await controller.retryStorage()
        #expect(!controller.hasPendingWork && controller.canStart)
        #expect(controller.document.sessions.last?.state == .stopped)
    }

    @Test func cancellingOneNoteInAnActiveBatchReleasesAndRepreparesRemainingProtections() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        let first = try await final(repository, session: id, attempt: attempt).notes[0]
        _ = try await final(repository, session: id, attempt: attempt, key: "second", start: 6, text: "Remove this pause")
        let processor = PausedVoiceProcessor(), worker = VoiceCandidateWorker(repository: repository, processor: processor)
        let task = Task { try await worker.drain() }
        while await processor.calls == 0 { await Task.yield() }
        let other = try #require(try await repository.load().notes.last)
        _ = try await repository.cancel(note: other.id)
        await processor.release(); try await task.value
        let result = try await repository.load()
        #expect(result.processingJobID == nil)
        #expect(result.notes.first(where: { $0.id == first.id })?.state == .prepared)
        #expect(result.candidates.last?.directives.map(\.noteID) == [first.id])
    }

    @Test func simultaneousWorkersCannotClaimTheSameProjectAndNewNotesJoinNextCandidate() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        _ = try await final(repository, session: id, attempt: attempt)
        let processor = PausedVoiceProcessor(), worker = VoiceCandidateWorker(repository: repository, processor: processor)
        let first = Task { try await worker.drain() }
        while await processor.calls == 0 { await Task.yield() }
        _ = try await final(repository, session: id, attempt: attempt, key: "new-ready", start: 6, text: "Remove this pause")
        try await VoiceCandidateWorker(repository: repository).drain()
        #expect(try await repository.load().candidates.count == 1)
        await processor.release(); try await first.value
        let result = try await repository.load()
        #expect(result.processingJobID == nil && result.candidates.count == 2)
        #expect(result.candidates[0].state == .superseded && result.candidates[1].state == .prepared)
        #expect(result.candidates[1].directives.count == 2)
    }

    @Test func restartRecoversDeadCaptureAndProcessingOwnersWithoutStartingMicrophone() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository, target: target)
        _ = try await final(repository, session: id, attempt: attempt)
        let claim = try #require(try await repository.claim())
        var document = try await repository.load()
        let old = document.sessions[0]
        var interrupted = VoiceReviewSession(id: old.id, attemptID: old.attemptID, deviceUID: old.deviceUID, locale: old.locale, ownerProcessID: 999999, created: old.created)
        interrupted.audio = old.audio; interrupted.playhead = old.playhead; interrupted.events = old.events
        document.sessions[0] = interrupted
        document.candidates[0] = VoiceRevisionCandidate(id: claim.id, parent: claim.parent, noteRevisions: claim.noteRevisions, ownerProcessID: 999999, created: claim.created, renderNotBefore: claim.renderNotBefore)
        struct Envelope: Encodable { let sha256: String; let document: VoiceReviewDocument }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(document)
        try encoder.encode(Envelope(sha256: TranscriptSourceMap.sha(payload), document: document)).write(to: project.folder.appendingPathComponent("notes/voice-review/ledger.json"))
        let recovered = try await VoiceReviewRepository(project: project).recover()
        #expect(recovered.sessions[0].state == .interrupted && recovered.processingJobID == nil)
        #expect(recovered.candidates[0].state == .failed && recovered.notes[0].state == .failed)
    }

    @Test func adapterRelayDrainConsumesTailPacketsBeforeClosingAndCancelsHungStreamVisibly() async throws {
        let probe = VoiceRelayProbe()
        let (stream, output) = AsyncStream<Int>.makeStream()
        for value in 0..<100 { output.yield(value) }; output.finish()
        let relay = Task { for await value in stream { await probe.append(value) } }
        await VoiceRelayDrain.finish([relay]) { await probe.timeout() }
        #expect(await probe.values == Array(0..<100))
        #expect(await probe.timedOut == false)
        let (hung, holdOpen) = AsyncStream<Int>.makeStream()
        let hungRelay = Task { for await value in hung { await probe.append(value) } }
        await VoiceRelayDrain.finish([hungRelay], timeout: .milliseconds(10)) { await probe.timeout() }
        #expect(await probe.timedOut && hungRelay.isCancelled)
        holdOpen.finish()
    }

    @Test func asyncPreviewDurationReadCannotMixVersionMetadataOrApprovedArtifactSnapshots() async throws {
        for changed in ["clauto-version.json","plan/cut.plan.json","inputs/script/approved.md","inputs/brief.md","exports/cut.fcpxml","exports/cut.mp4"] {
            let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let folder = project.folder.appendingPathComponent("cuts/v001")
            let xml = Data("<fcpxml><library><event><project><sequence duration=\"120s\"/></project></event></library></fcpxml>".utf8)
            try xml.write(to: folder.appendingPathComponent("exports/cut.fcpxml"))
            try JSONSerialization.data(withJSONObject: ["saved_sha256":TranscriptSourceMap.sha(xml)]).write(to: folder.appendingPathComponent("exports/cut.snapshot.json"))
            let version = CutVersion(number: 1, label: "Synthetic voice race", engineVersion: "synthetic", runID: UUID(),
                artifacts: ["exports/cut.fcpxml","exports/cut.mp4","plan/cut.plan.json"], approvedPlanHash: target.approvedPlanSHA256,
                briefHash: target.approvedBriefSHA256, approvedScript: "inputs/script/approved.md")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(version).write(to: folder.appendingPathComponent("clauto-version.json"))
            let workflow = WorkflowRepository()
            let valid = try await workflow.voiceReviewTarget(version, project: project, durationLoader: { _ in 120 })
            #expect(valid.versionID == version.id)
            await #expect(throws: (any Error).self) {
                _ = try await workflow.voiceReviewTarget(version, project: project, durationLoader: { _ in
                    let path = folder.appendingPathComponent(changed)
                    var bytes = try Data(contentsOf: path); bytes.append(Data(" ".utf8)); try bytes.write(to: path)
                    return 120
                })
            }
        }
    }

    @MainActor @Test func delayedTypedSaveRefusesChangedTargetAndKeepsClickedAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-typed-dispatch-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await ProjectRepository().create(name: "Synthetic typed dispatch",root: root,engine: root,engineVersion: "test")
        let a = try target(project: project,number: 1), b = try target(project: project,number: 2)
        let controller = try VoiceReviewController(project: project,provider: MockVoiceProvider())
        await controller.load()
        let first = UUID(); controller.willAttach(first)
        await controller.attach(a,token: first,sampler: { .init(host: 100,seconds: 1,rate: 0,available: true) })
        let clickedTarget = try #require(controller.target), clickedAction = VoiceRangeAction.protect
        let delayed = { @MainActor in await controller.addTyped(text: "Keep A",action: clickedAction,start: 1,end: 2,expectedTarget: clickedTarget) }
        let second = UUID(); controller.willAttach(second)
        await controller.attach(b,token: second,sampler: { .init(host: 101,seconds: 1,rate: 0,available: true) })
        #expect(await delayed() == false)
        #expect(controller.document.notes.isEmpty)
        let expectedB = try #require(controller.target)
        var pickerAction = VoiceRangeAction.protect
        let frozenAction = pickerAction; pickerAction = .remove
        #expect(await controller.addTyped(text: "Keep B",action: frozenAction,start: 1,end: 2,expectedTarget: expectedB))
        let note = try #require(controller.document.notes.last)
        #expect(pickerAction == .remove && note.action == .protect && note.effectiveAnchor?.targetID == expectedB.id)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func unsupportedPlaybackRatesRetainTranscriptsWithoutPoisoningStorage() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), token = UUID()
        let controller = try await controller(project: project,provider: provider,target: target,token: token)
        controller.start(); try await waitFor { controller.mode == .recording }
        controller.record(.init(host: 100.1,seconds: 10,rate: 16,available: true),token: token)
        controller.record(.init(host: 100.4,seconds: 10,rate: .nan,available: true),token: token)
        await provider.emit(.clock(audioStart: 0,duration: 1,hostStart: 100.1))
        await provider.emit(.speech(.init(segmentID: "unsupported-rate",text: "Keep the original feedback",isFinal: true,audioStart: 0.1,audioEnd: 0.2)))
        try await waitFor { controller.document.notes.count == 1 }
        #expect(controller.document.notes[0].state == .needsResolution && controller.unsavedActions == 0)
        controller.record(.init(host: 101.2,seconds: 10,rate: 0,available: true),token: token)
        #expect(await controller.stop())
        #expect(await controller.flushForExit())
        let reopened = try await repository.load()
        #expect(reopened.notes[0].text == "Keep the original feedback" && reopened.notes[0].state == .needsResolution)
        #expect(reopened.sessions[0].playhead.allSatisfy { $0.rate.isFinite && (-4...4).contains($0.rate) })
        #expect(reopened.sessions[0].playhead.contains { $0.targetID == nil })
    }
    @MainActor @Test func attachingFrozenPlayerIdentityAfterFileChangeRefusesFreshRebinding() async throws {
        let (root,project,_,original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try VoiceReviewController(project: project,provider: provider)
        await controller.load()
        let movie = project.folder.appendingPathComponent(original.preview.relativePath)
        try Data("Synthetic changed movie after decoder opened".utf8).write(to: movie)
        let token = UUID(); controller.willAttach(token)
        await controller.attach(original,token: token,sampler: { .init(host: 100,seconds: 10,rate: 0,available: true) })
        #expect(controller.target == nil && controller.error != nil && !controller.canStart)
        #expect(controller.document.notes.isEmpty && controller.document.sessions.isEmpty)
        #expect(await provider.starts == 0)
        #expect(await provider.microphoneRequests == 0)
        #expect(await controller.flushForExit())
    }

    @Test func decoderOpeningIdentityRejectsReplacementBeforeAsyncTargetPreparation() async throws {
        let (root,project,_,original) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = project.folder.appendingPathComponent(original.preview.relativePath)
        let opening = try ReviewMovieOpeningIdentity.capture(url: url,project: project)
        try opening.check(original,project: project)
        // Same bytes/hash, different file identity between decoder opening and
        // the asynchronous full target lookup: neither voice nor frame endpoint
        // may publish this new target for the old decoder.
        let bytes = try Data(contentsOf: url); try bytes.write(to: url,options: .atomic)
        let freshPreview = try VoiceReviewProvenance.inspect(original.preview.relativePath,project: project)
        #expect(freshPreview.sha256 == original.preview.sha256 && freshPreview.signature != original.preview.signature)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String:Any])
        object["preview"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(freshPreview))
        let fresh = try JSONDecoder().decode(VoiceReviewTarget.self,from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) { try opening.check(fresh,project: project) }
        let reopened = try ReviewMovieOpeningIdentity.capture(url: url,project: project)
        try reopened.check(fresh,project: project)
        #expect(throws: (any Error).self) { try ReviewMovieOpeningIdentity.capture(url: project.folder.deletingLastPathComponent().appendingPathComponent("outside.mp4"),project: project) }
    }

}
