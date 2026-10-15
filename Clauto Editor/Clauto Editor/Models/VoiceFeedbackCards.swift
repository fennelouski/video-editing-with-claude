import Foundation

/// A card operation changes review instructions only; camera media, saved cuts
/// and original ASR notes remain immutable evidence. Retrying an operation ID
/// acknowledges the same transaction and cannot create duplicate children.
struct VoiceCardRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case merge, split }
    let id: UUID
    let kind: Kind
    let parents: [VoiceNoteRevision]
    var splitUTF16: Int?
    var childIDs: [UUID] {
        (0..<(kind == .merge ? 1:2)).map { index in
            let hex = TranscriptSourceMap.sha(Data((id.uuidString+":"+String(index)).utf8))
            let chars = Array(hex.prefix(32))
            let value = String(chars[0..<8])+"-"+String(chars[8..<12])+"-"+String(chars[12..<16])+"-"+String(chars[16..<20])+"-"+String(chars[20..<32])
            return UUID(uuidString: value)!
        }
    }
}
struct VoiceCardLineage: Codable, Sendable {
    let operation: VoiceCardRequest
    let part: Int
    let parentAnchors: [VoiceNoteAnchor]
}

extension VoiceReviewDocument {
    func validateCardLineage() throws {
        for operation in cardOperations ?? [] {
            guard operation.parents.count == (operation.kind == .merge ? 2:1), Set(operation.parents.map(\.id)).count == operation.parents.count else { throw ProjectFailure.invalidProject }
            guard let firstRef = operation.parents.first, let firstIndex = notes.firstIndex(where: { $0.id == firstRef.id }) else { throw ProjectFailure.invalidProject }
            let first = notes[firstIndex], ordinal = captureOrder(first,fallback: firstIndex), path = first.capturePath ?? []
            for (part,id) in operation.childIDs.enumerated() {
                guard let child = notes.first(where: { $0.id == id }), child.lineage?.operation == operation, child.lineage?.part == part, child.captureOrdinal == ordinal,
                      child.capturePath == path+(operation.kind == .split ? [part]:[]), (child.capturePath ?? []).count <= 64 else { throw ProjectFailure.invalidProject }
            }
            for ref in operation.parents {
                guard let parent = notes.first(where: { $0.id == ref.id }), parent.revision > ref.revision,
                      parent.state == .cancelled, parent.supersededBy == operation.childIDs else { throw ProjectFailure.invalidProject }
            }
        }
        for note in notes {
            if let lineage = note.lineage { guard (cardOperations ?? []).contains(lineage.operation), lineage.operation.childIDs.contains(note.id) else { throw ProjectFailure.invalidProject } }
            if !(note.supersededBy ?? []).isEmpty {
                guard (cardOperations ?? []).contains(where: { $0.parents.contains(where: { $0.id == note.id }) && $0.childIDs == note.supersededBy }) else { throw ProjectFailure.invalidProject }
            }
        }
    }

