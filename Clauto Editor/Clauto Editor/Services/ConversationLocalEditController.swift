import Foundation
import Observation

/// Owns independent idle batching and local work. Provider availability is not
/// a prerequisite for a supported local command; no finalization button is needed.
@MainActor @Observable final class ConversationLocalEditController {
    private(set) var ledger: ConversationLocalEditLedger?
    private(set) var nextUpdateAt: Date?
    private(set) var running = false
    private(set) var paused = false
    private(set) var details = ""
    private(set) var error: String?
    @ObservationIgnored let project: Project
    @ObservationIgnored let engine: URL
    @ObservationIgnored private let repository: ConversationLocalEditRepository
    @ObservationIgnored private let factory: @Sendable () -> any ConversationLocalEditExecuting
    @ObservationIgnored private let admit: @MainActor (UUID) -> Bool
    @ObservationIgnored private let release: @MainActor (UUID) -> Void
    @ObservationIgnored private let onExport: @MainActor (DerivedCut) -> Void
    @ObservationIgnored private let idleInterval: TimeInterval
    @ObservationIgnored private var document: LiveConversationDocument?
    @ObservationIgnored private var unsent = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var feedbackGeneration = UUID()
    @ObservationIgnored private var idleTask: Task<Void,Never>?
    @ObservationIgnored private var idleID: UUID?
    @ObservationIgnored private var unacknowledgedClaim: (UUID,UUID)?
    @ObservationIgnored private var storageTask: (UUID,Task<Void,Never>)?
    @ObservationIgnored private var retryTask: (UUID,Task<Void,Never>)?
    @ObservationIgnored private var completionAdmission: ConversationLocalEditAdmission?
    @ObservationIgnored private var worker: Task<Void,Never>?
    @ObservationIgnored private var active: (UUID,any ConversationLocalEditExecuting,Task<DerivedCut,Error>)?
    private struct Completion {
        let id = UUID()
        let jobID: UUID
        let ownerID: UUID
        let export: DerivedCut?
        let cancelled: Bool
        let failure: String?
        let admission: ConversationLocalEditAdmission
        let generation: UUID
    }
    @ObservationIgnored private var pending: Completion?
    init(project: Project,engine: URL,idleInterval: TimeInterval = 120,
         factory: @escaping @Sendable () -> any ConversationLocalEditExecuting = { ConversationLocalEditWorker() },
         admit: @escaping @MainActor (UUID) -> Bool = { _ in true },
         release: @escaping @MainActor (UUID) -> Void = { _ in },
         onExport: @escaping @MainActor (DerivedCut) -> Void = { _ in }) {
        self.project = project;self.engine = engine;self.idleInterval = idleInterval
        repository = .init(project: project);self.factory = factory;self.admit = admit;self.release = release;self.onExport = onExport
    }
    var hasPendingWork: Bool { storageTask != nil || retryTask != nil || worker != nil || pending != nil || unacknowledgedClaim != nil }
    var savingPendingResult: Bool { pending != nil }
    var latestMatchesFeedback: Bool {
        guard !unsent,let document,let request = ledger?.jobs.last?.request else { return false }
        return request.sessionID==document.sessionID && request.feedbackIDs==document.messages.map(\.id)
    }
    private func applyLedger(_ value: ConversationLocalEditLedger) {
        guard value.projectID==project.id,value.revision >= (ledger?.revision ?? 0) else { return }
        ledger = value
    }
    func load() async {
        guard !loaded else { return }
        do { applyLedger(try await repository.recover());loaded = true;schedule() }
        catch { self.error = error.localizedDescription }
    }
    func observe(_ value: LiveConversationDocument,hasUnsentDraft: Bool) {
        guard value.projectID==project.id,value.revision >= (document?.revision ?? 0) else { return }
        if document?.messages.map(\.id) != value.messages.map(\.id) || hasUnsentDraft && !unsent { interruptOwnedWork() }
        document = value;unsent = hasUnsentDraft || value.draft?.text.isEmpty == false;schedule()
    }
    func steer() { unsent = true;interruptOwnedWork() }
    func resume() { paused = false;schedule() }
    func stopCurrent() { interruptOwnedWork() }
    var canRetryExport: Bool {
        guard !paused,!unsent,storageTask==nil,retryTask==nil,!running,pending==nil,error==nil,let state = ledger?.jobs.last?.state else { return false }
        return [.failed,.cancelled].contains(state)
    }
    func retryExport() async {
        guard canRetryExport,let id = ledger?.jobs.last?.id else { return }
        let token = UUID(),expected = generation
        // Reserve this writer before the first await. Quit joins it and a second
        // click cannot race another ledger retry. Completion never resumes pause.
        let task = Task { [self] in
            defer { if retryTask?.0==token { retryTask = nil } }
            do {
                applyLedger(try await repository.retry(id))
                guard generation==expected,!paused,!unsent else { return }
                kick()
            } catch { self.error = error.localizedDescription }
        }
        retryTask = (token,task);await task.value
    }
    private func interruptOwnedWork(invalidateCompletion: Bool = true) {
        if invalidateCompletion { feedbackGeneration = UUID();completionAdmission?.cancel();pending?.admission.cancel() }
        generation = UUID();idleTask?.cancel();idleTask = nil;idleID = nil;nextUpdateAt = nil
        if let active { active.2.cancel();Task { await active.1.cancel() } }
    }
    private func schedule() {
        idleTask?.cancel();idleTask = nil;idleID = nil;nextUpdateAt = nil
        guard loaded,!paused,!unsent,storageTask==nil,retryTask==nil,worker==nil,pending==nil,error==nil,
              idleInterval.isFinite,(0...86400).contains(idleInterval),let document,
              let last = document.latestActivity,!document.messages.isEmpty,
              document.messages.contains(where: { $0.localEdit != nil }) else { return }
        let expected = generation,token = UUID(),deadline = last.addingTimeInterval(idleInterval);nextUpdateAt = deadline;idleID = token
        idleTask = Task {
            do {
                try await Task.sleep(for: .seconds(max(0,deadline.timeIntervalSinceNow)));try Task.checkCancellation()
                guard generation==expected,!paused,!unsent else { return }
                let value = try await repository.enqueueIdle(idleInterval: idleInterval)
                guard idleID==token,generation==expected else { return }
                applyLedger(value);idleTask = nil;idleID = nil;nextUpdateAt = nil
                guard !paused,!unsent else { return };kick()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func kick() {
        guard !paused,!unsent,storageTask==nil,worker==nil,pending==nil,error==nil,let job = ledger?.jobs.last(where: { $0.state == .queued }) else { return }
        let owner = UUID(),expected = generation,expectedFeedback = feedbackGeneration
        guard admit(owner) else {
            idleTask = Task {
                do { try await Task.sleep(for: .seconds(3));try Task.checkCancellation();guard generation==expected else { return };kick() }
                catch is CancellationError {} catch { self.error = error.localizedDescription }
            };return
        }
        let admission = ConversationLocalEditAdmission();completionAdmission = admission
        running = true
        // This outer task is not cancelled by steering. Its separately owned
        // operation is cancelled/joined, then the terminal result is saved.
        worker = Task { [self] in
            defer { active = nil;completionAdmission = nil;worker = nil;running = false;release(owner);schedule() }
            var claimed = false
            do {
                unacknowledgedClaim = (job.id,owner)
                applyLedger(try await repository.claim(job.id,owner: owner));unacknowledgedClaim = nil
                guard ledger?.jobs.first(where: { $0.id==job.id })?.state == .running else { return };claimed = true
                guard generation==expected,!paused,!unsent else {
                    pending = .init(jobID: job.id,ownerID: owner,export: nil,cancelled: true,failure: nil,admission: admission,generation: expectedFeedback);await persistPending();return
                }
                let executor = factory(),operation = Task {
                    try await executor.execute(job.request,project: project,engine: engine) { [weak self] line in
                        await self?.receive(line,owner: owner)
                    }
                }
                active = (owner,executor,operation)
                let output = try await operation.value
                pending = .init(jobID: job.id,ownerID: owner,export: output,cancelled: generation != expected || paused || unsent || operation.isCancelled,failure: nil,admission: admission,generation: expectedFeedback)
                await persistPending()
            } catch {
                if claimed {
                    pending = .init(jobID: job.id,ownerID: owner,export: nil,cancelled: generation != expected || paused || unsent || error is CancellationError,failure: error.localizedDescription,admission: admission,generation: expectedFeedback)
                    await persistPending()
                } else { self.error = error.localizedDescription }
            }
        }
    }
    private func receive(_ line: ProcessLine,owner: UUID) {
        guard active?.0==owner else { return };details = String((details+line.text+"\n").suffix(4096))
    }
    private func persistPending() async {
        guard let value = pending else { return }
        do {
            let saved = try await repository.finish(value.jobID,owner: value.ownerID,export: value.export,cancelled: value.cancelled,failure: value.failure,admission: value.admission)
            applyLedger(saved)
            // A delayed acknowledgement only owns the Completion it captured.
            guard pending?.id==value.id else { return }
            if let output = value.export,!value.admission.cancelled,feedbackGeneration==value.generation,!unsent,
               ledger?.jobs.first(where: { $0.id==value.jobID })?.state == .succeeded { onExport(output) }
            pending = nil;error = nil
        } catch { self.error = error.localizedDescription }
    }
    func retrySaving() async {
        if let current = storageTask { await current.1.value;return }
        guard worker==nil,retryTask==nil else { return }
        let token = UUID()
        let task = Task { [self] in
            defer { if storageTask?.0==token { storageTask = nil;schedule() } }
            await recoverStorage()
        }
        storageTask = (token,task);await task.value
    }
    private func recoverStorage() async {
        if pending != nil { await persistPending() }
        else if let attempt = unacknowledgedClaim {
            do {
                applyLedger(try await repository.load())
                if let job = ledger?.jobs.first(where: { $0.id==attempt.0 }),job.state == .running,job.events.last?.ownerID==attempt.1 {
                    pending = .init(jobID: attempt.0,ownerID: attempt.1,export: nil,cancelled: true,failure: nil,admission: ConversationLocalEditAdmission(),generation: feedbackGeneration)
                    await persistPending();if pending==nil { unacknowledgedClaim = nil }
                } else { unacknowledgedClaim = nil;error = nil }
            } catch { self.error = error.localizedDescription }
        } else {
            do { applyLedger(try await repository.recover());loaded = true;error = nil }
            catch { self.error = error.localizedDescription }
        }
        schedule()
    }
    func pause() async {
        paused = true;let previousIdle = idleTask,previousRetry = retryTask?.1,previousStorage = storageTask?.1;interruptOwnedWork(invalidateCompletion: false)
        if let previousIdle { await previousIdle.value }
        if let previousRetry { await previousRetry.value }
        if let previousStorage { await previousStorage.value }
        if let active { active.2.cancel();await active.1.cancel() }
        await worker?.value
    }
    func flushForExit() async -> Bool {
        await pause();if pending != nil || unacknowledgedClaim != nil { await retrySaving() }
        return storageTask==nil && retryTask==nil && worker==nil && pending==nil && unacknowledgedClaim==nil
    }
}
