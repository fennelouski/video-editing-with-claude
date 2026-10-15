import Foundation
import Observation

private actor LiveReplyReceiver {
    private(set) var reply: LiveConversationReply
    init(session: UUID) { reply = .init(sessionID: session) }
    func receive(_ line: String) throws -> LiveConversationReply { try reply.receive(line); return reply }
}

@MainActor @Observable final class LiveConversationController {
    let project: Project
    private(set) var document: LiveConversationDocument?
    private(set) var draft = LiveConversationDocument.Draft.empty()
    private(set) var draftDirty = false
    private(set) var draftConflict = false
    private(set) var resolvingDraft = false
    private(set) var submitting = false
    private(set) var connecting = false
    private(set) var connected = false
    private(set) var disconnecting = false
    private(set) var needsSignIn = false
    private(set) var connectionDetail: String?
    private(set) var streaming = false
    private(set) var preparingReply = false
    private(set) var storagePending = false
    private(set) var nextPacketAt: Date?
    var error: String?
    @ObservationIgnored let repository: LiveConversationRepository
    @ObservationIgnored private var factory: (@Sendable () -> any ClaudeTurnTransport)?
    @ObservationIgnored private let injectedFactory: (@Sendable () -> any ClaudeTurnTransport)?
    @ObservationIgnored private let setupRunnerFactory: @Sendable () -> any CommandRunning
    @ObservationIgnored private let clientLocator: @Sendable () -> URL?
    @ObservationIgnored private var activeSetup: (UUID,any CommandRunning)?
    @ObservationIgnored private let idleInterval: TimeInterval
    @ObservationIgnored private var autosave: Task<Void,Never>?
    @ObservationIgnored private var worker: Task<Void,Never>?
    @ObservationIgnored private var idleTask: Task<Void,Never>?
    @ObservationIgnored private var activeTransport: (UUID,any ClaudeTurnTransport,Task<Void,Error>)?
    @ObservationIgnored private var preempted: Set<UUID> = []
    @ObservationIgnored private var pending: (UUID,LiveConversationReply,LiveConversationDocument.Turn.State,String?)?
    @ObservationIgnored private var unacknowledgedClaim: (UUID,UUID)?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var requestedRetry: UUID?
    @ObservationIgnored private var draftBase: LiveConversationDocument.Draft?
    @ObservationIgnored private var draftWrite: (UUID,Task<LiveConversationDocument,Error>)?
    @ObservationIgnored private var draftRecoveryGeneration = UUID()
    private enum DraftMutation { case save, submit, preserve, restore(UUID,UUID) }
    init(project: Project,syntheticFactory: (@Sendable () -> any ClaudeTurnTransport)? = nil,
         setupRunnerFactory: @escaping @Sendable () -> any CommandRunning = { ProcessRunner() },
         clientLocator: @escaping @Sendable () -> URL? = { ClaudeClientContract.locate() },idleInterval: TimeInterval = 120) {
        self.project = project; repository = .init(project: project)
        self.setupRunnerFactory = setupRunnerFactory; self.clientLocator = clientLocator
        self.injectedFactory = syntheticFactory; self.idleInterval = idleInterval
    }
    var hasPendingWork: Bool { draftDirty || draftWrite != nil || resolvingDraft || submitting || connecting || disconnecting || worker != nil || storagePending }
    var savingDraft: Bool { draftWrite != nil }
    var canSend: Bool { !submitting && !resolvingDraft && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.text.utf8.count <= 16_384 && !storagePending }
    var canRetryReply: Bool {
        guard worker == nil, !storagePending, let last = document?.turns.last else { return false }
        return [.failed,.cancelled,.interrupted].contains(last.state)
    }
    private func apply(_ value: LiveConversationDocument) {
        guard value.projectID == project.id, value.revision >= (document?.revision ?? 0) else { return }; document = value
    }
    func load() async {
        do {
            let value = try await repository.recover(); guard value.revision >= (document?.revision ?? 0) else { return }; apply(value)
            if !draftDirty, !submitting, !resolvingDraft, draftWrite == nil {
                if let saved = value.draft { draft = saved }
                draftBase = value.draft; draftConflict = false
            }
            schedulePacket()
        } catch { self.error = error.localizedDescription }
    }
    func edit(_ text: String) {
        guard !text.utf8.elementsEqual(draft.text.utf8), draft.revision < 1_000_000 else { return }
        draft.text = text; draft.revision += 1; draft.updated = Date(); draftDirty = true
        idleTask?.cancel(); idleTask = nil; nextPacketAt = nil
        autosave?.cancel(); let snapshot = draft
        autosave = Task {
            do {
                try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation()
                _ = try await writeDraft(snapshot)
                if draft == snapshot { draftDirty = false; draftConflict = false; autosave = nil; schedulePacket() }
            } catch is CancellationError {} catch { reportDraft(error) }
        }
    }
    private func reportDraft(_ failure: any Error) {
        if failure is LiveConversationDraftConflict { draftConflict = true }
        error = failure.localizedDescription
    }
    private func writeDraft(_ snapshot: LiveConversationDocument.Draft,mutation: DraftMutation = .save) async throws -> LiveConversationDocument {
        let previous = draftWrite?.1, id = UUID()
        let task = Task { [self] in
            defer { if draftWrite?.0 == id { draftWrite = nil } }
            if let previous { _ = try? await previous.value }
            let value: LiveConversationDocument
            switch mutation {
            case .save:
                value = try await repository.saveDraft(snapshot,expected: draftBase)
                if value.draft == snapshot { draftBase = snapshot }
            case .submit:
                value = try await repository.submitDraft(snapshot,expected: draftBase)
                if value.draft == nil { draftBase = nil }
            case .preserve: value = try await repository.preserveLocalDraft(snapshot)
            case .restore(let archive,let newID): value = try await repository.restoreRecoveredDraft(archive,newID: newID,local: snapshot)
            }
            apply(value); return value
        }
        draftWrite = (id,task)
        return try await task.value
    }
    func keepBothDrafts() async { await recoverDraft(nil) }
    func continueRecoveredDraft(_ id: UUID) async { await recoverDraft(id) }
    private func recoverDraft(_ archive: UUID?) async {
        guard !resolvingDraft, !submitting else { return }
        let snapshot = draft, generation = UUID(); draftRecoveryGeneration = generation
        resolvingDraft = true; autosave?.cancel(); autosave = nil
        defer { resolvingDraft = false; schedulePacket() }
        do {
            let mutation: DraftMutation = archive.map { .restore($0,UUID()) } ?? .preserve
            let value = try await writeDraft(snapshot,mutation: mutation)
            guard draftRecoveryGeneration == generation, draft == snapshot else {
                draftDirty = true; draftConflict = true
                error = "The earlier words are saved in Recovered Unsent Drafts. Keep Both Drafts again to preserve your newer changes."; return
            }
            draft = value.draft ?? .empty(); draftBase = value.draft
            draftDirty = false; draftConflict = false; error = nil
        } catch { reportDraft(error) }
    }
    func connect() async { await connect(signingIn: false) }
    func signIn() async { await connect(signingIn: true) }
    private func connect(signingIn: Bool) async {
        guard !connecting, !connected, !disconnecting else { return }
        let generation = UUID(); connectionGeneration = generation
        connecting = true; needsSignIn = false; connectionDetail = "Connecting to your Claude account…"
        defer {
            if connectionGeneration == generation { connecting = false; connectionDetail = nil }
            if activeSetup?.0 == generation { activeSetup = nil }
        }
        do {
            if let injectedFactory {
                guard injectedFactory().isSyntheticFixture else { throw ClaudeFailure.disabled }
                factory = injectedFactory
            } else {
                guard let executable = clientLocator() else { throw ClaudeClientFailure.missing }
                let runner = setupRunnerFactory(); activeSetup = (generation,runner)
                let contract = try await ClaudeClientContract.inspect(executable: executable,runner: runner)
                guard connectionGeneration == generation else { return }
                let account = ClaudeAccountService(contract: contract,runner: runner)
                if signingIn {
                    connectionDetail = "Finish signing in in your browser. Your messages are saved here."
                    try await account.signIn()
                } else {
                    switch try await account.status() {
                    case .ready: break
                    case .signedOut: throw ClaudeClientFailure.signInRequired
                    case .differentAccountMethod: throw ClaudeClientFailure.subscriptionRequired
                    }
                }
                guard connectionGeneration == generation else { return }
                // A fresh transport/runner per turn makes late cancellation
                // incapable of stopping a later reply's process.
                factory = { ClaudeCLITransport(contract: contract) }
            }
            guard connectionGeneration == generation else { return }
            connected = true; error = nil; kick()
        } catch is CancellationError {
        } catch {
            if connectionGeneration == generation {
                self.error = error.localizedDescription; needsSignIn = (error as? ClaudeClientFailure)?.offersSignIn == true
            }
        }
    }
    @discardableResult func submit() async -> Bool {
        guard canSend else { return false }
        submitting = true; defer { submitting = false; kick(); schedulePacket() }
        let snapshot = draft, generation = connectionGeneration, earlier = activeTransport
        do {
            autosave?.cancel(); autosave = nil
            _ = try await writeDraft(snapshot,mutation: .submit)
            if draft == snapshot { autosave?.cancel(); autosave = nil; draft = .empty(); draftDirty = false }
            error = nil
            guard connectionGeneration == generation, !disconnecting else { return true }
            if let active = earlier {
                preempted.insert(active.0)
                // Capture the old instance, not whichever transport is current
                // after the next suspension. Instances are never reused.
                active.2.cancel(); Task { await active.1.cancel() }
            }
            if !connected {
                // Connecting must not hold the composer transaction open.
                // Delayed setup may start only in this submission's generation.
                Task { [weak self] in
                    guard let self, self.connectionGeneration == generation, !self.disconnecting else { return }
                    await self.connect()
                }
            } else { kick() }
            return true
        } catch { reportDraft(error); return false }
    }
    func retryReply() async {
        guard canRetryReply else { return }
        requestedRetry = document?.turns.last?.id
        if !connected { await connect() }; kick()
    }
    private func kick() {
        guard connected, factory != nil, worker == nil, !storagePending,
              requestedRetry != nil || document?.queued.isEmpty == false else { return }
        let generation = connectionGeneration
        worker = Task { [self] in
            var mayRestart = true
            defer { worker = nil; streaming = false; preparingReply = false; activeTransport = nil; schedulePacket(); if mayRestart { kick() } }
            while connected, !storagePending, connectionGeneration == generation {
                preparingReply = true
                var acknowledgedClaim: (UUID,UUID)?
                do {
                    let current = try await repository.recover(); apply(current)
                    guard connected, connectionGeneration == generation else { return }
                    guard current.running == nil else { mayRestart = false; error = "Another conversation reply is still running. Your new messages remain queued."; return }
                    guard requestedRetry != nil || !current.queued.isEmpty else { return }
                    if let previous = requestedRetry, current.turns.last?.id != previous {
                        requestedRetry = nil; mayRestart = false
                        error = "This reply changed in another window. Its history is saved; choose the latest reply to retry."; return
                    }
                    let id = UUID(); unacknowledgedClaim = (id,current.sessionID)
                    let claimed: LiveConversationDocument
                    if let previous = requestedRetry {
                        claimed = try await repository.retryTurn(previous,id: id); requestedRetry = nil
                    } else { claimed = try await repository.beginTurn(id: id) }
                    apply(claimed)
                    unacknowledgedClaim = nil; acknowledgedClaim = (id,claimed.sessionID)
                    let turn = try claimed.turns.first(where: { $0.id == id }).unwrap()
                    let prompt = try claimed.prompt(for: turn.messageIDs)
                    let workspace = try await repository.textOnlyWorkspace(session: claimed.sessionID)
                    guard connected, connectionGeneration == generation else {
                        try await saveCompletion(id,reply: .init(sessionID: claimed.sessionID),state: .cancelled,failure: nil)
                        return
                    }
                    guard let factory else { throw ClaudeFailure.disabled }
                    let transport = factory(); streaming = true
                    let resume = claimed.turns.dropLast().contains { $0.events.contains(.session(claimed.sessionID)) }
                    var request = ClaudeTurnRequest(sessionID: claimed.sessionID,resume: resume,prompt: prompt,project: project.folder,engine: project.folder)
                    request.projectID = project.id; request.textOnlyWorkspace = workspace
                    request.textAuthorization = .init(projectID: project.id,text: prompt)
                    let receiver = LiveReplyReceiver(session: claimed.sessionID)
                    let outgoing = request
                    // Steering cancels only this owned network task. The worker
                    // stays uncancelled so it can acknowledge the final words.
                    // This task is always joined before the worker moves on.
                    let response = Task.detached(priority: .userInitiated) { [repository,weak self] in
                        try Task.checkCancellation()
                        try await transport.turn(outgoing) { line in
                            let reply = try await receiver.receive(line)
                            let value = try await repository.updateTurn(id,reply: reply)
                            await self?.receiveProgress(value)
                        }
                    }
                    activeTransport = (id,transport,response)
                    preparingReply = false
                    var failure: String?
                    do {
                        try await response.value
                    } catch {
                        failure = error.localizedDescription
                        if (error as? ClaudeClientFailure)?.offersSignIn == true { needsSignIn = true }
                    }
                    let reply = await receiver.reply
                    let state: LiveConversationDocument.Turn.State
                    if preempted.contains(id) || !connected || connectionGeneration != generation { state = .cancelled }
                    else if reply.finished, failure == nil {
                        state = reply.failed ? .failed:.succeeded
                        if reply.failed { failure = "Claude could not finish this reply. Your message and received words are saved. Reconnect to try again." }
                    }
                    else { state = .failed; failure = failure ?? ClaudeFailure.incomplete.localizedDescription }
                    preempted.remove(id); activeTransport = nil; streaming = false
                    try await saveCompletion(id,reply: reply,state: state,failure: failure)
                    if state == .failed { error = failure ?? reply.text; connected = false; mayRestart = false; return }
                } catch {
                    mayRestart = false
                    if pending == nil, let claim = acknowledgedClaim {
                        pending = (claim.0,.init(sessionID: claim.1),connected ? .failed:.cancelled,"This reply could not start. Your submitted message remains saved.")
                    }
                    if unacknowledgedClaim != nil || pending != nil { storagePending = true }
                    self.error = error.localizedDescription; return
                }
            }
        }
    }
    private func saveCompletion(_ id: UUID,reply: LiveConversationReply,state: LiveConversationDocument.Turn.State,failure: String?) async throws {
        pending = (id,reply,state,failure); unacknowledgedClaim = nil; storagePending = true
        apply(try await repository.updateTurn(id,reply: reply,state: state,failure: failure))
        pending = nil; storagePending = false
    }
    private func receiveProgress(_ value: LiveConversationDocument) { apply(value) }
    func retryStorage() async {
        guard !resolvingDraft else { return }
        if worker == nil, storagePending, let claim = unacknowledgedClaim {
            do {
                let value = try await repository.load(); apply(value)
                if value.turns.contains(where: { $0.id == claim.0 }) {
                    pending = (claim.0,.init(sessionID: claim.1),.failed,"This reply could not start. Your submitted message remains saved.")
                }
                unacknowledgedClaim = nil; storagePending = pending != nil
            } catch { self.error = error.localizedDescription; return }
        }
        if worker == nil, let pending {
            do {
                apply(try await repository.updateTurn(pending.0,reply: pending.1,state: pending.2,failure: pending.3))
                self.pending = nil; storagePending = false; error = nil
            } catch { self.error = error.localizedDescription; return }
        }
        if draftDirty {
            autosave?.cancel(); autosave = nil
            let snapshot = draft
            do { _ = try await writeDraft(snapshot); if draft == snapshot { draftDirty = false; draftConflict = false } }
            catch { reportDraft(error); return }
        }
        kick(); schedulePacket()
    }
    func disconnect() async {
        guard !disconnecting else { return }
        disconnecting = true; defer { disconnecting = false }
        connected = false; connectionGeneration = UUID(); connecting = false
        connectionDetail = nil
        let setup = activeSetup; activeSetup = nil
        if let setup { await setup.1.cancel() }
        idleTask?.cancel(); idleTask = nil; nextPacketAt = nil
        let current = activeTransport; if let current { preempted.insert(current.0); current.2.cancel(); await current.1.cancel() }
        await worker?.value
    }
    func flushForExit() async -> Bool {
        await disconnect(); autosave?.cancel(); autosave = nil
        if let draftWrite { _ = try? await draftWrite.1.value }
        await retryStorage()
        return !draftDirty && draftWrite == nil && !resolvingDraft && !storagePending && !submitting && !connecting && !disconnecting
    }
    private func schedulePacket() {
        idleTask?.cancel(); idleTask = nil; nextPacketAt = nil
        guard !draftDirty, !submitting, !resolvingDraft, !storagePending, document?.running == nil,
              document?.queued.isEmpty == true, draft.text.isEmpty, let last = document?.latestActivity,
              idleInterval.isFinite, (0...86_400).contains(idleInterval) else { return }
        let deadline = last.addingTimeInterval(idleInterval); nextPacketAt = deadline
        idleTask = Task {
            do {
                try await Task.sleep(for: .seconds(min(idleInterval,max(0,deadline.timeIntervalSinceNow)))); try Task.checkCancellation()
                guard !draftDirty, !submitting, draft.text.isEmpty else { return }
                apply(try await repository.sealIdlePacket(idleInterval: idleInterval)); nextPacketAt = nil; idleTask = nil
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped { guard let self else { throw ProjectFailure.invalidProject }; return self }
}
