import Foundation
import Observation
import AVFoundation

struct VoiceLivePlayhead: Sendable {
    let host: Double
    let seconds: Double
    let rate: Double
    let available: Bool
    static var now: Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

/// One project-owned controller outlives changing VersionReview view identities.
/// MainActor owns UI/player sampling; repositories/processors own background work.
/// Per-version composer ownership survives pane collapse and view replacement.
@MainActor @Observable final class VoiceTypedComposer {
    var text = ""
    var start = ""
    var end = ""
    var action = VoiceRangeAction.protect
    var saving = false
}

@MainActor @Observable final class VoiceCardInput { var splitAfter = "" }

@MainActor @Observable
final class VoiceReviewController {
    enum Mode: String { case idle, starting, recording, finishing, failed }
    let project: Project
    private(set) var document: VoiceReviewDocument
    private(set) var target: VoiceReviewTarget?
    private(set) var mode: Mode = .idle
    private(set) var devices: [VoiceInputDevice] = []
    private(set) var access: VoiceReviewAccess?
    private(set) var drafts: [UUID: VoiceTranscriptDraft] = [:]
    private(set) var level: Float = 0
    private(set) var pendingWrites = 0
    private(set) var unsavedActions = 0
    private(set) var renderingCandidateID: UUID?
    private(set) var renderProgress = ""
    private(set) var candidatePlaybackID: UUID?
    private(set) var frameCommentLease: UUID?
    var restructuringCards: Set<UUID> = []
    var cardInputs: [UUID:VoiceCardInput] = [:]
    func cardInput(for note: UUID) -> VoiceCardInput {
        if let value = cardInputs[note] { return value }
        let value = VoiceCardInput(); cardInputs[note] = value; return value
    }
    var visibleCards: [VoiceReviewNote] {
        let visible = document.orderedVisibleNotes
        let retained = document.notes.filter { note in !(note.supersededBy ?? []).isEmpty && drafts[note.id] != nil }
        // In-memory drafts take precedence over delayed disk acknowledgements.
        return visible + retained
    }
    func restructureCards(_ request: VoiceCardRequest) {
        let ids = Set(request.parents.map(\.id))
        guard restructuringCards.isDisjoint(with: ids), ids.allSatisfy({ drafts[$0] == nil }) else { error = "Finish or discard these card drafts before changing their structure."; return }
        restructuringCards.formUnion(ids)
        let write = enqueue(retainFailure: false) { try await $0.restructureCards(request) }
        cardTasks[request.id] = Task { @MainActor in
            defer { restructuringCards.subtract(ids); cardTasks[request.id] = nil }
            _ = await write.value
        }
    }
    var typedComposers: [UUID:VoiceTypedComposer] = [:]
    func typedComposer(for version: UUID) -> VoiceTypedComposer {
        if let value = typedComposers[version] { return value }
        let value = VoiceTypedComposer(); typedComposers[version] = value; return value
    }
    var error: String?
    var selectedDeviceUID: String
    var locale: String
    @ObservationIgnored let repository: VoiceReviewRepository
    @ObservationIgnored private let previewService = VoiceCandidatePreviewService()
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private let worker: VoiceCandidateWorker
    @ObservationIgnored private let provider: any VoiceReviewDictating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var writes: Task<Bool, Never>?
    @ObservationIgnored private var retryingStorage = false
    @ObservationIgnored private var failedWrites: [@Sendable (VoiceReviewRepository) async throws -> VoiceReviewDocument] = []
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Bool, Never>?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var draftTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cardTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStopCancelled = false
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var attemptID: UUID?
    @ObservationIgnored private var viewToken: UUID?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var latest: VoiceLivePlayhead?
    @ObservationIgnored private var clockSampler: (@MainActor () -> VoiceLivePlayhead)?

