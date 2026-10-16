import Foundation

struct LiveConversationDocument: Codable, Equatable, Sendable {
    struct RecoveredDraft: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let draft: Draft
        let created: Date
    }
    struct Draft: Codable, Equatable, Sendable {
        var id: UUID
        var revision: Int
        var text: String
        var updated: Date
        static func empty() -> Self { .init(id: UUID(),revision: 1,text: "",updated: Date()) }
        static func == (lhs: Self,rhs: Self) -> Bool {
            // Ownership is exact content + revision. JSON millisecond date
            // roundtrips may change sub-microsecond metadata precision; that
            // must not create a false conflict or silently adopt other words.
            lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
        var submissionID: UUID {
            let hex = TranscriptSourceMap.sha(Data((id.uuidString+":"+String(revision)).utf8))
            let a = Array(hex.prefix(32)); let value = String(a[0..<8])+"-"+String(a[8..<12])+"-"+String(a[12..<16])+"-"+String(a[16..<20])+"-"+String(a[20..<32])
            return UUID(uuidString: value)!
        }
    }
    struct Message: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let text: String
        let created: Date
        // Only text explicitly sent in this composer may leave the app.
        let explicitlySubmitted: Bool
        // Optional for old history. This local-only typed request is never part
        // of prompt(for:); free-form messages carry no inferred editing intent.
        var localEdit: ConversationLocalEditInstruction? = nil
    }
    struct Turn: Codable, Equatable, Identifiable, Sendable {
        enum State: String, Codable, Sendable { case running, succeeded, failed, cancelled, interrupted }
        let id: UUID
        let messageIDs: [UUID]
        let created: Date
        let ownerPID: Int32
        var state: State
        var text: String
        var events: [ClaudeEvent]
        var failure: String?
        var retryOf: UUID? = nil
    }
    struct Packet: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let messageIDs: [UUID]
        let turnIDs: [UUID]
        let created: Date
        let reviewOnly: Bool
    }
    let schemaVersion: Int
    let projectID: UUID
    let sessionID: UUID
    var revision: Int
    var messages: [Message]
    var turns: [Turn]
    var packets: [Packet]
    var draft: Draft?
    var retiredDrafts: [UUID:Int]?
    var recoveredDrafts: [RecoveredDraft]?
    init(projectID: UUID) {
        schemaVersion = 1; self.projectID = projectID; sessionID = UUID()
        revision = 0; messages = []; turns = []; packets = []
    }
    var queued: [Message] {
        let assigned = Set(turns.flatMap(\.messageIDs)); return messages.filter { !assigned.contains($0.id) }
    }
    var running: Turn? { turns.last(where: { $0.state == .running }) }
    var latestActivity: Date? { (messages.map(\.created)+[draft?.updated].compactMap { $0 }).max() }
    func prompt(for ids: [UUID]) throws -> String {
        let values = try ids.map { id in
            guard let message = messages.first(where: { $0.id == id }), message.explicitlySubmitted else { throw ProjectFailure.invalidProject }
            return message.text
        }
        return values.joined(separator: "\n\nAdditional steering:\n")
    }
    func validate(project: UUID) throws {
        guard schemaVersion == 1, projectID == project, (0..<1_000_000).contains(revision),
              messages.count <= 512, turns.count <= 512, packets.count <= 512,
              Set(messages.map(\.id)).count == messages.count, Set(turns.map(\.id)).count == turns.count,
              Set(packets.map(\.id)).count == packets.count,
              messages.allSatisfy({ $0.explicitlySubmitted && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.utf8.count <= 16_384 && !$0.text.utf8.contains(0) && $0.created.timeIntervalSince1970.isFinite }),
              turns.filter({ $0.state == .running }).count <= 1, (retiredDrafts?.count ?? 0) <= 512,
              (retiredDrafts ?? [:]).values.allSatisfy({ (1...1_000_000).contains($0) }) else { throw ProjectFailure.invalidProject }
        for message in messages { try message.localEdit?.validate(text: message.text,project: project) }
        let recovered = recoveredDrafts ?? []
        guard recovered.count <= 512, Set(recovered.map(\.id)).count == recovered.count,
              recovered.allSatisfy({ Self.validDraft($0.draft) && !$0.draft.text.isEmpty && $0.created.timeIntervalSince1970.isFinite }) else { throw ProjectFailure.invalidProject }
        if let draft {
            guard Self.validDraft(draft),
                  draft.revision > (retiredDrafts?[draft.id] ?? 0) else { throw ProjectFailure.invalidProject }
        }
        var assigned = Set<UUID>()
        var earlier: [Turn] = []
        for turn in turns {
            guard !turn.messageIDs.isEmpty, turn.messageIDs.count <= 4, turn.ownerPID > 0,
                  Set(turn.messageIDs).count == turn.messageIDs.count,
                  turn.messageIDs.allSatisfy({ id in messages.contains(where: { $0.id == id }) }),
                  turn.text.utf8.count <= 1024*1024, turn.events.count <= 8192,
                  (turn.failure?.utf8.count ?? 0) <= 4096, turn.created.timeIntervalSince1970.isFinite else { throw ProjectFailure.invalidProject }
            if let previous = turn.retryOf {
                guard let parent = earlier.last, parent.id == previous,
                      [.failed,.cancelled,.interrupted].contains(parent.state),
                      parent.messageIDs == turn.messageIDs else { throw ProjectFailure.invalidProject }
            } else {
                guard assigned.isDisjoint(with: turn.messageIDs) else { throw ProjectFailure.invalidProject }
            }
            assigned.formUnion(turn.messageIDs)
            earlier.append(turn)
        }
        for packet in packets {
            guard packet.reviewOnly, !packet.messageIDs.isEmpty, packet.created.timeIntervalSince1970.isFinite,
                  Set(packet.messageIDs).count == packet.messageIDs.count, Set(packet.turnIDs).count == packet.turnIDs.count,
                  packet.messageIDs.allSatisfy({ id in messages.contains(where: { $0.id == id }) }),
                  packet.turnIDs.allSatisfy({ id in turns.contains(where: { $0.id == id && $0.state != .running }) }) else { throw ProjectFailure.invalidProject }
        }
    }
    static func validDraft(_ draft: Draft) -> Bool {
        (1...1_000_000).contains(draft.revision) && draft.text.utf8.count <= 16_384 && !draft.text.utf8.contains(0) && draft.updated.timeIntervalSince1970.isFinite
    }
}