    /// Display order follows the captured audio timeline, never ASR completion.
    var orderedVisibleNotes: [VoiceReviewNote] {
        notes.enumerated().filter { ($0.element.supersededBy ?? []).isEmpty }.sorted { a,b in
            let x = captureOrder(a.element,fallback: a.offset), y = captureOrder(b.element,fallback: b.offset)
            if x != y { return x < y }
            let lhs = a.element.capturePath ?? [], rhs = b.element.capturePath ?? []
            return lhs == rhs ? a.offset < b.offset : lhs.lexicographicallyPrecedes(rhs)
        }.map(\.element)
    }
    func captureOrder(_ note: VoiceReviewNote,fallback: Int) -> Int64 {
        if let ordinal = note.captureOrdinal { return ordinal }
        let session = sessions.firstIndex { $0.id == note.sessionID } ?? 0
        if let start = note.audioStart, start.isFinite, start >= 0, start < 86_400 {
            return Int64(session)*100_000_000_000+Int64((start*1_000_000).rounded())
        }
        return Int64(session)*100_000_000_000+90_000_000_000+Int64(fallback)
    }
    mutating func restructureCards(_ request: VoiceCardRequest,now: Date = Date()) throws {
        if let old = (cardOperations ?? []).first(where: { $0.id == request.id }) {
            guard old == request else { throw WorkflowFailure.invalid("This card operation ID belongs to a different edit. Reload the cards.") }; return
        }
        guard request.parents.count == (request.kind == .merge ? 2:1), Set(request.parents.map(\.id)).count == request.parents.count else { throw ProjectFailure.invalidProject }
        let parents = try request.parents.map { ref -> VoiceReviewNote in
            guard let note = notes.first(where: { $0.id == ref.id && $0.revision == ref.revision }), note.isFinal,
                  note.state != .cancelled, (note.supersededBy ?? []).isEmpty,
                  !(drafts ?? []).contains(where: { $0.noteID == note.id }) else {
                throw WorkflowFailure.invalid("A card changed or has an unsaved edit. Save or discard its draft and reload before merging or splitting.")
            }
            return note
        }
        if request.kind == .merge {
            let ordered = orderedVisibleNotes.filter { $0.state != .cancelled }
            guard let index = ordered.firstIndex(where: { $0.id == parents[0].id }), index+1 < ordered.count,
                  ordered[index+1].id == parents[1].id,
                  let target = parents[0].effectiveAnchor?.targetID, parents[1].effectiveAnchor?.targetID == target else {
                throw WorkflowFailure.invalid("Merge adjacent finalized cards from the same saved version. Resolve their timing first.")
            }
        }
        let texts: [String]
        if request.kind == .merge { texts = [parents.map(\.text).joined(separator: "\n")] }
        else {
            let text = parents[0].text
            guard let offset = request.splitUTF16, offset > 0, offset < text.utf16.count else { throw WorkflowFailure.invalid("Choose a word boundary inside this card.") }
            let index = String.Index(utf16Offset: offset,in: text)
            guard text.indices.contains(index), index.utf16Offset(in: text) == offset,
                  let before = text[..<index].last, let after = text[index...].first,
                  before.isWhitespace || after.isWhitespace || before.isPunctuation || after.isPunctuation else {
                throw WorkflowFailure.invalid("Split between words, without cutting a character or inventing word timing.")
            }
            texts = [String(text[..<index]),String(text[index...])].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard texts.allSatisfy({ !$0.isEmpty }) else { throw WorkflowFailure.invalid("Both cards need text.") }
        }
        guard notes.count+texts.count <= 10_000, (cardOperations ?? []).count < 10_000,
              texts.allSatisfy({ $0.count <= 20_000 }), parents.allSatisfy({ $0.history.count < 512 }),
              !request.childIDs.contains(where: { id in notes.contains(where: { $0.id == id }) }) else { throw WorkflowFailure.invalid("This review reached its card/history limit. The original cards remain unchanged.") }
        // Deduplicate shared utterance evidence by identity, never by words:
        // two separate utterances may legitimately say exactly the same thing.
        var originals: [String] = [], seen: Set<UUID> = []
        var evidence = parents.reversed().map(\.id)
        while let id = evidence.popLast() {
            guard seen.insert(id).inserted else { continue }
            guard let original = notes.first(where: { $0.id == id }) else { throw ProjectFailure.invalidProject }
            if let source = original.speechSourceID { evidence.append(source) }
            else if let lineage = original.lineage { evidence.append(contentsOf: lineage.operation.parents.reversed().map(\.id)) }
            else { originals.append(original.transcript) }
        }
        let rawTranscript = originals.joined(separator: "\n")
        guard rawTranscript.count <= 20_000 else { throw WorkflowFailure.invalid("The combined original transcript exceeds this card's limit. Original cards remain unchanged.") }
        let first = parents[0], anchors = parents.compactMap(\.effectiveAnchor)
        let ordinal = captureOrder(first,fallback: notes.firstIndex(where: { $0.id == first.id })!)
        let parentPath = first.capturePath ?? []
        guard parentPath.count < 64 else { throw WorkflowFailure.invalid("This card reached its structure-depth limit. Original cards are retained.") }
        for (part,text) in texts.enumerated() {
            var child = VoiceReviewNote(id: request.childIDs[part],sessionID: first.sessionID,segmentID: "card-"+request.childIDs[part].uuidString,
                audioStart: nil,audioEnd: nil,created: now,transcript: rawTranscript,text: text,isFinal: true,intent: .infer(text))
            child.manuallyEdited = true; child.onset = first.onset
            child.lineage = .init(operation: request,part: part,parentAnchors: anchors); child.captureOrdinal = ordinal
            child.capturePath = parentPath+(request.kind == .split ? [part]:[])
            child.history = [.init(date: now,source: request.kind == .merge ? "User merged cards; resolve new range/action" : "User split card; word timing not inferred",text: text,revision: 1)]
            notes.append(child)
        }
        for ref in request.parents {
            let i = notes.firstIndex { $0.id == ref.id }!
            notes[i].supersededBy = request.childIDs; notes[i].state = .cancelled; notes[i].revision += 1
            notes[i].history.append(.init(date: now,source: "Superseded by card \(request.kind.rawValue) \(request.id.uuidString)",text: notes[i].text,revision: notes[i].revision))
        }
        var operations = cardOperations ?? []; operations.append(request); cardOperations = operations
        refresh()
    }
}