    init(project: Project, provider: any VoiceReviewDictating = DictateReviewAdapter(), defaults: UserDefaults = .standard,
         processor: any VoiceCandidateProcessing = LocalVoiceCandidateProcessor()) throws {
        self.project = project; self.provider = provider; self.defaults = defaults
        selectedDeviceUID = defaults.string(forKey: "ClautoVoiceReviewMicrophoneUID") ?? ""
        locale = defaults.string(forKey: "ClautoVoiceReviewLocale") ?? Locale.current.identifier
        document = .init(projectID: project.id)
        let repository = try VoiceReviewRepository(project: project); self.repository = repository
        worker = VoiceCandidateWorker(repository: repository, processor: processor)
    }
    var active: Bool { [.starting,.recording,.finishing].contains(mode) }
    var hasPendingWork: Bool { !restructuringCards.isEmpty || sessionID != nil || startTask != nil || stopTask != nil || active || pendingWrites > 0 || unsavedActions > 0 || prepareTask != nil || !draftTasks.isEmpty || renderTask != nil }
    var canStart: Bool { frameCommentLease == nil && candidatePlaybackID == nil && !active && sessionID == nil && startTask == nil && stopTask == nil && unsavedActions == 0 && target != nil && latest?.available == true && access?.canStart == true && devices.contains(where: { $0.id == selectedDeviceUID }) }
    var canStop: Bool { sessionID != nil }

    var canPresentCandidate: Bool { frameCommentLease == nil && candidatePlaybackID == nil && !active && sessionID == nil && startTask == nil && stopTask == nil }
    func beginCandidatePlayback(_ token: UUID) -> Bool {
        guard canPresentCandidate else { error = "Stop and finalize voice capture before playing a review candidate."; return false }
        candidatePlaybackID = token; return true
    }
    func beginFrameComment(_ token: UUID) -> Bool {
        guard canPresentCandidate else { error = "Stop and finalize voice capture and close the candidate player before adding a frame comment."; return false }
        frameCommentLease = token; return true
    }
    func endFrameComment(_ token: UUID) { if frameCommentLease == token { frameCommentLease = nil } }
    func endCandidatePlayback(_ token: UUID) { if candidatePlaybackID == token { candidatePlaybackID = nil } }

    func isAttached(to token: UUID) -> Bool { viewToken == token }

    private func apply(_ value: VoiceReviewDocument) {
        guard value.projectID == project.id, value.sequence >= document.sequence else { return }; document = value
        if let id = renderingCandidateID, let candidate = document.candidates.first(where: { $0.id == id }) {
            let relevant = document.notes.filter { $0.state != .cancelled && ($0.effectiveAnchor?.targetID == candidate.parent.id || $0.effectiveAnchor == nil) }
            if candidate.state != .prepared || relevant.map({ VoiceNoteRevision(id: $0.id,revision: $0.revision) }) != candidate.noteRevisions {
                renderTask?.cancel(); Task { await previewService.cancel() }
            }
        }
    }
    func load() async {
        if let loadTask { await loadTask.value; return }
        guard !loaded else { return }
        let task = Task {
            do { apply(try await repository.recover()); drafts = Dictionary(uniqueKeysWithValues: (document.drafts ?? []).map { ($0.noteID, $0) }); loaded = true; error = document.sessions.last?.failure; await refreshAccess() }
            catch { self.error = error.localizedDescription }
        }
        loadTask = task; await task.value; loadTask = nil
    }
    func refreshAccess() async { devices = await provider.devices(); access = await provider.access(locale: locale) }
    func chooseDevice(_ uid: String) {
        guard !active else { return }; selectedDeviceUID = uid; defaults.set(uid, forKey: "ClautoVoiceReviewMicrophoneUID")
    }
    func requestMicrophonePermission() async { _ = await provider.requestMicrophonePermission(); await refreshAccess() }
    func requestSpeechPermission() async { _ = await provider.requestSpeechPermission(); await refreshAccess() }

