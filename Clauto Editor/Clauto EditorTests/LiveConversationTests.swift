import Foundation
import Testing
import Synchronization
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor ConversationFixtureState {
    let holdFirst: Bool
    let failAfterResult: Bool
    let holdBeforeFirst: Bool
    var requests: [ClaudeTurnRequest] = []
    init(holdFirst: Bool = false,failAfterResult: Bool = false,holdBeforeFirst: Bool = false) {
        self.holdFirst = holdFirst; self.failAfterResult = failAfterResult; self.holdBeforeFirst = holdBeforeFirst
    }
    func append(_ value: ClaudeTurnRequest) -> Int { requests.append(value); return requests.count }
}
private actor ConversationFixtureTransport: ClaudeTurnTransport {
    nonisolated let isSyntheticFixture = true
    let state: ConversationFixtureState
    private var cancelled = false
    private var waiter: CheckedContinuation<Void,Never>?
    init(_ state: ConversationFixtureState) { self.state = state }
    func turn(_ request: ClaudeTurnRequest,onLine: @escaping @Sendable (String) async throws -> Void) async throws {
        let index = await state.append(request)
        if state.holdBeforeFirst, index == 1, !cancelled { await withCheckedContinuation { waiter = $0 } }
        if cancelled { throw CancellationError() }
        try await onLine("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\(request.sessionID)\"}")
        try await onLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Partial 🥖"}}}"#)
        if state.holdFirst, index == 1, !cancelled { await withCheckedContinuation { waiter = $0 } }
        if cancelled { throw CancellationError() }
        try await onLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"A concrete synthetic suggestion."}]}}"#)
        try await onLine(#"{"type":"result","subtype":"success","is_error":false,"result":"A concrete synthetic suggestion."}"#)
        if state.failAfterResult { throw WorkflowFailure.invalid("Synthetic process failed after its result") }
    }
    func cancel() { cancelled = true; waiter?.resume(); waiter = nil }
    func release() { waiter?.resume(); waiter = nil }
}
private actor ConversationCommandFixture: CommandRunning {
    var commands: [ProcessCommand] = []
    var cancelled = 0
    let lines: [String]
    let help: String
    init(lines: [String] = [],help: String = ClaudeClientContract.requiredFlags.joined(separator: " ")) { self.lines = lines; self.help = help }
    func run(_ command: ProcessCommand,onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        commands.append(command)
        if command.arguments == ["--help"] { return .init(exitCode: 0,output: help,error: "",cancelled: false) }
        for line in lines { await onLine?(.init(text: line,isError: false)) }
        return .init(exitCode: 0,output: "",error: "",cancelled: cancelled > 0)
    }
    func cancel() { cancelled += 1 }
}
private actor ConversationAccountFixture: CommandRunning {
    var commands: [ProcessCommand] = []
    var statuses: [ProcessResult]
    var holdingHelp: Bool
    var holdingStatus: Bool
    private var waiter: CheckedContinuation<Void,Never>?
    private(set) var helpStarted = false
    private(set) var statusStarted = false
    private(set) var cancellations = 0
    init(statuses: [ProcessResult],holdingHelp: Bool = false,holdingStatus: Bool = false) {
        self.statuses = statuses; self.holdingHelp = holdingHelp; self.holdingStatus = holdingStatus
    }
    func run(_ command: ProcessCommand,onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        commands.append(command)
        if command.arguments == ["--help"] {
            helpStarted = true
            if holdingHelp { await withCheckedContinuation { waiter = $0 } }
            return .init(exitCode: 0,output: ClaudeClientContract.requiredFlags.joined(separator: " "),error: "",cancelled: false)
        }
        if command.arguments == ["auth","login","--claudeai"] { return .init(exitCode: 0,output: "",error: "",cancelled: false) }
        guard command.arguments == ["auth","status","--json"], !statuses.isEmpty else { throw WorkflowFailure.invalid("Unexpected synthetic account command") }
        statusStarted = true
        if holdingStatus { await withCheckedContinuation { waiter = $0 } }
        return statuses.removeFirst()
    }
    func releaseHelp() { holdingHelp = false; waiter?.resume(); waiter = nil }
    func releaseStatus() { holdingStatus = false; waiter?.resume(); waiter = nil }
    // Deliberately leave the old help response pending to test late completion.
    func cancel() { cancellations += 1 }
}

