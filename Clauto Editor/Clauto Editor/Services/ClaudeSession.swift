import Foundation

// Provisional adapter: fixtures follow Anthropic's documented headless events.
// No live transport exists in this build. A real, authorized CLI capture must
// verify these shapes and permission boundaries before enabling external turns.
enum ClaudeEvent: Codable, Equatable, Sendable {
    case session(UUID)
    case textDelta(String)
    case assistantText(String)
    case tool(name: String, id: String)
    case retry(attempt: Int)
    case result(text: String, failed: Bool, subtype: String)
    case unknown(String)
}

enum ClaudeFailure: LocalizedError {
    case disabled, busy, invalidStream, sessionMismatch, missingSession, incomplete
    var errorDescription: String? {
        switch self {
        case .disabled: "Live Claude is disabled. Your saved request remains available."
        case .busy: "A conversation turn is already running. Stop it or wait for it to finish."
        case .invalidStream: "Claude returned unreadable events. The previous cut is unchanged."
        case .sessionMismatch: "The conversation identity changed. The previous cut is unchanged."
        case .missingSession: "Claude did not identify this conversation. The previous cut is unchanged."
        case .incomplete: "Claude stopped before confirming a result. Your request remains saved."
        }
    }
}

struct ClaudeStreamParser: Sendable {
    func parse(_ line: String) throws -> [ClaudeEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { throw ClaudeFailure.invalidStream }
        var events: [ClaudeEvent] = []
        if let value = object["session_id"] {
            guard let text = value as? String, let id = UUID(uuidString: text) else { throw ClaudeFailure.invalidStream }
            events.append(.session(id))
        }
        switch type {
        case "system":
            if object["subtype"] as? String == "api_retry" {
                guard let attempt = object["attempt"] as? Int, attempt > 0 else { throw ClaudeFailure.invalidStream }
                events.append(.retry(attempt: attempt))
            } else if object["subtype"] as? String != "init" { events.append(.unknown(type)) }
        case "stream_event":
            guard let event = object["event"] as? [String: Any], let eventType = event["type"] as? String else { throw ClaudeFailure.invalidStream }
            if eventType == "content_block_delta", let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                guard let value = delta["text"] as? String else { throw ClaudeFailure.invalidStream }
                events.append(.textDelta(value))
            } else { events.append(.unknown(eventType)) }
        case "assistant":
            guard let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { throw ClaudeFailure.invalidStream }
            var text: [String] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    guard let value = block["text"] as? String else { throw ClaudeFailure.invalidStream }
                    text.append(value)
                case "tool_use":
                    guard let name = block["name"] as? String, let id = block["id"] as? String, !name.isEmpty, !id.isEmpty else { throw ClaudeFailure.invalidStream }
                    // Tool input is data. This adapter never executes it.
                    events.append(.tool(name: name, id: id))
                default: events.append(.unknown("content_block"))
                }
            }
            if !text.isEmpty { events.append(.assistantText(text.joined(separator: "\n"))) }
        case "result":
            guard let subtype = object["subtype"] as? String, let failed = object["is_error"] as? Bool else { throw ClaudeFailure.invalidStream }
            if let value = object["result"], !(value is String) { throw ClaudeFailure.invalidStream }
            if let value = object["errors"], !(value is [String]) { throw ClaudeFailure.invalidStream }
            var denied = false
            if let value = object["permission_denials"] {
                guard let denials = value as? [Any] else { throw ClaudeFailure.invalidStream }
                denied = !denials.isEmpty
            }
            let text = object["result"] as? String ?? (object["errors"] as? [String])?.joined(separator: "\n") ?? ""
            events.append(.result(text: text, failed: failed || denied || subtype != "success", subtype: subtype))
        default: events.append(.unknown(type))
        }
        return events
    }
}

struct ClaudeTurnRequest: Sendable {
    var sessionID: UUID
    var resume: Bool
    var prompt: String
    var project: URL
    var engine: URL
}

protocol ClaudeTurnTransport: Sendable {
    var isSyntheticFixture: Bool { get }
    func turn(_ request: ClaudeTurnRequest, onLine: @escaping @Sendable (String) async throws -> Void) async throws
    func cancel() async
}

struct DisabledClaudeTransport: ClaudeTurnTransport {
    let isSyntheticFixture = false
    func turn(_ request: ClaudeTurnRequest, onLine: @escaping @Sendable (String) async throws -> Void) async throws { throw ClaudeFailure.disabled }
    func cancel() async { }
}

struct ClaudeConversation: Codable, Sendable {
    enum State: String, Codable, Sendable { case running, succeeded, failed, cancelled, interrupted }
    struct Turn: Codable, Identifiable, Sendable {
        var id = UUID()
        var prompt: String
        var created = Date()
        var state: State = .running
        var text = ""
        var events: [ClaudeEvent] = []
        var failure: String? = nil
    }
    var schemaVersion = 1
    var projectID: UUID
    var sessionID: UUID
    var fixtureOnly = true
    var turns: [Turn] = []
}

