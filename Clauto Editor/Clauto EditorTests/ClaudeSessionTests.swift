import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

private actor SyntheticClaudeTransport: ClaudeTurnTransport {
    enum Ending: Sendable { case success, denied, malformed, mismatch, incomplete }
    let isSyntheticFixture: Bool
    let ending: Ending
    let identity: Bool
    var requests: [ClaudeTurnRequest] = []
    init(_ ending: Ending = .success, fixture: Bool = true, identity: Bool = true) {
        self.ending = ending; isSyntheticFixture = fixture; self.identity = identity
    }
    func cancel() {}
    func turn(_ request: ClaudeTurnRequest, onLine: @escaping @Sendable (String) async throws -> Void) async throws {
        requests.append(request)
        let id = request.sessionID.uuidString
        if identity { try await onLine("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\(id)\"}") }
        try await onLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Synthetic "}}}"#)
        try await onLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}}"#)
        switch ending {
        case .success:
            try await onLine(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Synthetic answer"},{"type":"tool_use","name":"NeverExecute","id":"fixture-tool","input":{"command":"invalid"}}]}}"#)
            try await onLine(#"{"type":"result","subtype":"success","is_error":false,"result":"Synthetic answer"}"#)
        case .denied:
            try await onLine(#"{"type":"result","subtype":"success","is_error":false,"result":"Permission denied","permission_denials":[{"tool":"NeverExecute"}]}"#)
        case .malformed: try await onLine("not json")
        case .mismatch: try await onLine("{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"\(UUID())\"}")
        case .incomplete: break
        }
    }
}

private actor BlockingClaudeTransport: ClaudeTurnTransport {
    let isSyntheticFixture = true
    var started = false
    var cancellations = 0
    var waiter: CheckedContinuation<Void, Never>?
    func turn(_ request: ClaudeTurnRequest, onLine: @escaping @Sendable (String) async throws -> Void) async throws {
        try await onLine(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Saved partial"}}}"#)
        await withCheckedContinuation { waiter = $0; started = true }
        throw CancellationError()
    }
    func cancel() {
        cancellations += 1
        waiter?.resume(); waiter = nil
    }
}

struct ClaudeSessionTests {
    private func fixture() async throws -> (URL, URL, Project) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-conversation-\(UUID())")
        let engine = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("templates"), withIntermediateDirectories: true)
        let project = try await ProjectRepository().create(name: "Synthetic conversation", root: root.appendingPathComponent("projects"), engine: engine, engineVersion: "fixture")
        return (root, engine, project)
    }

    @Test func syntheticTurnsPersistResumeAndDoNotDuplicateText() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = SyntheticClaudeTransport(), session = ClaudeSession(transport: transport)
        let first = try await session.send("Synthetic prompt", project: project, engine: engine)
        #expect(first.turns[0].state == .succeeded)
        #expect(first.turns[0].text == "Synthetic answer")
        #expect(first.turns[0].events.contains(.tool(name: "NeverExecute", id: "fixture-tool")))
        let reopened = ClaudeSession(transport: transport)
        let second = try await reopened.send("Another synthetic prompt", project: project, engine: engine)
        #expect(second.sessionID == first.sessionID && second.turns.count == 2)
        let requests = await transport.requests
        #expect(requests.map(\.resume) == [false, true])
        #expect(requests.allSatisfy { $0.sessionID == first.sessionID })
        #expect(try await reopened.load(project: project)?.turns[0].prompt == "Synthetic prompt")
    }

    @Test func deniedMalformedMismatchedAndPartialResultsRemainFailed() async throws {
        for ending in [SyntheticClaudeTransport.Ending.denied, .malformed, .mismatch, .incomplete] {
            let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let session = ClaudeSession(transport: SyntheticClaudeTransport(ending))
            let conversation = try await session.send("Synthetic failure fixture", project: project, engine: engine)
            #expect(conversation.turns[0].state == .failed)
            #expect(conversation.turns[0].failure != nil)
            #expect(!conversation.turns[0].text.isEmpty)
            #expect(try await session.load(project: project)?.turns[0].state == .failed)
            #expect(!FileManager.default.fileExists(atPath: project.folder.appendingPathComponent("cuts/current.json").path))
        }
    }

    @Test func defaultAndNonFixtureTransportsCannotStartTurns() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: ClaudeFailure.self) { try await ClaudeSession().send("Saved elsewhere", project: project, engine: engine) }
        let transport = SyntheticClaudeTransport(fixture: false)
        await #expect(throws: ClaudeFailure.self) { try await ClaudeSession(transport: transport).send("Synthetic refusal", project: project, engine: engine) }
        #expect(await transport.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: project.folder.appendingPathComponent("notes/claude-fixture-conversation.json").path))
    }

    @Test func interruptedTurnRecoversWithoutChangingSessionIdentity() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = ClaudeConversation(projectID: project.id, sessionID: UUID(), turns: [.init(prompt: "Interrupted synthetic prompt")])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original).write(to: project.folder.appendingPathComponent("notes/claude-fixture-conversation.json"))
        let transport = SyntheticClaudeTransport(), session = ClaudeSession(transport: transport)
        #expect(try await session.load(project: project)?.turns[0].state == .interrupted)
        let resumed = try await session.send("Retry synthetic turn", project: project, engine: engine)
        #expect(resumed.sessionID == original.sessionID)
        #expect(resumed.turns[0].state == .interrupted && resumed.turns[1].state == .succeeded)
        #expect(await transport.requests.first?.resume == true)
    }

    @Test func busyAndCallerCancellationPreservePartialRequest() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = BlockingClaudeTransport(), session = ClaudeSession(transport: transport)
        let task = Task { try await session.send("Synthetic cancellation", project: project, engine: engine) }
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transport.started)
        // Read disk while the first turn is still blocked. A restart must retain
        // received text, rather than depending on graceful cancellation to save it.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let running = try decoder.decode(ClaudeConversation.self, from: Data(contentsOf: project.folder.appendingPathComponent("notes/claude-fixture-conversation.json")))
        #expect(running.turns[0].state == .running && running.turns[0].text == "Saved partial")
        #expect(!running.turns[0].events.isEmpty)
        await #expect(throws: ClaudeFailure.self) { try await session.send("Busy", project: project, engine: engine) }
        task.cancel()
        let conversation = try await task.value
        #expect(conversation.turns[0].state == .cancelled)
        #expect(conversation.turns[0].text == "Saved partial")
        #expect(conversation.turns[0].prompt == "Synthetic cancellation")
        #expect(await transport.cancellations == 1)
        #expect(try await session.load(project: project)?.turns[0].state == .cancelled)
    }

    @Test func successWithoutObservedSessionIdentityIsRefused() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ClaudeSession(transport: SyntheticClaudeTransport(identity: false))
        let conversation = try await session.send("Unbound synthetic result", project: project, engine: engine)
        #expect(conversation.turns[0].state == .failed)
        #expect(conversation.turns[0].failure == ClaudeFailure.missingSession.errorDescription)
        #expect(try await session.load(project: project)?.turns[0].state == .failed)
    }

    @Test func escapedNotesRefusedWithoutWritingOutsideProject() async throws {
        let (root, engine, project) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default, notes = project.folder.appendingPathComponent("notes"), outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.removeItem(at: notes); try fm.createSymbolicLink(at: notes, withDestinationURL: outside)
        await #expect(throws: ProjectFailure.self) { try await ClaudeSession(transport: SyntheticClaudeTransport()).send("Synthetic containment", project: project, engine: engine) }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func parserRejectsInvalidIdentitiesAndPreservesRetryAndUnknownEvents() throws {
        let parser = ClaudeStreamParser()
        #expect(throws: ClaudeFailure.self) { try parser.parse(#"{"type":"system","subtype":"init","session_id":"invalid"}"#) }
        #expect(throws: ClaudeFailure.self) { try parser.parse(#"{"type":"system","subtype":"api_retry","attempt":0}"#) }
        #expect(try parser.parse(#"{"type":"system","subtype":"api_retry","attempt":2}"#) == [.retry(attempt: 2)])
        #expect(try parser.parse(#"{"type":"new_fixture_event"}"#) == [.unknown("new_fixture_event")])
        for field in [#""permission_denials":{}"#, #""permission_denials":"denied""#, #""result":{}"#, #""errors":[7]"#] {
            let malformed = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\(field)}"
            #expect(throws: ClaudeFailure.self) { try parser.parse(malformed) }
        }
    }
}
