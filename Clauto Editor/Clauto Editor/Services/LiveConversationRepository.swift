import Foundation
import Darwin

actor LiveConversationRepository {
    private struct Envelope: Codable { let sha256: String; let payload: Data }
    let project: Project
    init(project: Project) { self.project = project }
    private nonisolated static func read(_ state: SourceRenderDirectory,project: UUID) throws -> LiveConversationDocument {
        var info = stat()
        if fstatat(state.descriptor,"live-conversation.json",&info,AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ProjectFailure.invalidProject }; return .init(projectID: project)
        }
        let bytes = try state.read("live-conversation.json",limit: 16*1024*1024)
        try TranscriptJSONKeys.validate(bytes)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(Envelope.self,from: bytes)
        guard envelope.payload.count <= 12*1024*1024, TranscriptSourceMap.sha(envelope.payload) == envelope.sha256 else { throw ProjectFailure.invalidProject }
        try TranscriptJSONKeys.validate(envelope.payload)
        let value = try decoder.decode(LiveConversationDocument.self,from: envelope.payload); try value.validate(project: project)
        return value
    }
    func load() throws -> LiveConversationDocument {
        let root = try ProjectMutationLease.checkedRoot(project), state = try root.child(".clauto")
        let value = try Self.read(state,project: project.id); try root.checkPath(); try state.checkPath(); return value
    }
    private func mutate(_ edit: (inout LiveConversationDocument) throws -> Void) throws -> LiveConversationDocument {
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let state = try lease.root.child(".clauto"), previous = try Self.read(state,project: project.id)
        var value = previous; try edit(&value)
        guard value != previous else { return value }
        value.revision += 1; try value.validate(project: project.id)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(value), bytes = try encoder.encode(Envelope(sha256: TranscriptSourceMap.sha(payload),payload: payload))
        guard payload.count <= 12*1024*1024, bytes.count <= 16*1024*1024 else { throw WorkflowFailure.invalid("This local conversation reached its history limit. Existing messages and replies remain saved.") }
        try lease.root.checkPath(); try state.checkPath(); try state.replacePointer(bytes,name: "live-conversation.json")
        try lease.root.checkPath(); try state.checkPath(); return value
    }
    /// Called under the local job repository's existing common lease. This does
    /// not expose project content to the provider or acquire a nested lock.
    nonisolated static func localEditingSnapshot(_ state: SourceRenderDirectory,project: UUID) throws -> LiveConversationDocument {
        try read(state,project: project)
    }
    func enqueue(_ text: String,id: UUID,created: Date,localEdit: ConversationLocalEditInstruction? = nil) throws -> LiveConversationDocument {
        try mutate { value in
            if let previous = value.messages.first(where: { $0.id == id }) {
                guard previous.text.utf8.elementsEqual(text.utf8), previous.explicitlySubmitted else { throw ProjectFailure.invalidProject }; return
            }
            value.messages.append(.init(id: id,text: text,created: created,explicitlySubmitted: true,localEdit: localEdit))
        }
    }
    private func checkDraft(_ draft: LiveConversationDocument.Draft,expected: LiveConversationDocument.Draft?,value: LiveConversationDocument) throws {
        let stored = value.draft
        let consumedBase = stored == nil && expected.map { (value.retiredDrafts?[$0.id] ?? 0) >= $0.revision && $0.id == draft.id } == true
        guard stored == expected || stored == draft || consumedBase,
              stored == nil || stored!.id == draft.id,
              stored == nil || stored!.revision <= draft.revision,
              stored?.revision != draft.revision || stored == draft else {
            throw LiveConversationDraftConflict()
        }
    }
    func saveDraft(_ draft: LiveConversationDocument.Draft,expected: LiveConversationDocument.Draft? = nil) throws -> LiveConversationDocument {
        try mutate { value in
            guard draft.revision > (value.retiredDrafts?[draft.id] ?? 0) else { return }
            try checkDraft(draft,expected: expected,value: value)
            value.draft = draft
        }
    }
    func submitDraft(_ draft: LiveConversationDocument.Draft,expected: LiveConversationDocument.Draft?,localEdit: ConversationLocalEditInstruction? = nil) throws -> LiveConversationDocument {
        try mutate { value in
            if let previous = value.messages.first(where: { $0.id == draft.submissionID }) {
                guard previous.text.utf8.elementsEqual(draft.text.utf8), previous.explicitlySubmitted else { throw ProjectFailure.invalidProject }
            } else {
                guard draft.revision > (value.retiredDrafts?[draft.id] ?? 0) else { throw ProjectFailure.invalidProject }
                try checkDraft(draft,expected: expected,value: value)
                value.messages.append(.init(id: draft.submissionID,text: draft.text,created: Date(),explicitlySubmitted: true,localEdit: localEdit))
            }
            var retired = value.retiredDrafts ?? [:]; retired[draft.id] = max(retired[draft.id] ?? 0,draft.revision); value.retiredDrafts = retired
            if let saved = value.draft, saved.id == draft.id, saved.revision <= draft.revision { value.draft = nil }
        }
    }
    private func preserve(_ draft: LiveConversationDocument.Draft,in value: inout LiveConversationDocument) throws {
        guard LiveConversationDocument.validDraft(draft) else { throw ProjectFailure.invalidProject }
        guard !draft.text.isEmpty, value.recoveredDrafts?.contains(where: { $0.draft == draft }) != true else { return }
        var recovered = value.recoveredDrafts ?? []
        recovered.append(.init(id: UUID(),draft: draft,created: Date())); value.recoveredDrafts = recovered
    }
    /// The original local snapshot and the fresh saved draft are handled under
    /// one lease. Neither becomes a submitted message or a provider request.
    func preserveLocalDraft(_ local: LiveConversationDocument.Draft) throws -> LiveConversationDocument {
        try mutate { value in
            if value.draft != local { try preserve(local,in: &value) }
        }
    }
    func restoreRecoveredDraft(_ archive: UUID,newID: UUID,local: LiveConversationDocument.Draft) throws -> LiveConversationDocument {
        try mutate { value in
            guard let chosen = value.recoveredDrafts?.first(where: { $0.id == archive }) else { throw ProjectFailure.invalidProject }
            try preserve(local,in: &value)
            if let current = value.draft {
                try preserve(current,in: &value)
                if current.text.utf8.elementsEqual(chosen.draft.text.utf8) { return }
            }
            value.draft = .init(id: newID,revision: 1,text: chosen.draft.text,updated: Date())
        }
    }
    func acknowledgeDraft(_ draft: LiveConversationDocument.Draft) throws -> LiveConversationDocument {
        try mutate { value in
            guard value.messages.contains(where: { $0.id == draft.submissionID && $0.text.utf8.elementsEqual(draft.text.utf8) }) else { throw ProjectFailure.invalidProject }
            var retired = value.retiredDrafts ?? [:]; retired[draft.id] = max(retired[draft.id] ?? 0,draft.revision); value.retiredDrafts = retired
            if let saved = value.draft, saved.id == draft.id, saved.revision <= draft.revision { value.draft = nil }
        }
    }
    func recover(now: Date = Date()) throws -> LiveConversationDocument {
        try mutate { value in
            guard let index = value.turns.lastIndex(where: { $0.state == .running }) else { return }
            let turn = value.turns[index]
            if kill(turn.ownerPID,0) == 0, now.timeIntervalSince(turn.created) < 240 { return }
            value.turns[index].state = .interrupted
            value.turns[index].failure = "The earlier reply ended before completion. Its received words remain saved."
        }
    }
    func beginTurn(id: UUID,now: Date = Date()) throws -> LiveConversationDocument {
        try mutate { value in
            if let previous = value.turns.first(where: { $0.id == id }) {
                guard previous.ownerPID == getpid(), previous.state == .running else { throw ClaudeFailure.busy }; return
            }
            guard value.running == nil else { throw ClaudeFailure.busy }
            var queued: [LiveConversationDocument.Message] = []
            for message in value.queued.prefix(4) {
                let next = queued+[message]
                if try value.prompt(for: next.map(\.id)).utf8.count > 65_536 { break }; queued = next
            }
            guard !queued.isEmpty else { throw ClaudeFailure.incomplete }
            value.turns.append(.init(id: id,messageIDs: queued.map(\.id),created: now,ownerPID: getpid(),state: .running,text: "",events: [],failure: nil))
        }
    }
    func updateTurn(_ id: UUID,reply: LiveConversationReply,state: LiveConversationDocument.Turn.State = .running,failure: String? = nil) throws -> LiveConversationDocument {
        try mutate { value in
            guard value.sessionID == reply.sessionID,
                  let index = value.turns.firstIndex(where: { $0.id == id }),
                  value.turns[index].ownerPID == getpid() else { throw ClaudeFailure.sessionMismatch }
            let message = failure.map { String($0.prefix(1024)) }
            if value.turns[index].state == state, value.turns[index].text == reply.text,
               value.turns[index].events == reply.events, value.turns[index].failure == message { return }
            guard value.turns[index].state == .running, reply.events.starts(with: value.turns[index].events) else { throw ClaudeFailure.sessionMismatch }
            if state == .succeeded { guard reply.finished, !reply.failed else { throw ClaudeFailure.incomplete } }
            value.turns[index].text = reply.text; value.turns[index].events = reply.events
            value.turns[index].state = state; value.turns[index].failure = message
        }
    }
    func retryTurn(_ previous: UUID,id: UUID,now: Date = Date()) throws -> LiveConversationDocument {
        try mutate { value in
            if let existing = value.turns.first(where: { $0.id == id }) {
                guard existing.retryOf == previous, existing.ownerPID == getpid(), existing.state == .running else { throw ClaudeFailure.busy }; return
            }
            guard value.running == nil, let parent = value.turns.last, parent.id == previous,
                  [.failed,.cancelled,.interrupted].contains(parent.state) else { throw ClaudeFailure.busy }
            value.turns.append(.init(id: id,messageIDs: parent.messageIDs,created: now,ownerPID: getpid(),state: .running,text: "",events: [],failure: nil,retryOf: parent.id))
        }
    }
    func sealIdlePacket(now: Date = Date(),idleInterval: TimeInterval = 120) throws -> LiveConversationDocument {
        guard idleInterval.isFinite, (0...86_400).contains(idleInterval) else { throw ProjectFailure.invalidProject }
        return try mutate { value in
            guard let last = value.latestActivity, now.timeIntervalSince(last) >= idleInterval,
                  value.running == nil, value.queued.isEmpty, value.draft?.text.isEmpty != false, !value.messages.isEmpty else { return }
            let ids = value.messages.map(\.id)
            guard value.packets.last?.messageIDs != ids else { return }
            value.packets.append(.init(id: UUID(),messageIDs: ids,turnIDs: value.turns.map(\.id),created: now,reviewOnly: true))
        }
    }
    func textOnlyWorkspace(session: UUID) throws -> URL {
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let state = try lease.root.child(".clauto"), clients = try state.child("conversation-clients",create: true)
        let folder = try clients.child(session.uuidString,create: true)
        // This directory holds no project media, engine, transcript or frame.
        // CLI tools, hooks, skills and external connectors are disabled as well.
        try lease.root.checkPath(); try clients.checkPath(); try folder.checkPath(); return folder.url
    }
}