actor ClaudeSession {
    private let transport: any ClaudeTurnTransport
    private var activeTurn: UUID?
    private var cancelled = false
    init(transport: any ClaudeTurnTransport = DisabledClaudeTransport()) { self.transport = transport }

    func load(project: Project) throws -> ClaudeConversation? {
        let file = try location(project)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var conversation = try decoder.decode(ClaudeConversation.self, from: Data(contentsOf: file))
        guard conversation.schemaVersion == 1, conversation.projectID == project.id, conversation.fixtureOnly else { throw ProjectFailure.invalidProject }
        if activeTurn == nil, let index = conversation.turns.indices.last, conversation.turns[index].state == .running {
            conversation.turns[index].state = .interrupted
            conversation.turns[index].failure = "The previous session ended. The saved request can be retried."
            try save(conversation, project: project)
        }
        return conversation
    }

    func send(_ prompt: String, project: Project, engine: URL,
              onEvent: @escaping @Sendable (ClaudeEvent) async -> Void = { _ in }) async throws -> ClaudeConversation {
        // A Boolean UI preference can never enable the network: there is no live
        // transport implementation, and non-fixture transports are refused here.
        guard transport.isSyntheticFixture else { throw ClaudeFailure.disabled }
        guard activeTurn == nil else { throw ClaudeFailure.busy }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClaudeFailure.incomplete }
        var conversation = try load(project: project) ?? ClaudeConversation(projectID: project.id, sessionID: UUID())
        let resume = !conversation.turns.isEmpty
        conversation.turns.append(.init(prompt: prompt))
        let index = conversation.turns.count - 1
        try save(conversation, project: project)
        let turnID = conversation.turns[index].id
        activeTurn = turnID; cancelled = false
        defer { activeTurn = nil }
        let recorder = ClaudeTurnRecorder(sessionID: conversation.sessionID)
        let initialConversation = conversation
        let request = ClaudeTurnRequest(sessionID: conversation.sessionID, resume: resume, prompt: prompt, project: project.folder, engine: engine)
        do {
            try await withTaskCancellationHandler {
                try await transport.turn(request) { line in
                    let events = try ClaudeStreamParser().parse(line)
                    for event in events {
                        try await recorder.append(event)
                    }
                    try await self.persistProgress(await recorder.value, conversation: initialConversation,
                                                   index: index, turnID: turnID, project: project)
                    for event in events { await onEvent(event) }
                }
            } onCancel: { Task { await self.cancel(turnID: turnID) } }
            let result = await recorder.value
            conversation.turns[index].events = result.events
            conversation.turns[index].text = result.text
            if cancelled || Task.isCancelled { conversation.turns[index].state = .cancelled }
            else if !result.finished { throw ClaudeFailure.incomplete }
            else { conversation.turns[index].state = result.failed ? .failed : .succeeded }
            conversation.turns[index].failure = result.failed ? result.text : nil
        } catch {
            let result = await recorder.value
            conversation.turns[index].events = result.events; conversation.turns[index].text = result.text
            conversation.turns[index].state = cancelled || Task.isCancelled || error is CancellationError ? .cancelled : .failed
            conversation.turns[index].failure = error.localizedDescription
        }
        try save(conversation, project: project)
        return conversation
    }

    func cancel() async {
        guard let turnID = activeTurn else { return }
        await cancel(turnID: turnID)
    }

    private func cancel(turnID: UUID) async {
        // A cancellation handler may arrive after its turn completed. It must
        // never cancel a newer turn that reused this session actor.
        guard activeTurn == turnID else { return }
        cancelled = true
        await transport.cancel()
    }

    private func persistProgress(_ value: ClaudeTurnRecorder.Value, conversation: ClaudeConversation,
                                 index: Int, turnID: UUID, project: Project) throws {
        guard activeTurn == turnID else { throw ClaudeFailure.incomplete }
        var snapshot = conversation
        snapshot.turns[index].events = value.events
        snapshot.turns[index].text = value.text
        // Keep it running until the transport exits cleanly. After a crash,
        // load() recovers this durable partial as an interrupted turn.
        try save(snapshot, project: project)
    }

    private func location(_ project: Project) throws -> URL {
        try ProjectRepository.validateDrive(project.folder)
        let root = project.folder.resolvingSymlinksInPath().standardizedFileURL
        let notes = project.folder.appendingPathComponent("notes").resolvingSymlinksInPath().standardizedFileURL
        let file = notes.appendingPathComponent("claude-fixture-conversation.json")
        guard notes == root.appendingPathComponent("notes"), file.resolvingSymlinksInPath().standardizedFileURL == file else { throw ProjectFailure.invalidProject }
        return file
    }

    private func save(_ conversation: ClaudeConversation, project: Project) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(conversation).write(to: location(project), options: .atomic)
    }
}

private actor ClaudeTurnRecorder {
    let sessionID: UUID
    var value = Value()
    private var identified = false
    struct Value: Sendable { var events: [ClaudeEvent] = []; var text = ""; var finished = false; var failed = false }
    init(sessionID: UUID) { self.sessionID = sessionID }
    func append(_ event: ClaudeEvent) throws {
        guard !value.finished else { throw ClaudeFailure.invalidStream }
        if case .session(let id) = event {
            guard id == sessionID else { throw ClaudeFailure.sessionMismatch }
            identified = true
        }
        if case .result = event, !identified { throw ClaudeFailure.missingSession }
        value.events.append(event)
        switch event {
        case .textDelta(let text): value.text += text
        case .assistantText(let text): value.text = text // Full snapshots replace deltas; never duplicate them.
        case .result(let text, let failed, _):
            if !text.isEmpty { value.text = text }
            value.finished = true; value.failed = failed
        default: break
        }
    }
}