struct LiveConversationDraftConflict: LocalizedError {
    var errorDescription: String? { "Another window saved different words. Keep Both Drafts to continue without losing either draft." }
}

/// Shared with the fixture adapter, with bounded text/event accumulation for
/// the live composer. Tool events are refused: conversation has no file tools.
struct LiveConversationReply: Sendable {
    let sessionID: UUID
    private(set) var identified = false
    private(set) var text = ""
    private(set) var events: [ClaudeEvent] = []
    private(set) var finished = false
    private(set) var failed = false
    mutating func receive(_ line: String) throws {
        guard !finished else { throw ClaudeFailure.invalidStream }
        let incoming = try ClaudeStreamParser().parse(line)
        for event in incoming {
            guard !finished else { throw ClaudeFailure.invalidStream }
            switch event {
            case .session(let id): guard id == sessionID else { throw ClaudeFailure.sessionMismatch }; identified = true
            case .textDelta(let value): text += value
            case .assistantText(let value): text = value
            case .result(let value,let error,_):
                guard identified else { throw ClaudeFailure.missingSession }
                // Failure results may contain client instructions or diagnostics.
                // Keep them in the raw event history, without replacing words
                // already received from the assistant or becoming the main UI.
                if !error, !value.isEmpty { text = value }; finished = true; failed = error
            case .tool: throw ClaudeClientFailure.unavailable("Claude requested a tool in a text-only conversation. No app edit was authorized.")
            case .retry, .unknown: break
            }
            events.append(event)
            guard events.count <= 8192, text.utf8.count <= 1024*1024 else { throw ClaudeClientFailure.outputLimit }
        }
    }
}