    func willAttach(_ token: UUID) {
        if let old = clockSampler?() { record(old, token: viewToken) }
        viewToken = token; target = nil; epoch = UUID(); clockSampler = nil
        record(.init(host: VoiceLivePlayhead.now, seconds: 0, rate: 0, available: false), kind: .versionChanged, token: token)
    }
    func attach(_ value: VoiceReviewTarget, token: UUID, sampler: @escaping @MainActor () -> VoiceLivePlayhead) async {
        guard viewToken == token else { return }
        do {
            let registered = try await repository.register(value)
            guard viewToken == token else { return }
            target = registered; clockSampler = sampler; epoch = UUID()
            record(sampler(), kind: .versionChanged, token: token)
        } catch { self.error = error.localizedDescription }
    }
    func detach(_ token: UUID) {
        guard viewToken == token else { return }
        let sample = clockSampler?() ?? .init(host: VoiceLivePlayhead.now, seconds: 0, rate: 0, available: false)
        record(sample, kind: .unavailable, token: token)
        viewToken = nil; target = nil; clockSampler = nil
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if viewToken == nil { _ = await stop() }
        }
    }

    @discardableResult private func enqueue(retainFailure: Bool = true, _ operation: @escaping @Sendable (VoiceReviewRepository) async throws -> VoiceReviewDocument) -> Task<Bool, Never> {
        let preceding = writes; pendingWrites += 1
        let task = Task {
            _ = await preceding?.value
            defer { pendingWrites -= 1 }
            do { apply(try await operation(repository)); kickPreparation(); return true }
            catch {
                self.error = error.localizedDescription
                if retainFailure { failedWrites.append(operation); unsavedActions = failedWrites.count }
                if retainFailure && active { Task { _ = await self.stop(cancel: true) } }
                return false
            }
        }
        writes = task; return task
    }

    func record(_ sample: VoiceLivePlayhead, kind: VoiceTransportKind = .sample, token: UUID?) {
        guard token == viewToken, sample.host.isFinite, sample.seconds.isFinite else { return }
        let event = kind == .sample && latest?.rate != nil && latest?.rate != sample.rate ? VoiceTransportKind.rateChanged : kind
        latest = sample
        guard let id = sessionID else { return }
        if pendingWrites > 32 && event == .sample { return }
        if pendingWrites > 256 { error = "Voice review storage cannot keep up. Capture stopped; resolve incomplete feedback."; Task { _ = await stop(cancel: true) }; return }
        if event != .sample { epoch = UUID() }
        let boundTarget = sample.available && kind != .seekRequested && kind != .unavailable ? target?.id : nil
        let generation = epoch
        enqueue { repo in try await repo.observe(session: id, host: sample.host, seconds: max(0,sample.seconds), rate: sample.rate,
            target: boundTarget, epoch: generation, kind: event) }
    }

    func start() {
        guard canStart, let target, let sample = clockSampler?() ?? latest else { error = "Choose a verified version and microphone, then grant the required access before starting."; return }
        error = nil; mode = .starting
        let id = UUID(), attempt = UUID(), uid = selectedDeviceUID, language = locale
        sessionID = id; attemptID = attempt
        startTask = Task { [self] in
            defer { startTask = nil }
            do {
                try VoiceReviewProvenance.check(target, project: project)
                guard await enqueue({ try await $0.begin(id: id, attempt: attempt, deviceUID: uid, locale: language) }).value else { throw WorkflowFailure.invalid("The session could not be saved. No microphone was started.") }
                guard sessionID == id, mode == .starting else { return }
                try Task.checkCancellation()
                record(sample, kind: .versionChanged, token: viewToken)
                guard await writes?.value == true else { throw WorkflowFailure.invalid("The playback anchor could not be saved. No microphone was started.") }
                let stream = try await provider.start(session: id, deviceUID: uid, locale: language)
                try Task.checkCancellation()
                guard sessionID == id, mode == .starting else { await provider.stop(session: id, cancel: true); return }
                mode = .recording
                consumer = Task { [weak self] in
                    for await event in stream {
                        guard !Task.isCancelled, let self else { break }
                        await self.receive(event, session: id, attempt: attempt)
                    }
                }
            } catch {
                self.error = error.localizedDescription
                await provider.stop(session: id, cancel: true)
                // Stop owns terminal persistence; it waits for this start task to
                // return and retains failed ingress before closing the session.
                pendingStopCancelled = true
                if sessionID == id { mode = .failed }
                Task { _ = await self.stop(cancel: true) }
            }
        }
    }

