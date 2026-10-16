import Foundation

/// References name immutable, locally stored windows. Session and revision never
/// reset: archiving changes storage, not submission or provider authorization.
struct ConversationHistory: Codable,Equatable,Sendable {
    struct Reference: Codable,Equatable,Identifiable,Sendable {
        let id: UUID
        let sha256: String
        let epoch: Int
        let messageCount: Int
        let turnCount: Int
    }
    struct LocalBase: Codable,Equatable,Sendable {
        let target: ConversationLocalEditTarget
        let output: DerivativeRequest
        let archiveSHA256: String
        func validate(project: UUID) throws {
            try target.validate(project: project);try output.validate(duration: target.duration)
            guard CutoutSourceInfo.validHash(archiveSHA256),output.graphic==nil,output.soundFileID==nil,output.effects==nil else { throw ProjectFailure.invalidProject }
        }
    }
    var references: [Reference]
    let feedbackSHA256: String
    let identifiedSession: Bool
    let localBase: LocalBase?
    func validate(project: UUID) throws {
        guard !references.isEmpty,references.count<=4096,CutoutSourceInfo.validHash(feedbackSHA256),
              Set(references.map(\.id)).count==references.count,
              references.enumerated().allSatisfy({ $0.offset==$0.element.epoch && CutoutSourceInfo.validHash($0.element.sha256) && (0...512).contains($0.element.messageCount) && (0...512).contains($0.element.turnCount) }) else { throw ProjectFailure.invalidProject }
        if let localBase { try localBase.validate(project: project);guard localBase.archiveSHA256==references.last?.sha256 else { throw ProjectFailure.invalidProject } }
    }
}

extension LiveConversationDocument {
    var historyEpoch: Int { history?.references.count ?? 0 }
    /// A chain over immutable user feedback only. Streaming, packet writes and
    /// rollover do not masquerade as steering; new submitted words always do.
    var feedbackSHA256: String {
        var digest = history?.feedbackSHA256 ?? TranscriptSourceMap.sha(Data(("clauto-feedback-v1:"+projectID.uuidString+sessionID.uuidString).utf8))
        for message in messages {
            let anchor = message.localEdit.flatMap { try? CreativeAssetFiles.encoder().encode($0) } ?? Data()
            digest = TranscriptSourceMap.sha(Data((digest+message.id.uuidString+TranscriptSourceMap.sha(Data(message.text.utf8))+TranscriptSourceMap.sha(anchor)).utf8))
        }
        return digest
    }
    struct FoldedLocalEdit {
        let target: ConversationLocalEditTarget
        let output: DerivativeRequest
        let commands: [Message]
        let inherited: ConversationHistory.LocalBase?
    }
    func foldedLocalEdit() throws -> FoldedLocalEdit? {
        guard let target = messages.last(where: { $0.localEdit != nil })?.localEdit?.target ?? history?.localBase?.target else { return nil }
        let foreign = messages.lastIndex(where: { $0.localEdit.map { $0.target != target } ?? false })
        let inherited = foreign==nil && history?.localBase?.target==target ? history?.localBase:nil
        let commands = messages.dropFirst((foreign ?? -1)+1).filter { $0.localEdit?.target==target }
        guard inherited != nil || !commands.isEmpty else { return nil }
        var output = inherited?.output ?? target.initialRequest
        for message in commands {
            guard let instruction = message.localEdit else { throw ProjectFailure.invalidProject }
            try instruction.validate(text: message.text,project: projectID)
            for patch in instruction.patches { output = try patch.applying(to: output,target: target) }
        }
        return .init(target: target,output: output,commands: commands,inherited: inherited)
    }
}
