import Foundation
import Testing
import Observation
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor VoiceDraftAutosaveGate {
    private var held = true
    func wait() async throws {
        while held { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5)) }
    }
    func release() { held = false }
}

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
    var microphone = VoicePermission.authorized, speech = VoicePermission.authorized
    var installedModel = true, grantMicrophone = true, grantSpeech = true, holdModel = false, failModelOnce = false
    var cancellationAsNSError = false
    var modelPreparations = 0
    var lastDeviceUID: String?
    var inputDevices = [VoiceInputDevice(id: "mock-device",name: "Mock microphone",isDefault: true)]
    var modelProgress: (@Sendable (Double) -> Void)?
    var accessCalls = 0, heldAccessCall: Int?
    var accessWaiter: CheckedContinuation<Void,Never>?
    func access(locale: String) async -> VoiceReviewAccess {
        accessCalls += 1
        if accessCalls == heldAccessCall { await withCheckedContinuation { accessWaiter = $0 } }
        return .init(microphone: microphone,speech: speech,installedModel: installedModel,locale: locale)
    }
    func holdSpeechAccess() { heldAccessCall = accessCalls+2 }
    func releaseAccess() { accessWaiter?.resume(); accessWaiter = nil; heldAccessCall = nil }
    var accessIsHeld: Bool { accessWaiter != nil }
    func devices() async -> [VoiceInputDevice] { inputDevices }
    func requestMicrophonePermission() async -> Bool { microphoneRequests += 1; microphone = grantMicrophone ? .authorized:.denied; return grantMicrophone }
    func requestSpeechPermission() async -> Bool { speechRequests += 1; speech = grantSpeech ? .authorized:.denied; return grantSpeech }
    func configureSetup(microphone: VoicePermission = .notDetermined,speech: VoicePermission = .notDetermined,installed: Bool = false,grantMicrophone: Bool = true,grantSpeech: Bool = true,holdModel: Bool = false,failModelOnce: Bool = false,devices: [VoiceInputDevice]? = nil) {
        self.microphone = microphone; self.speech = speech; installedModel = installed
        self.grantMicrophone = grantMicrophone; self.grantSpeech = grantSpeech; self.holdModel = holdModel; self.failModelOnce = failModelOnce
        if let devices { inputDevices = devices }
    }
    func useFrameworkCancellationError() { cancellationAsNSError = true }
    func releaseModel() { holdModel = false }
    func emitModelProgress(_ value: Double) { modelProgress?(value) }
    func prepareSpeech(locale: String,progress: @escaping @Sendable (Double) -> Void) async throws {
        modelPreparations += 1; modelProgress = progress; progress(0.25)
        do { while holdModel { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5)) } }
        catch { if cancellationAsNSError { throw NSError(domain: NSURLErrorDomain,code: NSURLErrorCancelled) }; throw error }
        try Task.checkCancellation()
        if failModelOnce { failModelOnce = false; throw WorkflowFailure.invalid("Synthetic offline model failure; try again.") }
        installedModel = true; progress(1)
    }
    func configure(holdStart: Bool = false, holdStop: Bool = false, finals: [VoiceDictationEvent] = []) { self.holdStart = holdStart; self.holdStop = holdStop; finalEvents = finals }
    func start(session: UUID, deviceUID: String, locale: String) async throws -> AsyncStream<VoiceDictationEvent> {
        starts += 1
        lastDeviceUID = deviceUID
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
        let controller = try VoiceReviewController(project: project, provider: provider, defaults: defaults, steeringIdleInterval: 0)
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
        let controller = try VoiceReviewController(project: project,provider: MockVoiceProvider(), steeringIdleInterval: 0)
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
        let provider = MockVoiceProvider(), controller = try VoiceReviewController(project: project,provider: provider, steeringIdleInterval: 0)
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

    @Test func feedbackPacketsUseExactIdleDeadlineAndIgnoreClockAndDuplicateSpeech() async throws {
        let (root,_,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository,target: target), now = Date(timeIntervalSince1970: 1_000)
        let partial = VoiceSpeechResult(segmentID: "live",text: "I like this",isFinal: false,audioStart: 2,audioEnd: 3)
        _ = try await repository.speech(partial,session: id,attempt: attempt,now: now)
        #expect(try await repository.packetFeedback(now: now.addingTimeInterval(119.999),idleInterval: 120).feedbackPackets == nil)
        let before = try await repository.load().steering
        _ = try await repository.speech(partial,session: id,attempt: attempt,now: now.addingTimeInterval(119))
        _ = try await repository.captured(session: id,attempt: attempt,audioStart: 10,duration: 1,hostStart: 110)
        #expect(try await repository.load().steering == before)
        let packet = try #require(try await repository.packetFeedback(now: now.addingTimeInterval(120),idleInterval: 120).feedbackPackets?.first)
        #expect(packet.notes.count == 1 && !packet.notes[0].isFinal && packet.needsAttention == 1)
        #expect(try await repository.claim(now: now.addingTimeInterval(121),idleInterval: 120) == nil)
        #expect(try await repository.load().sessions[0].state == .recording)
        _ = try await repository.speech(.init(segmentID: "live",text: "I like this moment",isFinal: true,audioStart: 2,audioEnd: 3),session: id,attempt: attempt,now: now.addingTimeInterval(122))
        #expect(try await repository.claim(now: now.addingTimeInterval(241.999),idleInterval: 120) == nil)
        let claim = try #require(try await repository.claim(now: now.addingTimeInterval(242),idleInterval: 120))
        let saved = try await repository.load()
        #expect(saved.feedbackPackets?.count == 2 && saved.feedbackPackets?.first == packet)
        #expect(claim.feedbackPacketID == saved.feedbackPackets?.last?.id && claim.noteRevisions[0].revision == 2)
        #expect(saved.sessions[0].state == .recording)
    }

    @Test func packetTransactionsAreIdempotentAcrossRepositoriesAndPreserveEarlierProtection() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try VoiceReviewRepository(project: project), (id,attempt) = try await seed(repository,target: target), now = Date(timeIntervalSince1970: 1_000)
        _ = try await repository.speech(.init(segmentID: "keep",text: "Keep this",isFinal: true,audioStart: 2,audioEnd: 3),session: id,attempt: attempt,now: now)
        async let a = repository.packetFeedback(now: now.addingTimeInterval(120),idleInterval: 120)
        async let b = second.packetFeedback(now: now.addingTimeInterval(120),idleInterval: 120)
        let (one,two) = try await (a,b)
        #expect(one.feedbackPackets?.count == 1 && one.feedbackPackets == two.feedbackPackets)
        let original = try #require(one.feedbackPackets?.first)
        _ = try await second.speech(.init(segmentID: "change",text: "Remove this",isFinal: true,audioStart: 6,audioEnd: 7),session: id,attempt: attempt,now: now.addingTimeInterval(121))
        let next = try await repository.packetFeedback(now: now.addingTimeInterval(241),idleInterval: 120)
        #expect(next.feedbackPackets?.count == 2 && next.feedbackPackets?.first == original)
        #expect(next.feedbackPackets?.last?.notes.map(\.intent) == [.protect,.change])
        let claims = try await [repository.claim(now: now.addingTimeInterval(241),idleInterval: 120),second.claim(now: now.addingTimeInterval(241),idleInterval: 120)]
        #expect(claims.compactMap { $0 }.count == 1)
        let reopened = try await VoiceReviewRepository(project: project).load()
        #expect(reopened.feedbackPackets == next.feedbackPackets)
    }

    @Test func idlePacketRetainsDraftsWithoutPromotingThemToInstructions() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository,target: target)
        let saved = try await final(repository,session: id,attempt: attempt), note = saved.notes[0]
        let draft = VoiceTranscriptDraft(noteID: note.id,text: "Unfinished alternative",intent: .change,targetID: target.id,start: "unfinished",end: "",baseRevision: note.revision)
        _ = try await repository.saveDraft(draft)
        var typed = VoiceTypedDraft(versionID: target.versionID); typed.text = "Another unfinished idea"; typed.target = target
        _ = try await repository.saveTypedDraft(typed,expected: nil)
        let now = try #require(try await repository.load().steering?.lastActivity).addingTimeInterval(120)
        let packet = try #require(try await repository.packetFeedback(now: now,idleInterval: 120).feedbackPackets?.first)
        #expect(packet.drafts == [draft] && packet.typedDrafts == [typed] && packet.needsAttention == 2)
        #expect(packet.notes[0].text == note.text && packet.notes[0].isFinal)
        #expect(try await repository.claim(now: now,idleInterval: 120) == nil)
        #expect(try await VoiceReviewRepository(project: project).load().candidates.isEmpty)
        #expect(try await repository.load().notes[0].text == note.text)
    }

    @MainActor @Test func liveCaptureAutomaticallyPacketsAndPreparesWhileMicrophoneStaysOn() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try VoiceReviewController(project: project,provider: provider,steeringIdleInterval: 0.08)
        await controller.load(); let token = UUID(); controller.willAttach(token)
        await controller.attach(target,token: token,sampler: { .init(host: 100,seconds: 10,rate: 0,available: true) })
        controller.chooseDevice("mock-device"); controller.start(); try await waitFor { controller.mode == .recording }
        controller.record(.init(host: 110,seconds: 10,rate: 0,available: true),token: token)
        await provider.emit(.clock(audioStart: 0,duration: 10,hostStart: 100))
        await provider.emit(.speech(.init(segmentID: "first",text: "Keep this moment",isFinal: true,audioStart: 2,audioEnd: 3)))
        try await waitFor { controller.document.candidates.last?.state == .prepared }
        #expect(controller.active && controller.document.feedbackPackets?.count == 1)
        #expect(await provider.starts == 1); #expect(await provider.stops == 0)
        await provider.emit(.speech(.init(segmentID: "second",text: "Keep this detail",isFinal: true,audioStart: 5,audioEnd: 6)))
        try await waitFor { controller.document.feedbackPackets?.count == 2 && controller.document.candidates.last?.noteRevisions.count == 2 && controller.document.candidates.last?.state == .prepared }
        #expect(controller.active); #expect(await provider.stops == 0)
        let frameLease = UUID(); #expect(controller.beginFrameComment(frameLease)); controller.endFrameComment(frameLease) // A frame pause is a clock boundary.
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func steeringDuringBackgroundWorkSupersedesOldProposalAndKeepsCaptureLive() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), processor = PausedVoiceProcessor()
        let controller = try VoiceReviewController(project: project,provider: provider,processor: processor,steeringIdleInterval: 0.06)
        await controller.load(); let token = UUID(); controller.willAttach(token)
        await controller.attach(target,token: token,sampler: { .init(host: 100,seconds: 10,rate: 0,available: true) })
        controller.chooseDevice("mock-device"); controller.start(); try await waitFor { controller.mode == .recording }
        controller.record(.init(host: 110,seconds: 10,rate: 0,available: true),token: token)
        await provider.emit(.clock(audioStart: 0,duration: 10,hostStart: 100))
        await provider.emit(.speech(.init(segmentID: "first",text: "Keep this",isFinal: true,audioStart: 2,audioEnd: 3)))
        try await waitFor { await processor.calls == 1 }
        await provider.emit(.speech(.init(segmentID: "second",text: "Keep this too",isFinal: true,audioStart: 5,audioEnd: 6)))
        try await waitFor { controller.document.notes.count == 2 }
        #expect(controller.active); #expect(await provider.stops == 0)
        await processor.release()
        try await waitFor { controller.document.candidates.count == 2 && controller.document.candidates.last?.state == .prepared }
        #expect(controller.document.candidates[0].state == .superseded && controller.document.feedbackPackets?.count == 2)
        #expect(controller.document.candidates.last?.noteRevisions.count == 2)
        #expect(controller.active); #expect(await controller.flushForExit())
    }

    @MainActor @Test func quitCancelsIdleTimerAndReopenReschedulesSavedDraftWithoutCapture() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try VoiceReviewController(project: project,provider: provider)
        await controller.load(); controller.typedComposer(for: target.versionID).text = "Keep this raw unfinished thought"
        #expect(await controller.flushForExit())
        #expect(controller.nextPacketAt == nil && controller.document.feedbackPackets == nil)
        let reopened = try VoiceReviewController(project: project,provider: provider,steeringIdleInterval: 0)
        await reopened.load(); try await waitFor { reopened.document.feedbackPackets?.count == 1 }
        #expect(reopened.document.feedbackPackets?.first?.typedDrafts.first?.text == "Keep this raw unfinished thought")
        #expect(reopened.document.notes.isEmpty && reopened.document.candidates.isEmpty)
        #expect(await provider.starts == 0)
        #expect(try await repository.load().feedbackPackets?.count == 1)
        #expect(await reopened.flushForExit())
    }

    @MainActor @Test func pendingTypingCannotBeBypassedByClockWritesOrAnOldIdleTimer() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), gate = VoiceDraftAutosaveGate()
        let controller = try VoiceReviewController(project: project,provider: provider,steeringIdleInterval: 0.04,draftAutosaveWait: { try await gate.wait() })
        await controller.load(); let token = UUID(); controller.willAttach(token)
        await controller.attach(target,token: token,sampler: { .init(host: 100,seconds: 10,rate: 0,available: true) })
        controller.chooseDevice("mock-device"); controller.start(); try await waitFor { controller.mode == .recording }
        controller.typedComposer(for: target.versionID).text = "Unfinished steering remains a draft"
        controller.record(.init(host: 110,seconds: 10,rate: 0,available: true),token: token)
        await provider.emit(.clock(audioStart: 0,duration: 10,hostStart: 100))
        await provider.emit(.speech(.init(segmentID: "first",text: "Keep this",isFinal: true,audioStart: 2,audioEnd: 3)))
        try await waitFor { controller.document.notes.count == 1 }
        try await Task.sleep(for: .milliseconds(70))
        #expect(controller.document.feedbackPackets == nil && controller.document.candidates.isEmpty)
        await gate.release()
        try await waitFor { controller.document.feedbackPackets?.count == 1 }
        #expect(controller.document.feedbackPackets?.first?.typedDrafts.first?.text == "Unfinished steering remains a draft")
        #expect(controller.document.candidates.isEmpty && controller.active)
        #expect(await controller.flushForExit())
    }

    @Test func packetBoundWorkCannotPublishAfterAnotherRepositoryAddsDraftOrUnfinishedSpeech() async throws {
        for typed in [false,true] {
            let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let other = try VoiceReviewRepository(project: project), (id,attempt) = try await seed(repository,target: target)
            _ = try await final(repository,session: id,attempt: attempt)
            let claim = try #require(try await repository.claim(idleInterval: 0)), input = try await repository.candidateInput(claim)
            if typed {
                var draft = VoiceTypedDraft(versionID: target.versionID); draft.text = "New unfinished direction"; draft.target = target
                _ = try await other.saveTypedDraft(draft,expected: nil)
            } else {
                _ = try await other.speech(.init(segmentID: "new-partial",text: "Actually this next bit",isFinal: false,audioStart: 6,audioEnd: 7),session: id,attempt: attempt)
            }
            await #expect(throws: (any Error).self) { try await repository.candidateInput(claim) }
            let completed = try await repository.complete(claim,directives: input)
            #expect(completed.candidates[0].state == .superseded && completed.processingJobID == nil)
            #expect(completed.candidates[0].instructionsRelativePath == nil)
            #expect(!FileManager.default.fileExists(atPath: project.folder.appendingPathComponent("notes/voice-review/candidates/"+claim.id.uuidString+".json").path))
            #expect(completed.notes[0].state == .ready && completed.hasUnpacketedFeedback)
        }
    }

    @MainActor @Test func firstLocalDraftKeystrokeInvalidatesHeldPreparationBeforeAutosave() async throws {
        for typed in [false,true] {
            let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let (id,attempt) = try await seed(repository,target: target)
            _ = try await final(repository,session: id,attempt: attempt)
            let processor = PausedVoiceProcessor(), controller = try VoiceReviewController(project: project,provider: MockVoiceProvider(),processor: processor,steeringIdleInterval: 0)
            await controller.load(); try await waitFor { await processor.calls == 1 }
            if typed { controller.typedComposer(for: target.versionID).text = "New raw direction" }
            else {
                let note = controller.document.notes[0]
                controller.retainDraft(.init(noteID: note.id,text: "New raw direction",intent: .change,targetID: target.id,start: "unfinished",end: "",baseRevision: note.revision))
            }
            await processor.release()
            try await waitFor { controller.document.candidates.count == 1 && controller.document.processingJobID == nil }
            let stale = try #require(controller.document.candidates.first)
            #expect(stale.state != .prepared && stale.instructionsRelativePath == nil)
            #expect(await controller.flushForExit())
            let saved = try await repository.load()
            #expect(saved.typedDrafts?.first?.text == "New raw direction" || saved.drafts?.first?.text == "New raw direction")
        }
    }

    @MainActor @Test func busyExternalLeaseResumesWithoutNewFeedbackAndQuitCancelsTheWatcher() async throws {
        for releaseLease in [true,false] {
            let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let (id,attempt) = try await seed(repository,target: target)
            _ = try await final(repository,session: id,attempt: attempt)
            let claim = try #require(try await repository.claim()), input = try await repository.candidateInput(claim)
            _ = try await final(repository,session: id,attempt: attempt,key: "next",start: 6,text: "Keep this detail too")
            let controller = try VoiceReviewController(project: project,provider: MockVoiceProvider(),steeringIdleInterval: 0)
            await controller.load(); try await waitFor { controller.waitingForPreparation }
            let activity = controller.document.steering
            if releaseLease {
                _ = try await repository.complete(claim,directives: input)
                try await waitFor { controller.document.candidates.count == 2 && controller.document.candidates.last?.state == .prepared }
                #expect(controller.document.steering == activity && controller.document.feedbackPackets?.count == 1)
                #expect(!controller.waitingForPreparation && controller.document.candidates.last?.noteRevisions.count == 2)
                #expect(await controller.flushForExit())
            } else {
                #expect(await controller.flushForExit())
                #expect(!controller.waitingForPreparation && controller.nextPacketAt == nil)
                #expect(try await repository.load().processingJobID == claim.id) // Never cancel another repository's job.
                _ = try await repository.complete(claim,directives: input)
            }
        }
    }

    @MainActor @Test func cancelledApplicationQuitResumesPacketsWithoutRestartingMicrophone() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try VoiceReviewController(project: project,provider: provider,steeringIdleInterval: 0.08)
        await controller.load()
        let token = UUID(); controller.willAttach(token)
        await controller.attach(target,token: token,sampler: { .init(host: 100,seconds: 10,rate: 0,available: true) })
        #expect(await controller.addTyped(text: "Keep this exact range",action: .protect,start: 1,end: 2,expectedTarget: target))
        #expect(await controller.flushForExit())
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await repository.load().feedbackPackets == nil)
        controller.resumeAfterCancelledExit()
        try await waitFor { controller.document.feedbackPackets?.count == 1 && controller.document.candidates.last?.state == .prepared }
        #expect(await provider.starts == 0)
        #expect(controller.mode == .idle && controller.document.notes.count == 1)
        #expect(await controller.flushForExit())
    }

    @Test func discardedTypedDraftUsesCASAndCannotBeResurrectedByStaleSavesOrSubmissions() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = VoiceTypedDraft(versionID: target.versionID); draft.text = "Discard these unfinished words"; draft.start = "unfinished"; draft.target = target
        _ = try await repository.saveTypedDraft(draft,expected: nil)
        let other = try VoiceReviewRepository(project: project)
        var newer = draft; newer.revision += 1; newer.submissionID = UUID(); newer.text = "Newer words from another window"
        _ = try await other.saveTypedDraft(newer,expected: draft)
        await #expect(throws: (any Error).self) { try await repository.discardTypedDraft(draft,expected: draft) }
        #expect(try await repository.load().typedDrafts == [newer])
        let discarded = try await repository.discardTypedDraft(newer,expected: newer)
        let retry = try await other.discardTypedDraft(newer,expected: newer)
        #expect(discarded.typedDiscards == retry.typedDiscards && retry.typedDiscards?.count == 1 && (retry.typedDrafts ?? []).isEmpty)
        await #expect(throws: (any Error).self) { try await repository.saveTypedDraft(newer,expected: nil) }
        var changed = newer; changed.revision += 1; changed.submissionID = UUID(); changed.start = "1"; changed.end = "2"
        await #expect(throws: (any Error).self) { try await other.saveTypedDraft(changed,expected: nil) }
        await #expect(throws: (any Error).self) { try await other.submitTypedDraft(changed,expected: nil) }
        #expect(try await repository.load().notes.isEmpty)
    }

    @MainActor @Test func typedDiscardReservesSynchronouslyAndQuitJoinsItWithoutLosingOtherFeedback() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repository.addTyped(text: "Keep already saved feedback",action: .protect,anchor: .init(targetID: target.id,seconds: 1,endSeconds: 2))
        let controller = try VoiceReviewController(project: project,provider: MockVoiceProvider())
        await controller.load(); let composer = controller.typedComposer(for: target.versionID)
        composer.text = "Unfinished draft to discard"; composer.start = "-"
        let oldID = composer.snapshot.id, task = try #require(controller.discardTypedComposer(target.versionID))
        #expect(composer.saving && controller.hasPendingWork && controller.discardTypedComposer(target.versionID) == nil)
        composer.text = "Must not replace the frozen discard"; #expect(composer.text == "Unfinished draft to discard")
        #expect(await controller.flushForExit()); #expect(await task.value)
        let saved = try await repository.load()
        #expect(saved.notes.count == 1 && saved.notes[0].text == "Keep already saved feedback")
        #expect(saved.typedDiscards?.first?.draftID == oldID && (saved.typedDrafts ?? []).isEmpty)
        #expect(composer.text.isEmpty && composer.snapshot.id != oldID && !controller.hasPendingWork)
    }

    @MainActor @Test func clearingOrDiscardingTemporaryDraftUnblocksAnIdenticalFinalPacket() async throws {
        for discard in [false,true] {
            let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let (id,attempt) = try await seed(repository,target: target)
            _ = try await final(repository,session: id,attempt: attempt)
            let controller = try VoiceReviewController(project: project,provider: MockVoiceProvider(),steeringIdleInterval: 0)
            await controller.load(); try await waitFor { controller.document.candidates.last?.state == .prepared }
            let original = try #require(controller.document.candidates.last), composer = controller.typedComposer(for: target.versionID)
            composer.text = "A temporary unfinished direction"
            try await waitFor { controller.document.typedDrafts?.first?.text == composer.text }
            #expect(controller.document.candidates.first?.state == .superseded)
            if discard { #expect(await controller.discardTypedComposer(target.versionID)?.value == true) }
            else { composer.text = "" }
            try await waitFor { controller.document.candidates.last?.id != original.id && controller.document.candidates.last?.state == .prepared }
            let latest = try #require(controller.document.candidates.last)
            #expect(latest.noteRevisions == original.noteRevisions && latest.feedbackPacketID != original.feedbackPacketID)
            #expect(controller.document.feedbackPackets?.last?.needsAttention == 0)
            #expect(latest.directives.map(\.text) == original.directives.map(\.text))
            #expect(await controller.flushForExit())
        }
    }

    @MainActor @Test func foreignLeaseWatcherReconnectsAfterTemporaryLedgerReadFailure() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (id,attempt) = try await seed(repository,target: target)
        _ = try await final(repository,session: id,attempt: attempt)
        let claim = try #require(try await repository.claim()), input = try await repository.candidateInput(claim)
        _ = try await final(repository,session: id,attempt: attempt,key: "more",start: 6,text: "Keep this too")
        let controller = try VoiceReviewController(project: project,provider: MockVoiceProvider(),steeringIdleInterval: 0)
        await controller.load(); try await waitFor { controller.waitingForPreparation }
        let ledger = project.folder.appendingPathComponent("notes/voice-review/ledger.json"), original = try Data(contentsOf: ledger)
        try Data("{}".utf8).write(to: ledger,options: .atomic)
        try await waitFor { controller.error?.contains("Reconnecting") == true }
        #expect(controller.waitingForPreparation)
        try original.write(to: ledger,options: .atomic)
        _ = try await repository.complete(claim,directives: input)
        try await waitFor { controller.document.candidates.count == 2 && controller.document.candidates.last?.state == .prepared }
        #expect(!controller.waitingForPreparation && controller.error == nil)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func guidedVoiceSetupRequestsOncePreparesModelChoosesDefaultAndStartsVerifiedPlayer() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider()
        await provider.configureSetup(devices: [.init(id: "other",name: "Other"),.init(id: "system-default",name: "System default",isDefault: true)])
        let controller = try await controller(project: project,provider: provider,target: target)
        #expect(await provider.starts == 0); #expect(await provider.modelPreparations == 0)
        controller.setUpVoiceReview(for: target.versionID); controller.setUpVoiceReview(for: target.versionID)
        try await waitFor { controller.mode == .recording }
        #expect(controller.voiceSetupPhase == .ready && controller.selectedDeviceUID == "system-default")
        #expect(await provider.microphoneRequests == 1); #expect(await provider.speechRequests == 1)
        #expect(await provider.modelPreparations == 1); #expect(await provider.starts == 1)
        #expect(await provider.lastDeviceUID == "system-default")
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func deniedSetupPermissionNeverPreparesAssetsOrStartsMicrophone() async throws {
        for denyMicrophone in [true,false] {
            let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let provider = MockVoiceProvider(); await provider.configureSetup(grantMicrophone: !denyMicrophone,grantSpeech: false)
            let controller = try await controller(project: project,provider: provider,target: target)
            controller.setUpVoiceReview(for: target.versionID); try await waitFor { controller.voiceSetupPhase == .failed }
            #expect(controller.voiceSetupPermission == (denyMicrophone ? "Microphone":"SpeechRecognition"))
            #expect(await provider.modelPreparations == 0); #expect(await provider.starts == 0)
            #expect(controller.document.sessions.isEmpty)
            #expect(await controller.flushForExit())
        }
    }

    @MainActor @Test func guidedSetupRetriesFailedModelWithoutRepeatingGrantedConsent() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(); await provider.configureSetup(failModelOnce: true)
        let controller = try await controller(project: project,provider: provider,target: target)
        controller.setUpVoiceReview(for: target.versionID); try await waitFor { controller.voiceSetupPhase == .failed }
        #expect(await provider.starts == 0)
        controller.setUpVoiceReview(for: target.versionID); try await waitFor { controller.mode == .recording }
        #expect(await provider.microphoneRequests == 1); #expect(await provider.speechRequests == 1)
        #expect(await provider.modelPreparations == 2); #expect(await provider.starts == 1)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func cancelSetupAndQuitLeaveNoSessionAndIgnoreLateProgress() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(); await provider.configureSetup(holdModel: true)
        let controller = try await controller(project: project,provider: provider,target: target)
        await provider.useFrameworkCancellationError()
        controller.setUpVoiceReview(for: target.versionID); try await waitFor { await provider.modelPreparations == 1 }
        #expect(await controller.flushForExit())
        await provider.emitModelProgress(0.9); await Task.yield()
        #expect(controller.voiceSetupPhase == .idle && controller.voiceSetupProgress == nil)
        #expect(await provider.starts == 0); #expect(controller.document.sessions.isEmpty)
    }

    @MainActor @Test func setupCompletionCannotStartAnotherPlayerAfterNavigation() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(); await provider.configureSetup(holdModel: true)
        let controller = try await controller(project: project,provider: provider,target: target)
        controller.setUpVoiceReview(for: target.versionID); try await waitFor { await provider.modelPreparations == 1 }
        let other = try self.target(project: project,number: 2), token = UUID(); controller.willAttach(token)
        await controller.attach(other,token: token,sampler: { .init(host: 101,seconds: 1,rate: 0,available: true) })
        await provider.releaseModel(); try await waitFor { controller.voiceSetupPhase == .failed }
        #expect(await provider.starts == 0); #expect(controller.document.sessions.isEmpty)
        #expect(controller.target?.id == other.id)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func guidedSetupWithoutMicrophoneNeverPreparesAssetsAndCanRecover() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(); await provider.configureSetup(devices: [])
        let controller = try await controller(project: project,provider: provider,target: target)
        controller.setUpVoiceReview(for: target.versionID); try await waitFor { controller.voiceSetupPhase == .failed }
        #expect(await provider.modelPreparations == 0); #expect(await provider.starts == 0)
        #expect(controller.voiceSetupIssue?.contains("microphone") == true)
        await provider.configureSetup(microphone: .authorized,speech: .authorized,devices: [.init(id: "connected",name: "Connected",isDefault: true)])
        controller.setUpVoiceReview(for: target.versionID); try await waitFor { controller.mode == .recording }
        #expect(await provider.microphoneRequests == 1); #expect(await provider.speechRequests == 1)
        #expect(await provider.lastDeviceUID == "connected")
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func guidedSetupKeepsExplicitInputAndIgnoresInvalidAndLateProgress() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(); await provider.configureSetup(holdModel: true,devices: [.init(id: "chosen",name: "Chosen"),.init(id: "default",name: "Default",isDefault: true)])
        let controller = try await controller(project: project,provider: provider,target: target)
        controller.chooseDevice("chosen"); controller.setUpVoiceReview(for: target.versionID)
        try await waitFor { await provider.modelPreparations == 1 }
        await provider.emitModelProgress(.nan); await provider.emitModelProgress(5)
        try await waitFor { controller.voiceSetupProgress == 1 }
        controller.cancelVoiceSetup(); try await waitFor { controller.voiceSetupPhase == .idle }
        await provider.emitModelProgress(0.3); await Task.yield()
        #expect(controller.voiceSetupProgress == nil && controller.selectedDeviceUID == "chosen")
        #expect(await provider.starts == 0)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func cancellationDuringStatusReadCannotOpenTheNextPermissionPrompt() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(); await provider.configureSetup()
        let controller = try await controller(project: project,provider: provider,target: target)
        await provider.holdSpeechAccess(); controller.setUpVoiceReview(for: target.versionID)
        try await waitFor { await provider.accessIsHeld }
        controller.cancelVoiceSetup(); await provider.releaseAccess()
        try await waitFor { controller.voiceSetupPhase == .idle }
        #expect(await provider.microphoneRequests == 1); #expect(await provider.speechRequests == 0)
        #expect(await provider.modelPreparations == 0); #expect(await provider.starts == 0)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func newTypedDraftRestoresInvalidRangesUnicodeActionAndFrozenTargetAfterRestart() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try await controller(project: project,provider: provider,target: target)
        let composer = controller.typedComposer(for: target.versionID)
        composer.text = "Keep café 👩🏽‍🍳 and the original words"; composer.start = "unfinished :"; composer.end = "-"; composer.action = .remove
        #expect(controller.hasPendingWork && controller.typedComposer(for: target.versionID) === composer)
        #expect(await controller.flushForExit())
        let saved = try #require(try await repository.load().typedDrafts?.first)
        #expect(saved.text == composer.text && saved.start == "unfinished :" && saved.end == "-" && saved.action == .remove && saved.target == target)
        let reopened = try VoiceReviewController(project: project,provider: provider, steeringIdleInterval: 0); await reopened.load()
        let restored = reopened.typedComposer(for: target.versionID)
        #expect(restored.snapshot == saved && reopened.target == nil && !reopened.canStart)
        #expect(reopened.document.notes.isEmpty && reopened.document.sessions.isEmpty)
        #expect(await provider.starts == 0)
        #expect(await provider.microphoneRequests == 0)
        #expect(await reopened.flushForExit())
    }

    @MainActor @Test func typedSaveReservesSynchronouslyFreezesFieldsAndImmediateQuitWaits() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try await controller(project: project,provider: provider,target: target)
        let composer = controller.typedComposer(for: target.versionID)
        composer.text = "Remove this exact range"; composer.start = "1"; composer.end = "2"; composer.action = .remove
        let operation = try #require(controller.submitTypedComposer(target.versionID))
        #expect(composer.saving && controller.hasPendingWork && controller.submitTypedComposer(target.versionID) == nil)
        composer.text = "Cannot replace frozen submitted words"; composer.action = .protect
        #expect(composer.text == "Remove this exact range" && composer.action == .remove)
        #expect(await controller.flushForExit()); #expect(await operation.value)
        let saved = try await repository.load()
        #expect(saved.notes.count == 1 && saved.notes[0].text == "Remove this exact range" && saved.notes[0].action == .remove)
        #expect(saved.typedSubmissions?.count == 1 && (saved.typedDrafts ?? []).isEmpty)
        #expect(composer.text.isEmpty && !composer.saving && !controller.hasPendingWork)
        #expect(await provider.starts == 0)
        let reopened = try VoiceReviewController(project: project,provider: provider, steeringIdleInterval: 0); await reopened.load()
        #expect(reopened.typedComposer(for: target.versionID).text.isEmpty)
        #expect(await reopened.flushForExit())
    }

    @Test func typedSubmissionRetryDoesNotDuplicateOrResurrectDraftAndNewRevisionCanFollow() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = VoiceTypedDraft(versionID: target.versionID); draft.revision = 4; draft.text = "Keep the first words"; draft.start = "1"; draft.end = "2"; draft.target = target
        _ = try await repository.saveTypedDraft(draft,expected: nil)
        let first = try await repository.submitTypedDraft(draft,expected: draft)
        let retry = try await repository.submitTypedDraft(draft,expected: draft)
        #expect(retry.notes.map(\.id) == first.notes.map(\.id) && retry.sessions.count == 1 && retry.typedSubmissions?.count == 1)
        _ = try await repository.cancel(note: first.notes[0].id)
        #expect(try await repository.submitTypedDraft(draft,expected: nil).notes[0].state == .cancelled)
        let delayed = try await repository.saveTypedDraft(draft,expected: draft)
        #expect((delayed.typedDrafts ?? []).isEmpty)
        var changed = draft; changed.text = "A changed request cannot reuse the saved operation"
        await #expect(throws: (any Error).self) { try await repository.submitTypedDraft(changed,expected: nil) }
        changed.submissionID = UUID()
        await #expect(throws: (any Error).self) { try await repository.submitTypedDraft(changed,expected: nil) }
        var older = changed; older.revision = 3
        await #expect(throws: (any Error).self) { try await repository.submitTypedDraft(older,expected: nil) }
        changed.revision += 1; changed.submissionID = UUID()
        _ = try await repository.saveTypedDraft(changed,expected: draft)
        let second = try await repository.submitTypedDraft(changed,expected: changed)
        #expect(second.notes.count == 2 && second.typedSubmissions?.count == 2)
        #expect(second.notes[0].text == draft.text && second.notes[1].text == changed.text)
        // Idempotent receipt lookup still works after its media becomes unavailable.
        try Data("Synthetic changed movie after successful submit".utf8).write(to: project.folder.appendingPathComponent(target.preview.relativePath))
        #expect(try await repository.submitTypedDraft(changed,expected: nil).notes.count == 2)
    }

    @MainActor @Test func concurrentTypedDraftConflictPreservesBothLocalAndSavedWordsUntilExplicitReload() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try await controller(project: project,provider: MockVoiceProvider(),target: target)
        let first = a.typedComposer(for: target.versionID); first.text = "Original draft"; first.start = "1"; first.end = "2"
        #expect(await a.flushForExit())
        let b = try await controller(project: project,provider: MockVoiceProvider(),target: target)
        let second = b.typedComposer(for: target.versionID)
        first.text = "Saved by first window"; #expect(await a.flushForExit())
        second.text = "Unsaved words from second window"; #expect(await b.flushForExit() == false)
        #expect(second.text == "Unsaved words from second window" && second.storageIssue != nil && b.hasPendingWork)
        #expect(try await repository.load().typedDrafts?.first?.text == "Saved by first window")
        b.reloadTypedComposer(target.versionID); try await waitFor { !second.saving }
        #expect(second.text == "Saved by first window" && second.storageIssue == nil)
        #expect(await b.flushForExit())
    }

    @Test func invalidTypedDraftAndChangedMovieSubmissionLeaveStoredDraftAndNotesUntouched() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var draft = VoiceTypedDraft(versionID: target.versionID); draft.text = "Keep immutable original"; draft.start = "1"; draft.end = "2"; draft.target = target
        _ = try await repository.saveTypedDraft(draft,expected: nil)
        let ledger = project.folder.appendingPathComponent("notes/voice-review/ledger.json"), original = try Data(contentsOf: ledger)
        var invalid = draft; invalid.revision = 0
        await #expect(throws: (any Error).self) { try await repository.saveTypedDraft(invalid,expected: draft) }
        invalid = draft; invalid.start = String(repeating: "x",count: 101)
        await #expect(throws: (any Error).self) { try await repository.saveTypedDraft(invalid,expected: draft) }
        #expect(try Data(contentsOf: ledger) == original)
        try Data("Synthetic changed movie".utf8).write(to: project.folder.appendingPathComponent(target.preview.relativePath))
        await #expect(throws: (any Error).self) { try await repository.submitTypedDraft(draft,expected: draft) }
        let saved = try await repository.load()
        #expect(saved.typedDrafts == [draft] && saved.notes.isEmpty && (saved.typedSubmissions ?? []).isEmpty)
    }

    @MainActor @Test func unboundTypedDraftPinsOnlyAfterExplicitSelectionAndRefusesAnotherVersion() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), controller = try VoiceReviewController(project: project,provider: provider, steeringIdleInterval: 0)
        await controller.load()
        let composer = controller.typedComposer(for: target.versionID)
        composer.text = "Keep these unbound words"; composer.start = "unfinished"; composer.end = "3"
        #expect(await controller.flushForExit())
        #expect(try await repository.load().typedDrafts?.first?.target == nil)
        #expect(controller.submitTypedComposer(target.versionID) == nil)
        let first = UUID(); controller.willAttach(first)
        await controller.attach(target,token: first,sampler: { .init(host: 100,seconds: 1,rate: 0,available: true) })
        #expect(controller.submitTypedComposer(target.versionID) == nil) // Range still unfinished; pin is nevertheless saved.
        #expect(await controller.flushForExit())
        #expect(try await repository.load().typedDrafts?.first?.target == target)
        let restarted = try VoiceReviewController(project: project,provider: provider, steeringIdleInterval: 0); await restarted.load()
        #expect(restarted.typedComposer(for: target.versionID).snapshot.target == target && restarted.target == nil)
        #expect(await restarted.flushForExit())
        composer.start = "1"
        let other = try self.target(project: project,number: 2), second = UUID(); controller.willAttach(second)
        await controller.attach(other,token: second,sampler: { .init(host: 101,seconds: 1,rate: 0,available: true) })
        #expect(controller.submitTypedComposer(target.versionID) == nil)
        #expect(composer.text == "Keep these unbound words" && composer.snapshot.target == target)
        #expect(await controller.flushForExit())
        #expect(await provider.starts == 0)
        #expect(controller.document.notes.isEmpty)
    }

    @MainActor @Test func explicitWatchedPlayerSelectionImmediatelyInvalidatesViewObservers() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = try await controller(project: project,provider: MockVoiceProvider(),target: target)
        let clicked = UUID()
        await confirmation("Watched player selection updates its UI",expectedCount: 1) { changed in
            withObservationTracking { _ = controller.isAttached(to: clicked) } onChange: { changed() }
            controller.willAttach(clicked)
        }
        #expect(controller.isAttached(to: clicked) && !controller.canStart)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func playbackAvailabilityInvalidatesMicControlWithoutPublishingEveryClockTick() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID(), provider = MockVoiceProvider()
        let controller = try await controller(project: project,provider: provider,target: target,token: token)
        for (index,value) in [(false,0.0,VoiceTransportKind.unavailable),(true,0.0,.seekCompleted),
                              (true,0.0,.seekRequested),(true,1.0,.seekCompleted),
                              (true,8.0,.sample),(true,1.0,.sample),(true,Double.nan,.sample),
                              (true,0.0,.sample)].enumerated() {
            await confirmation("Availability changes update Mic On",expectedCount: 1) { changed in
                withObservationTracking { _ = controller.canStart } onChange: { changed() }
                controller.record(.init(host: 101+Double(index),seconds: 10,rate: value.1,available: value.0),kind: value.2,token: token)
            }
            #expect(controller.canStart == (index % 2 == 1))
        }
        await confirmation("Ordinary clock ticks do not invalidate the mic control",expectedCount: 0) { changed in
            withObservationTracking { _ = controller.canStart } onChange: { changed() }
            controller.record(.init(host: 120,seconds: 11,rate: 0,available: true),token: token)
            controller.record(.init(host: 121,seconds: 11,rate: 0,available: false),token: UUID())
        }
        #expect(await provider.starts == 0 && controller.document.sessions.isEmpty)
        #expect(await controller.flushForExit())
    }

    @MainActor @Test func startResamplesAvailabilityAndRejectsInvalidClockBeforeSavingOrStartingMicrophone() async throws {
        let (root,project,_,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for invalid in [VoiceLivePlayhead(host: 100,seconds: 10,rate: 0,available: false),
                        .init(host: .nan,seconds: 10,rate: 0,available: true),
                        .init(host: 100,seconds: -.infinity,rate: 0,available: true),
                        .init(host: 100,seconds: -1,rate: 0,available: true),
                        .init(host: 100,seconds: target.duration+1,rate: 0,available: true),
                        .init(host: 100,seconds: 10,rate: .nan,available: true),
                        .init(host: 100,seconds: 10,rate: -8,available: true)] {
            let provider = MockVoiceProvider(), token = UUID()
            let controller = try await controller(project: project,provider: provider,target: target,token: token)
            var current = VoiceLivePlayhead(host: 100,seconds: 10,rate: 0,available: true)
            await controller.attach(target,token: token,sampler: { current })
            #expect(controller.canStart)
            current = invalid; controller.start()
            #expect(!controller.canStart && !controller.active && controller.error != nil)
            #expect(controller.document.sessions.isEmpty && !controller.hasPendingWork)
            #expect(await provider.starts == 0)
            #expect(await provider.microphoneRequests == 0)
            #expect(await provider.speechRequests == 0)
            #expect(await controller.flushForExit())
        }
    }

    @MainActor @Test func clockRecoveryBoundarySurvivesOrdinaryTimestampBackpressure() async throws {
        let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let provider = MockVoiceProvider(), token = UUID()
        let controller = try await controller(project: project,provider: provider,target: target,token: token)
        controller.start(); try await waitFor { controller.mode == .recording }
        // MainActor does not yield while filling the real serial write queue.
        for index in 1...40 {
            controller.record(.init(host: 100+Double(index)/1000,seconds: 10,rate: 0,available: true),token: token)
        }
        #expect(controller.pendingWrites > 32)
        controller.record(.init(host: .nan,seconds: 10,rate: 0,available: true),token: token)
        let queued = controller.pendingWrites
        controller.record(.init(host: 100.8,seconds: 10,rate: 0,available: true),token: token)
        #expect(controller.pendingWrites == queued+1)
        controller.record(.init(host: 100.9,seconds: 10,rate: 0,available: true),kind: .pause,token: token)
        await provider.emit(.clock(audioStart: 0,duration: 1,hostStart: 100))
        await provider.emit(.speech(.init(segmentID: "backpressure-clock-loss",text: "Keep these words across clock loss",isFinal: true,audioStart: 0.05,audioEnd: 0.85)))
        try await waitFor { controller.document.notes.count == 1 }
        #expect(controller.document.notes[0].state == .needsResolution && controller.unsavedActions == 0)
        #expect(await controller.stop())
        #expect(await controller.flushForExit())
        let reopened = try await repository.load()
        #expect(reopened.notes[0].text == "Keep these words across clock loss" && reopened.notes[0].state == .needsResolution)
        #expect(!reopened.sessions[0].playhead.contains { $0.hostStart < 100.5 && $0.confirmedThrough > 100.5 })
    }

    @MainActor @Test func nonfiniteClockLossNeverBridgesFeedbackWhenValidClockReturns() async throws {
        for invalid in [VoiceLivePlayhead(host: .nan,seconds: 10,rate: 0,available: true),
                        .init(host: 100.5,seconds: .nan,rate: 0,available: true)] {
            let (root,project,repository,target) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let provider = MockVoiceProvider(), token = UUID()
            let controller = try await controller(project: project,provider: provider,target: target,token: token)
            controller.start(); try await waitFor { controller.mode == .recording }
            controller.record(.init(host: 100.2,seconds: 10,rate: 0,available: true),token: token)
            controller.record(invalid,token: token)
            #expect(!controller.playbackAvailable)
            // Even a transport callback must not extend the preceding span
            // across the unknown interval, despite matching paused seconds.
            controller.record(.init(host: 100.8,seconds: 10,rate: 0,available: true),kind: .pause,token: token)
            controller.record(.init(host: 101.2,seconds: 10,rate: 0,available: true),token: token)
            await provider.emit(.clock(audioStart: 0,duration: 1.2,hostStart: 100))
            await provider.emit(.speech(.init(segmentID: "lost-clock",text: "Retain these words across clock loss",isFinal: true,audioStart: 0.1,audioEnd: 1)))
            try await waitFor { controller.document.notes.count == 1 }
            #expect(controller.document.notes[0].state == .needsResolution && controller.unsavedActions == 0)
            #expect(await controller.stop())
            #expect(await controller.flushForExit())
            let reopened = try await repository.load()
            #expect(reopened.notes[0].text == "Retain these words across clock loss" && reopened.notes[0].state == .needsResolution)
            let spans = try #require(reopened.sessions.last).playhead
            #expect(spans.allSatisfy { $0.hostStart.isFinite && $0.confirmedThrough.isFinite && $0.seconds.isFinite })
            #expect(!spans.contains { $0.hostStart < 100.5 && $0.confirmedThrough > 100.5 })
        }
    }

}