    private func receive(_ event: VoiceDictationEvent, session id: UUID, attempt: UUID) async {
        guard sessionID == id, attemptID == attempt else { return }
        switch event {
        case .level(let value): level = value
        case .clock(let audioStart, let duration, let hostStart):
            if let sample = clockSampler?() { record(sample, token: viewToken) }
            _ = await enqueue { try await $0.captured(session: id, attempt: attempt, audioStart: audioStart, duration: duration, hostStart: hostStart) }.value
        case .speech(let result): _ = await enqueue { try await $0.speech(result, session: id, attempt: attempt) }.value
        case .failure(let detail):
            error = detail
            if mode != .finishing { _ = await stop(cancel: true) }
        case .ended: break
        }
    }

    func stop(cancel: Bool = false) async -> Bool {
        if let stopTask { return await stopTask.value }
        guard let id = sessionID else { _ = await writes?.value; return unsavedActions == 0 }
        let finalCancel = cancel || pendingStopCancelled
        pendingStopCancelled = finalCancel
        mode = .finishing
        let starting = startTask; starting?.cancel()
        let operation = Task { () -> Bool in
            await starting?.value
            await provider.stop(session: id, cancel: finalCancel)
            if finalCancel { consumer?.cancel() } else { await consumer?.value }
            _ = await writes?.value
            guard unsavedActions == 0 else { consumer = nil; mode = .failed; return false }
            do {
                apply(try await repository.end(session: id, state: finalCancel ? .cancelled : .stopped, failure: error))
                if sessionID == id { sessionID = nil; attemptID = nil; mode = .idle; level = 0 }
                consumer = nil; pendingStopCancelled = false; return true
            } catch { self.error = error.localizedDescription; mode = .failed; return false }
        }
        stopTask = operation
        let result = await operation.value; stopTask = nil; return result
    }