struct LiveConversationTests {
    private func fixture() async throws -> (URL,Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-live-"+UUID().uuidString)
        let engine = root.appendingPathComponent("engine"); try FileManager.default.createDirectory(at: engine,withIntermediateDirectories: true)
        return (root,try await ProjectRepository().create(name: "Synthetic live conversation",root: root,engine: engine))
    }
    private func line(_ object: [String:Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object),as: UTF8.self) }
    private func complete(_ session: UUID,text: String = "Synthetic answer") throws -> LiveConversationReply {
        var reply = LiveConversationReply(sessionID: session)
        try reply.receive(line(["type":"system","subtype":"init","session_id":session.uuidString]))
        try reply.receive(line(["type":"result","subtype":"success","is_error":false,"result":text])); return reply
    }
    private func accountResult(_ method: String,exit: Int32 = 0) -> ProcessResult {
        .init(exitCode: exit,output: "{\"authMethod\":\"\(method)\"}",error: "",cancelled: false)
    }
    @MainActor private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw WorkflowFailure.invalid("Synthetic conversation condition timed out")
    }
    private func waitForRequests(_ state: ConversationFixtureState,count: Int) async throws {
        for _ in 0..<500 { if await state.requests.count >= count { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw WorkflowFailure.invalid("Synthetic transport did not reach the held admission")
    }
    @Test func reducerRequiresStableIdentityFinalResultAndNeverDuplicatesSnapshots() throws {
        let session = UUID(); var reply = LiveConversationReply(sessionID: session)
        try reply.receive(line(["type":"system","subtype":"init","session_id":session.uuidString]))
        try reply.receive(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"🥖 "}}}"#)
        try reply.receive(#"{"type":"assistant","message":{"content":[{"type":"text","text":"🥖 Keep the bowl"}]}}"#)
        try reply.receive(#"{"type":"result","subtype":"success","is_error":false,"result":"🥖 Keep the bowl"}"#)
        #expect(reply.finished && !reply.failed && reply.text == "🥖 Keep the bowl")
        #expect(throws: (any Error).self) { try reply.receive(#"{"type":"system","subtype":"init"}"#) }
        var noIdentity = LiveConversationReply(sessionID: session)
        #expect(throws: (any Error).self) { try noIdentity.receive(#"{"type":"result","subtype":"success","is_error":false}"#) }
        var tools = LiveConversationReply(sessionID: session)
        #expect(throws: (any Error).self) { try tools.receive(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","id":"never-run"}]}}"#) }
    }
    @Test func aFailedResultRetainsReceivedWordsInsteadOfReplacingThemWithClientInstructions() throws {
        let session = UUID(); var reply = LiveConversationReply(sessionID: session)
        try reply.receive(line(["type":"system","subtype":"init","session_id":session.uuidString]))
        try reply.receive(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Received assistant words"}}}"#)
        try reply.receive(#"{"type":"result","subtype":"error","is_error":true,"result":"Synthetic raw client diagnostic: run a command elsewhere"}"#)
        #expect(reply.finished && reply.failed && reply.text == "Received assistant words")
        #expect(reply.events.last == .result(text: "Synthetic raw client diagnostic: run a command elsewhere",failed: true,subtype: "error"))
    }
    @Test func exactExplicitTextAuthorizationAndClientCommandGrantNoProjectAccess() throws {
        let exe = URL(fileURLWithPath: "/usr/bin/true"), contract = ClaudeClientContract(executable: exe,executableSHA256: try ClaudeClientContract.digest(exe),helpSHA256: String(repeating: "a",count: 64))
        let project = UUID(), transport = ClaudeCLITransport(contract: contract)
        var request = ClaudeTurnRequest(sessionID: UUID(),resume: false,prompt: "--an ordinary literal user message 🥖",project: URL(fileURLWithPath: "/private-footage-project"),engine: URL(fileURLWithPath: "/private-engine"))
        request.projectID = project; request.textOnlyWorkspace = URL(fileURLWithPath: "/tmp/synthetic-text-client")
        #expect(throws: (any Error).self) { try transport.command(request) }
        request.textAuthorization = .init(projectID: project,text: request.prompt)
        let command = try transport.command(request)
        #expect(command.arguments.last == request.prompt && command.arguments[command.arguments.count-2] == "--")
        #expect(command.arguments.contains("--safe-mode") && command.arguments.contains("--restricted"))
        #expect(!command.arguments.contains("--add-dir") && !command.arguments.contains(request.project.path) && !command.arguments.contains(request.engine.path))
        #expect(command.arguments[try #require(command.arguments.firstIndex(of: "--tools"))+1].isEmpty)
        request.prompt += " changed"
        #expect(throws: (any Error).self) { try transport.command(request) }
        #expect(!ClaudeTextAuthorization(projectID: project,text: "x",created: Date().addingTimeInterval(-301)).matches(project: project,text: "x"))
    }
    @Test func localHelpContractIsVerifiedWithoutRunningAConversation() async throws {
        let runner = ConversationCommandFixture(), exe = URL(fileURLWithPath: "/usr/bin/true")
        let contract = try await ClaudeClientContract.inspect(executable: exe,runner: runner)
        #expect(contract.executableSHA256 == (try ClaudeClientContract.digest(exe)))
        #expect(await runner.commands.map(\.arguments) == [["--help"]])
        await #expect(throws: (any Error).self) { _ = try await ClaudeClientContract.inspect(executable: exe,runner: ConversationCommandFixture(help: "incompatible")) }
    }
    @Test func existingAccountFlowUsesSubscriptionLoginAndNeverAcceptsAnAPIKeyAsReady() async throws {
        let exe = URL(fileURLWithPath: "/usr/bin/true")
        let contract = ClaudeClientContract(executable: exe,executableSHA256: try ClaudeClientContract.digest(exe),helpSHA256: String(repeating: "a",count: 64))
        let runner = ConversationAccountFixture(statuses: [accountResult("none",exit: 1),accountResult("api_key"),accountResult("claude.ai")])
        let service = ClaudeAccountService(contract: contract,runner: runner)
        #expect(try await service.status() == .signedOut)
        #expect(try await service.status() == .differentAccountMethod)
        try await service.signIn()
        #expect(await runner.commands.map(\.arguments) == [["auth","status","--json"],["auth","status","--json"],["auth","login","--claudeai"],["auth","status","--json"]])
        let malformed = ConversationAccountFixture(statuses: [.init(exitCode: 0,output: "{\"authMethod\":\"claude.ai\",\"authMethod\":\"api_key\"}",error: "",cancelled: false)])
        await #expect(throws: (any Error).self) { _ = try await ClaudeAccountService(contract: contract,runner: malformed).status() }
    }
    @MainActor @Test func signedOutConnectionOffersAnInAppSignInFlowWithoutStartingATurn() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = ConversationAccountFixture(statuses: [accountResult("none",exit: 1),accountResult("claude.ai")])
        let controller = LiveConversationController(project: project,setupRunnerFactory: { runner },clientLocator: { URL(fileURLWithPath: "/usr/bin/true") })
        await controller.load(); await controller.connect()
        #expect(controller.needsSignIn && !controller.connected)
        await controller.signIn()
        #expect(controller.connected && !controller.needsSignIn && controller.document?.turns.isEmpty == true)
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func aLateCancelledSetupCannotReconnectOrCancelTheNextConnection() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ConversationAccountFixture(statuses: [],holdingHelp: true)
        let second = ConversationAccountFixture(statuses: [accountResult("claude.ai")])
        let runners = Mutex<[any CommandRunning]>([first,second])
        let controller = LiveConversationController(project: project,setupRunnerFactory: { runners.withLock { $0.removeFirst() } },clientLocator: { URL(fileURLWithPath: "/usr/bin/true") })
        let old = Task { await controller.connect() }
        for _ in 0..<500 { if await first.helpStarted { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await first.helpStarted)
        await controller.disconnect(); await controller.connect()
        #expect(controller.connected)
        await first.releaseHelp(); await old.value
        #expect(controller.connected && controller.error == nil && !controller.connecting)
        let firstCount = await first.cancellations, secondCount = await second.cancellations
        #expect(firstCount == 1 && secondCount == 0)
        #expect(await controller.flushForExit())
    }
    @Test func draftSubmissionAcknowledgementIsIdempotentAndNeverResurrectsRetiredWords() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = LiveConversationRepository(project: project)
        let draft = LiveConversationDocument.Draft(id: UUID(),revision: 2,text: "Keep the 🥖",updated: Date())
        _ = try await repository.saveDraft(draft)
        _ = try await repository.enqueue(draft.text,id: draft.submissionID,created: draft.updated)
        _ = try await repository.enqueue(draft.text,id: draft.submissionID,created: draft.updated)
        _ = try await repository.acknowledgeDraft(draft); _ = try await repository.saveDraft(draft)
        let saved = try await repository.load(); #expect(saved.messages.count == 1 && saved.draft == nil)
        var newer = draft; newer.revision += 1; newer.text += " and the hands"
        _ = try await repository.saveDraft(newer); _ = try await repository.acknowledgeDraft(draft)
        #expect(try await repository.load().draft?.text == newer.text && newer.submissionID != draft.submissionID)
    }
    @Test func aHigherLocalRevisionCannotReplaceAnotherWritersUnsentDraft() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = LiveConversationRepository(project: project), second = LiveConversationRepository(project: project)
        let base = LiveConversationDocument.Draft(id: UUID(),revision: 1,text: "Shared saved base",updated: Date())
        _ = try await first.saveDraft(base)
        var winner = base; winner.revision = 2; winner.text = "Writer A's unsent words"
        _ = try await first.saveDraft(winner,expected: base)
        var stale = base; stale.revision = 3; stale.text = "Writer B's different unsent words"
        await #expect(throws: (any Error).self) { _ = try await second.saveDraft(stale,expected: base) }
        await #expect(throws: (any Error).self) { _ = try await second.submitDraft(stale,expected: base) }
        let saved = try await first.load()
        #expect(saved.draft == winner && saved.messages.isEmpty)
        _ = try await first.submitDraft(winner,expected: winner)
        _ = try await first.submitDraft(winner,expected: winner)
        #expect(try await first.load().messages.count == 1)
    }
    @Test func dateEncodingPrecisionCannotMakeTheWritersOwnSavedBaseConflict() async throws {
        struct Stamp: Codable { let date: Date }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var witness: Date?
        for i in 1...100 {
            let date = Date(timeIntervalSinceReferenceDate: 800_000_000+Double(i)/10_000_000)
            if try decoder.decode(Stamp.self,from: encoder.encode(Stamp(date: date))).date != date { witness = date; break }
        }
        let date = try #require(witness)
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project)
        let base = LiveConversationDocument.Draft(id: UUID(),revision: 1,text: "Original unsent words",updated: date)
        _ = try await repo.saveDraft(base)
        let decoded = try #require(try await repo.load().draft)
        #expect(decoded.updated != base.updated && decoded == base)
        var next = base; next.revision += 1; next.text = "Newer acknowledged words"
        _ = try await repo.saveDraft(next,expected: base)
        #expect(try await repo.load().draft?.text == next.text)
    }
    @MainActor @Test func twoWriterConflictKeepsBothDraftsAndAllowsNormalQuitAndExplicitContinuation() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project)
        let base = LiveConversationDocument.Draft(id: UUID(),revision: 1,text: "Shared base",updated: Date())
        _ = try await repo.saveDraft(base)
        let a = LiveConversationController(project: project), b = LiveConversationController(project: project)
        await a.load(); await b.load()
        a.edit("Writer A's saved unsent words"); await a.retryStorage()
        b.edit("Writer B's earlier words"); b.edit("Writer B's newer unsent words 🥖"); await b.retryStorage()
        let refusedQuit = await b.flushForExit()
        #expect(b.draftConflict && b.draftDirty && !refusedQuit)
        await b.keepBothDrafts()
        #expect(!b.draftDirty && !b.draftConflict && b.draft.text == "Writer A's saved unsent words")
        let recovered = try #require(b.document?.recoveredDrafts?.first)
        #expect(recovered.draft.text == "Writer B's newer unsent words 🥖")
        #expect(await b.flushForExit())
        await b.continueRecoveredDraft(recovered.id)
        let reopened = try await repo.load()
        #expect(reopened.messages.isEmpty && reopened.draft?.text == recovered.draft.text)
        #expect(reopened.draft?.id != recovered.draft.id)
        #expect(reopened.recoveredDrafts?.contains(where: { $0.draft.text == "Writer A's saved unsent words" }) == true)
        let quitA = await a.flushForExit(), quitB = await b.flushForExit()
        #expect(quitA && quitB)
    }
    @MainActor @Test func aLateKeepBothAcknowledgementCannotReplaceNewerLocalWords() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LiveConversationController(project: project), repo = LiveConversationRepository(project: project)
        await controller.load(); controller.edit("Earlier local branch")
        _ = try await repo.saveDraft(.init(id: UUID(),revision: 1,text: "Other writer's saved draft",updated: Date()))
        await controller.retryStorage(); #expect(controller.draftConflict)
        var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {}; lease = nil }
        let keeping = Task { await controller.keepBothDrafts() }
        try await wait { controller.resolvingDraft && controller.savingDraft }
        controller.edit("New local words typed while recovery waits")
        lease = nil; await keeping.value
        #expect(controller.draftDirty && controller.draftConflict && controller.draft.text == "New local words typed while recovery waits")
        #expect(controller.document?.recoveredDrafts?.contains(where: { $0.draft.text == "Earlier local branch" }) == true)
        await controller.keepBothDrafts()
        #expect(controller.document?.recoveredDrafts?.contains(where: { $0.draft.text == "New local words typed while recovery waits" }) == true)
        #expect(controller.draft.text == "Other writer's saved draft" && !controller.draftDirty)
        #expect(await controller.flushForExit())
    }
    @Test func recoveredSnapshotsAreIdempotentAndKeepCanonicalEquivalentUnicodeBranchesSeparate() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project)
        let first = LiveConversationDocument.Draft(id: UUID(),revision: 2,text: "caf\u{00e9}",updated: Date())
        var second = first; second.text = "cafe\u{0301}"
        _ = try await repo.preserveLocalDraft(first); _ = try await repo.preserveLocalDraft(first)
        let saved = try await repo.preserveLocalDraft(second)
        #expect(saved.recoveredDrafts?.count == 2 && saved.draft == nil && saved.messages.isEmpty)
        #expect(saved.recoveredDrafts?[0].draft.text.utf8.elementsEqual(first.text.utf8) == true)
        #expect(saved.recoveredDrafts?[1].draft.text.utf8.elementsEqual(second.text.utf8) == true)
    }
    @MainActor @Test func aRestoredOlderDraftStartsItsIdleClockAtTheActualSubmission() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = LiveConversationDocument.Draft(id: UUID(),revision: 2,text: "A restored draft",updated: Date().addingTimeInterval(-1000))
        _ = try await LiveConversationRepository(project: project).saveDraft(old)
        let state = ConversationFixtureState(), controller = LiveConversationController(project: project,syntheticFactory: { ConversationFixtureTransport(state) })
        await controller.load(); let beforeSend = Date(); #expect(await controller.submit())
        try await wait { controller.document?.turns.last?.state == .succeeded }
        let sent = try #require(controller.document?.messages.first)
        #expect(sent.created >= beforeSend && controller.document?.packets.isEmpty == true)
        #expect(try await controller.repository.sealIdlePacket(now: beforeSend.addingTimeInterval(119)).packets.isEmpty)
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func serializedDraftWritesKeepNewerWordsAndTheirExactUnicodeBytes() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LiveConversationController(project: project)
        await controller.load(); controller.edit("caf\u{00e9}")
        await controller.retryStorage()
        controller.edit("cafe\u{0301}")
        await controller.retryStorage()
        let saved = try await controller.repository.load()
        #expect(saved.draft?.text.utf8.elementsEqual("cafe\u{0301}".utf8) == true)
        #expect(await controller.flushForExit())
    }
    @Test func progressAndTerminalRetriesKeepQueuedMessagesAndExactReopenedReply() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = LiveConversationRepository(project: project), first = UUID(), second = UUID(), turn = UUID()
        _ = try await repository.enqueue("First",id: first,created: Date())
        let claimed = try await repository.beginTurn(id: turn)
        _ = try await repository.beginTurn(id: turn)
        _ = try await LiveConversationRepository(project: project).enqueue("Newer feedback",id: second,created: Date())
        let reply = try complete(claimed.sessionID)
        _ = try await repository.updateTurn(turn,reply: reply,state: .succeeded)
        _ = try await repository.updateTurn(turn,reply: reply,state: .succeeded)
        let reopened = try await LiveConversationRepository(project: project).load()
        #expect(reopened.queued.map(\.id) == [second] && reopened.turns.first?.text == "Synthetic answer")
        #expect(reopened.sessionID == claimed.sessionID)
        await #expect(throws: (any Error).self) { _ = try await repository.updateTurn(turn,reply: .init(sessionID: UUID()),state: .failed) }
    }
    @MainActor @Test func newerWordsWaitBehindAnAcknowledgedBaseInsteadOfConflictingWithTheirOwnEarlierWrite() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LiveConversationController(project: project)
        await controller.load()
        var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {}; lease = nil }
        controller.edit("Earlier unsent words")
        let first = Task { await controller.retryStorage() }
        try await wait { controller.savingDraft }
        controller.edit("Newer unsent words 🥖")
        let second = Task { await controller.retryStorage() }
        lease = nil; await first.value; await second.value
        #expect(!controller.draftDirty && !controller.savingDraft)
        #expect(try await controller.repository.load().draft?.text == "Newer unsent words 🥖")
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func moreFeedbackCanBeQueuedWhileConnectionSetupIsStillRunning() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = ConversationAccountFixture(statuses: [],holdingHelp: true)
        let controller = LiveConversationController(project: project,setupRunnerFactory: { runner },clientLocator: { URL(fileURLWithPath: "/usr/bin/true") })
        await controller.load(); controller.edit("First feedback"); #expect(await controller.submit())
        for _ in 0..<500 { if await runner.helpStarted { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(await runner.helpStarted)
        controller.edit("Second feedback during setup")
        #expect(controller.canSend && controller.connecting)
        #expect(await controller.submit())
        #expect(controller.document?.queued.count == 2 && !controller.submitting)
        await controller.disconnect(); await runner.releaseHelp()
        #expect(await controller.flushForExit())
        #expect(await runner.commands.map(\.arguments) == [["--help"]])
    }
    @MainActor @Test func manualRetryCancelsTheDebounceInsteadOfStartingARedundantBlockedWrite() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = LiveConversationController(project: project)
        await controller.load(); controller.edit("Saved once without a delayed duplicate")
        await controller.retryStorage()
        try #require(!controller.draftDirty && !controller.savingDraft)
        var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {}; lease = nil }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!controller.savingDraft && !controller.draftDirty)
        lease = nil
        #expect(await controller.flushForExit())
    }
    @Test func retryingAFailedReplyPreservesEveryAttemptAndTheOriginalSubmittedMessage() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project), first = UUID(), second = UUID(), message = UUID()
        _ = try await repo.enqueue("Keep the hands",id: message,created: Date())
        let claimed = try await repo.beginTurn(id: first)
        _ = try await repo.updateTurn(first,reply: complete(claimed.sessionID,text: "A received but failed reply"),state: .failed,failure: "Synthetic process failure")
        let retry = try await repo.retryTurn(first,id: second)
        #expect(retry.messages.count == 1 && retry.turns.count == 2 && retry.turns.last?.retryOf == first)
        #expect(retry.turns.first?.text == "A received but failed reply" && retry.turns.last?.messageIDs == [message])
        _ = try await repo.updateTurn(second,reply: complete(claimed.sessionID,text: "A successful retry"),state: .succeeded)
        await #expect(throws: (any Error).self) { _ = try await repo.retryTurn(first,id: UUID()) }
        #expect(try await repo.load().turns.map(\.text) == ["A received but failed reply","A successful retry"])
    }
    @Test func idlePacketsRequireFinishedRepliesAndNeverConsumeNewFeedbackOrDrafts() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project), date = Date().addingTimeInterval(-121), id = UUID(), turn = UUID()
        _ = try await repo.enqueue("First feedback",id: id,created: date)
        #expect(try await repo.sealIdlePacket().packets.isEmpty)
        let claimed = try await repo.beginTurn(id: turn)
        #expect(try await repo.sealIdlePacket().packets.isEmpty)
        _ = try await repo.updateTurn(turn,reply: complete(claimed.sessionID),state: .succeeded)
        let sealed = try await repo.sealIdlePacket(); #expect(sealed.packets.count == 1 && sealed.packets[0].reviewOnly)
        #expect(try await repo.sealIdlePacket().packets.count == 1)
        _ = try await repo.enqueue("Keep steering",id: UUID(),created: Date())
        #expect(try await repo.sealIdlePacket(now: Date().addingTimeInterval(121)).packets.count == 1)
    }
    @MainActor @Test func newFeedbackInterruptsOneReplyAndContinuesInTheSameSession() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ConversationFixtureState(holdFirst: true)
        let controller = LiveConversationController(project: project,syntheticFactory: { ConversationFixtureTransport(state) })
        await controller.load(); controller.edit("First explicitly sent message"); #expect(await controller.submit())
        try await wait { controller.document?.turns.first?.text == "Partial 🥖" }
        controller.edit("Keep steering while the reply runs"); #expect(await controller.submit())
        try await wait { controller.document?.turns.count == 2 && controller.document?.turns.last?.state == .succeeded }
        let requests = await state.requests
        #expect(requests.count == 2 && requests[0].sessionID == requests[1].sessionID)
        #expect(requests[0].resume == false && requests[1].resume == true)
        #expect(requests[1].prompt == "Keep steering while the reply runs")
        #expect(controller.document?.turns.first?.state == .cancelled && controller.document?.turns.first?.text == "Partial 🥖")
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func resultBeforeProcessFailureNeverClaimsASuccessfulReply() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ConversationFixtureState(failAfterResult: true)
        let controller = LiveConversationController(project: project,syntheticFactory: { ConversationFixtureTransport(state) })
        await controller.load(); controller.edit("A synthetic request"); #expect(await controller.submit())
        try await wait { controller.document?.turns.last?.state == .failed }
        #expect(!controller.connected && controller.document?.turns.last?.text == "A concrete synthetic suggestion.")
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func receivedWordsSurviveAStorageFailureUntilRetryAcknowledgesThem() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ConversationFixtureState(holdFirst: true), transport = ConversationFixtureTransport(state)
        let controller = LiveConversationController(project: project,syntheticFactory: { transport })
        await controller.load(); controller.edit("Keep this synthetic request"); #expect(await controller.submit())
        try await wait { controller.document?.turns.last?.text == "Partial 🥖" }
        let file = project.folder.appendingPathComponent(".clauto/live-conversation.json"), saved = project.folder.appendingPathComponent(".clauto/synthetic-saved-conversation.json")
        try FileManager.default.moveItem(at: file,to: saved)
        try FileManager.default.createDirectory(at: file,withIntermediateDirectories: false)
        await transport.release()
        try await wait { controller.storagePending && !controller.streaming }
        #expect(!(await controller.flushForExit()))
        try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: saved,to: file)
        await controller.retryStorage()
        let reopened = try await LiveConversationRepository(project: project).load()
        #expect(!controller.storagePending && reopened.turns.last?.text == "A concrete synthetic suggestion.")
        #expect(reopened.turns.last?.state == .failed && reopened.messages.count == 1)
        #expect(await controller.flushForExit())
    }
    @Test func recoveryRetainsPartialTextAndRefusesLatePublicationFromAnExpiredTurn() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LiveConversationRepository(project: project), turn = UUID(), now = Date()
        _ = try await repo.enqueue("A restartable synthetic request",id: UUID(),created: now)
        let claimed = try await repo.beginTurn(id: turn,now: now)
        var partial = LiveConversationReply(sessionID: claimed.sessionID)
        try partial.receive(line(["type":"system","subtype":"init","session_id":claimed.sessionID.uuidString]))
        try partial.receive(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Received before restart"}}}"#)
        _ = try await repo.updateTurn(turn,reply: partial)
        let recovered = try await LiveConversationRepository(project: project).recover(now: now.addingTimeInterval(241))
        #expect(recovered.turns.last?.state == .interrupted && recovered.turns.last?.text == "Received before restart")
        await #expect(throws: (any Error).self) { _ = try await repo.updateTurn(turn,reply: complete(claimed.sessionID),state: .succeeded) }
    }
    @MainActor @Test func idleFeedbackIsPacketedAutomaticallyAndLaterSteeringStartsAnotherPacket() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ConversationFixtureState()
        let controller = LiveConversationController(project: project,syntheticFactory: { ConversationFixtureTransport(state) },idleInterval: 0.05)
        await controller.load(); controller.edit("First steering"); #expect(await controller.submit())
        try await wait { controller.document?.packets.count == 1 }
        controller.edit("Later steering"); #expect(await controller.submit())
        try await wait { controller.document?.packets.count == 2 }
        #expect(controller.document?.messages.count == 2 && controller.document?.turns.count == 2)
        #expect(controller.document?.packets.map { $0.messageIDs.count } == [1,2])
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func disconnectWhileSubmitWaitsForTheLeaseLeavesItsMessageQueuedWithoutReconnecting() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ConversationFixtureState()
        let controller = LiveConversationController(project: project,syntheticFactory: { ConversationFixtureTransport(state) })
        await controller.load(); await controller.connect()
        var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {}; lease = nil }
        controller.edit("A submitted message waiting for storage")
        let submission = Task { await controller.submit() }
        try await wait { controller.submitting }
        await controller.disconnect(); lease = nil
        #expect(await submission.value)
        #expect(!controller.connected && controller.document?.queued.count == 1)
        #expect(await state.requests.isEmpty)
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func disconnectWhileWorkerWaitsForTheLeasePreventsAnyTransportAdmission() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ConversationFixtureState(), repo = LiveConversationRepository(project: project)
        _ = try await repo.enqueue("A saved queued message",id: UUID(),created: Date())
        let controller = LiveConversationController(project: project,syntheticFactory: { ConversationFixtureTransport(state) })
        await controller.load()
        var lease: ProjectMutationLease? = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {}; lease = nil }
        await controller.connect()
        try await wait { controller.preparingReply }
        let stopping = Task { await controller.disconnect() }
        try await wait { !controller.connected }
        lease = nil; await stopping.value
        #expect(await state.requests.isEmpty)
        #expect(controller.document?.queued.count == 1 && controller.document?.turns.isEmpty == true)
        #expect(await controller.flushForExit())
    }
    @MainActor @Test func retrySavingAnUnsentDraftCannotRetireTheHealthyRunningReply() async throws {
        let (root,project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = ConversationFixtureState(holdBeforeFirst: true), transport = ConversationFixtureTransport(state)
        let controller = LiveConversationController(project: project,syntheticFactory: { transport })
        await controller.load(); controller.edit("First submitted feedback"); #expect(await controller.submit())
        try await waitForRequests(state,count: 1)
        controller.edit("Unsent newer words")
        await controller.retryStorage()
        #expect(controller.document?.turns.last?.state == .running && !controller.storagePending)
        await transport.release()
        try await wait { controller.document?.turns.last?.state == .succeeded }
        #expect(controller.document?.turns.last?.text == "A concrete synthetic suggestion.")
        #expect(controller.draft.text == "Unsent newer words")
        #expect(await controller.flushForExit())
    }
    @Test func transportCancellationDuringAccountCheckNeverStartsTheModelCommand() async throws {
        let exe = URL(fileURLWithPath: "/usr/bin/true")
        let contract = ClaudeClientContract(executable: exe,executableSHA256: try ClaudeClientContract.digest(exe),helpSHA256: String(repeating: "a",count: 64))
        let runner = ConversationAccountFixture(statuses: [accountResult("claude.ai")],holdingStatus: true)
        let transport = ClaudeCLITransport(contract: contract,runner: runner), project = UUID()
        var request = ClaudeTurnRequest(sessionID: UUID(),resume: false,prompt: "A synthetic request",project: URL(fileURLWithPath: "/tmp/no-project-access"),engine: URL(fileURLWithPath: "/tmp/no-engine-access"))
        request.projectID = project; request.textOnlyWorkspace = URL(fileURLWithPath: "/tmp/synthetic-text-client")
        request.textAuthorization = .init(projectID: project,text: request.prompt)
        let outgoing = request
        let running = Task { try await transport.turn(outgoing,onLine: { _ in }) }
        for _ in 0..<500 { if await runner.statusStarted { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(await runner.statusStarted)
        await transport.cancel(); await runner.releaseStatus()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await runner.commands.map(\.arguments) == [["auth","status","--json"]])
        await #expect(throws: CancellationError.self) { try await transport.turn(outgoing,onLine: { _ in }) }
        #expect(await runner.commands.count == 1)
    }
}
