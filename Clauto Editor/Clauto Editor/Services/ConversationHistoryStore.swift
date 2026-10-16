import Foundation
import Darwin

/// Used only on repository actors, under the common mutation lease for writes.
/// Archive first, then pointer: a failed pointer leaves an ignored orphan, never
/// an active reference to missing words. No pathname cleanup or archive mutation.
enum ConversationHistoryStore {
    private struct Envelope: Codable { let sha256: String;let payload: Data }
    static func encode(_ value: LiveConversationDocument) throws -> Data {
        let encoder = CreativeAssetFiles.encoder(),payload = try encoder.encode(value)
        guard payload.count<=12*1024*1024 else { throw ProjectFailure.invalidProject }
        let bytes = try encoder.encode(Envelope(sha256: TranscriptSourceMap.sha(payload),payload: payload))
        guard bytes.count<=16*1024*1024 else { throw ProjectFailure.invalidProject };return bytes
    }
    static func read(_ reference: ConversationHistory.Reference,current: LiveConversationDocument,state: SourceRenderDirectory) throws -> LiveConversationDocument {
        guard current.history?.references.indices.contains(reference.epoch)==true,current.history?.references[reference.epoch]==reference else { throw ProjectFailure.invalidProject }
        let folder = try state.child("conversation-history"),bytes = try folder.read(reference.id.uuidString+".json",limit: 16*1024*1024)
        guard TranscriptSourceMap.sha(bytes)==reference.sha256 else { throw ProjectFailure.invalidProject }
        let envelope = try CreativeAssetFiles.decode(bytes,as: Envelope.self)
        guard envelope.payload.count<=12*1024*1024,TranscriptSourceMap.sha(envelope.payload)==envelope.sha256 else { throw ProjectFailure.invalidProject }
        let value = try CreativeAssetFiles.decode(envelope.payload,as: LiveConversationDocument.self)
        try value.validate(project: current.projectID)
        guard value.sessionID==current.sessionID,value.historyEpoch==reference.epoch,
              (value.history?.references ?? []) == Array((current.history?.references ?? []).prefix(reference.epoch)),
              value.messages.count==reference.messageCount,value.turns.count==reference.turnCount,value.revision<current.revision,
              value.running==nil,value.queued.isEmpty else { throw ProjectFailure.invalidProject }
        try folder.checkPath();try state.checkPath();return value
    }
    static func rollIfNeeded(_ value: inout LiveConversationDocument,state: SourceRenderDirectory,submitting: LiveConversationDocument.Draft? = nil) throws {
        let size = try CreativeAssetFiles.encoder().encode(value).count
        guard value.messages.count>=128 || value.turns.count>=128 || size>=4*1024*1024 else { return }
        guard value.running==nil,value.queued.isEmpty,value.turns.last?.state == .succeeded,
              value.draft==nil || value.draft?.text.isEmpty==true || (submitting.map { sent in value.draft.map { $0.id==sent.id && $0.revision<=sent.revision } ?? false } == true) else { return }
        guard value.historyEpoch<4096 else { throw WorkflowFailure.invalid("This conversation has reached its local archive capacity. Your saved history and current words are preserved.") }
        let bytes = try encode(value),sha = TranscriptSourceMap.sha(bytes),folder = try state.child("conversation-history",create: true)
        let archiveID = UUID(),filename = archiveID.uuidString+".json"
        // A new identity per attempt means a failed/partial write can never
        // occupy the name needed by a retry. Only the head admits an archive.
        try folder.writeNew(bytes,name: filename)
        guard try folder.read(filename,limit: 16*1024*1024)==bytes,fsync(folder.descriptor)==0 else {
            throw WorkflowFailure.invalid("The earlier conversation could not be verified on disk. Its active history is preserved; retry saving.")
        }
        try folder.checkPath();try state.checkPath()
        let folded = try value.foldedLocalEdit(),base = folded.map { ConversationHistory.LocalBase(target: $0.target,output: $0.output,archiveSHA256: sha) }
        var refs = value.history?.references ?? []
        refs.append(.init(id: archiveID,sha256: sha,epoch: value.historyEpoch,messageCount: value.messages.count,turnCount: value.turns.count))
        let history = ConversationHistory(references: refs,feedbackSHA256: value.feedbackSHA256,
            identifiedSession: value.history?.identifiedSession==true || value.turns.contains { $0.events.contains(.session(value.sessionID)) },localBase: base)
        value.schemaVersion = 2;value.history = history;value.messages = [];value.turns = [];value.packets = [];value.retiredDrafts = nil;value.recoveredDrafts = nil;value.draft = nil
    }
    static func validateHead(_ value: LiveConversationDocument,state: SourceRenderDirectory) throws {
        guard let history = value.history,let reference = history.references.last else { return }
        let archived = try read(reference,current: value,state: state),folded = try archived.foldedLocalEdit()
        let expected = folded.map { ConversationHistory.LocalBase(target: $0.target,output: $0.output,archiveSHA256: reference.sha256) }
        guard history.feedbackSHA256==archived.feedbackSHA256,history.localBase==expected,
              history.identifiedSession==(archived.history?.identifiedSession==true || archived.turns.contains { $0.events.contains(.session(archived.sessionID)) }) else { throw ProjectFailure.invalidProject }
    }
    /// An original draft can be submitted in its own epoch or the following
    /// window when that submission triggered rollover. Never search unboundedly.
    static func receipt(for draft: LiveConversationDocument.Draft,current: LiveConversationDocument,state: SourceRenderDirectory) throws -> Bool {
        guard LiveConversationDocument.validDraft(draft) else { throw ProjectFailure.invalidProject }
        for epoch in [draft.historyEpoch ?? 0,(draft.historyEpoch ?? 0)+1] where epoch<current.historyEpoch {
            guard let refs = current.history?.references,refs.indices.contains(epoch) else { throw ProjectFailure.invalidProject }
            let archived = try read(refs[epoch],current: current,state: state)
            if let message = archived.messages.first(where: { $0.id==draft.submissionID }) {
                guard message.text.utf8.elementsEqual(draft.text.utf8) else { throw ProjectFailure.invalidProject };return true
            }
        }
        return false
    }
}