    private func kickPreparation() {
        guard prepareTask == nil, unsavedActions == 0, document.notes.contains(where: { $0.state == .ready }) else { return }
        prepareTask = Task {
            var drained = false
            do { try await worker.drain(); apply(try await repository.load()); scheduleRenderIntent(); drained = true }
            catch { self.error = error.localizedDescription }
            prepareTask = nil
            // A ready note may have arrived after the worker's final empty claim.
            if drained && !Task.isCancelled && document.processingJobID == nil { kickPreparation() }
        }
    }
    private func scheduleRenderIntent() {
        debounceTask?.cancel()
        let ids = document.candidates.filter { $0.state == .prepared && !$0.renderRequested }.map(\.id)
        guard !ids.isEmpty else { return }
        debounceTask = Task {
            do {
                try await Task.sleep(for: .seconds(2))
                for id in ids { try Task.checkCancellation(); apply(try await repository.requestRender(candidate: id)) }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func retainDraft(_ draft: VoiceTranscriptDraft) {
        drafts[draft.noteID] = draft; draftTasks[draft.noteID]?.cancel()
        draftTasks[draft.noteID] = Task {
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
            catch { return }
            _ = await enqueue { try await $0.saveDraft(draft) }.value
            if drafts[draft.noteID] == draft { draftTasks[draft.noteID] = nil }
        }
    }
    func discardDraft(_ id: UUID) {
        draftTasks[id]?.cancel(); draftTasks[id] = nil; drafts[id] = nil
        enqueue { try await $0.discardDraft(id) }
    }
    func edit(_ note: VoiceReviewNote, text: String, intent: VoiceIntent, anchor: VoiceNoteAnchor?, expectedRevision: Int? = nil, action: VoiceRangeAction? = nil) async -> Bool {
        let submittedDraft = drafts[note.id]
        draftTasks[note.id]?.cancel(); draftTasks[note.id] = nil
        let saved = await enqueue(retainFailure: false) { try await $0.edit(note: note.id, expectedRevision: expectedRevision ?? note.revision, text: text, intent: intent, anchor: anchor, action: action) }.value
        if saved { if drafts[note.id] == submittedDraft { drafts[note.id] = nil } }
        else if let draft = drafts[note.id] { retainDraft(draft) }
        return saved
    }
    func cancel(_ note: VoiceReviewNote) async { _ = await enqueue { try await $0.cancel(note: note.id) }.value }
    func retry(_ note: VoiceReviewNote) async { _ = await enqueue { try await $0.retry(note: note.id) }.value }
    @discardableResult func addTyped(text: String, action: VoiceRangeAction, start: Double, end: Double, expectedTarget: VoiceReviewTarget) async -> Bool {
        guard let target else { error = "Select the watched player before adding feedback."; return false }
        guard expectedTarget == target else { error = "The selected video changed. Your draft is retained; select its original version and save again."; return false }
        return await enqueue(retainFailure: false) { try await $0.addTyped(text: text,action: action,anchor: .init(targetID: target.id,seconds: start,endSeconds: end)) }.value
    }
    func prepareEditPlan(_ candidate: VoiceRevisionCandidate) async { _ = await enqueue(retainFailure: false) { try await $0.prepareEditPlan(candidate.id) }.value }
    func approveEditPlan(_ candidate: VoiceRevisionCandidate) async {
        guard let sha = candidate.editPlanSHA256 else { return }
        _ = await enqueue(retainFailure: false) { try await $0.approveEditPlan(candidate.id,expectedSHA: sha) }.value
    }
    func renderPreview(_ candidate: VoiceRevisionCandidate, engine: URL) {
        guard renderTask == nil else { return }; renderingCandidateID = candidate.id; renderProgress = "Waiting for a render slot"
        renderTask = Task {
            do {
                apply(try await previewService.render(repository: repository,candidateID: candidate.id,engine: engine,onLine: { [self] line in
                    guard !line.isError, let bytes = line.text.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: bytes) as? [String:Any], let phase = event["phase"] as? String else { return }
                    let label: String
                    switch phase {
                    case "waiting_for_render_slot": label = "Waiting for a render slot"
                    case "source_snapshot_chunk", "source_snapshot_ready": label = "Verifying a private temporary copy of the watched movie"
                    case "render_fragment": label = "Rendering approved movie ranges"
                    case "candidate_verified": label = "Candidate frames and audio verified"
                    default: return
                    }
                    await self.showRenderProgress(label,candidate: candidate.id)
                }))
            } catch { self.error = error.localizedDescription }
            renderingCandidateID = nil; renderTask = nil
        }
    }
    private func showRenderProgress(_ value: String, candidate: UUID) { if renderingCandidateID == candidate { renderProgress = value } }
    func cancelRender() async { renderTask?.cancel(); await previewService.cancel(); await renderTask?.value }

    func retryStorage() async {
        guard !retryingStorage else { return }; retryingStorage = true
        defer { retryingStorage = false }
        _ = await writes?.value
        while let operation = failedWrites.first {
            do { apply(try await operation(repository)); failedWrites.removeFirst(); unsavedActions = failedWrites.count }
            catch { self.error = error.localizedDescription; return }
        }
        if sessionID != nil && mode == .failed { _ = await stop(cancel: pendingStopCancelled) }
        kickPreparation()
    }
    func flushForExit() async -> Bool {
        await cancelRender()
        _ = await stop()
        for task in Array(cardTasks.values) { await task.value }
        for task in Array(draftTasks.values) { await task.value }
        _ = await writes?.value
        await retryStorage()
        prepareTask?.cancel(); await prepareTask?.value; debounceTask?.cancel()
        return sessionID == nil && !active && pendingWrites == 0 && unsavedActions == 0 && draftTasks.isEmpty && restructuringCards.isEmpty && cardTasks.isEmpty
    }
}
