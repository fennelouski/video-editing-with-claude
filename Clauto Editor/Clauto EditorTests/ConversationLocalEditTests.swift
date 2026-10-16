import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct ConversationLocalEditTests {
    private func target(duration: Double = 120) -> ConversationLocalEditTarget {
        .init(projectID: UUID(),versionID: UUID(),versionNumber: 4,timelineSHA256: String(repeating: "a",count: 64),engineVersion: "synthetic-engine",duration: duration,aspect: "16:9",resolution: .fullHD)
    }
    @Test func exactLocalCommandsFoldRangeAspectAndResolutionWithoutChangingTheirAnchor() throws {
        let target = target(),text = "Trim from 1:12 to 1:30; make it portrait at 720p"
        let patches = try #require(ConversationLocalEditInterpreter.parse(text))
        let request = try patches.reduce(target.initialRequest) { try $1.applying(to: $0,target: target) }
        #expect(request.start==72 && request.end==90 && request.aspect=="9:16" && request.resolution == .hd)
        let command = ConversationLocalEditInstruction(target: target,textSHA256: TranscriptSourceMap.sha(Data(text.utf8)),patches: patches)
        try command.validate(text: text,project: target.projectID)
        #expect(throws: (any Error).self) { try command.validate(text: "Trim from 1:12 to 1:31; make it portrait at 720p",project: target.projectID) }
        #expect(throws: (any Error).self) { try command.validate(text: text,project: UUID()) }
    }
    @Test(arguments: ["don't make it portrait","maybe trim from 1 to 5","trim from 1 to 5 and delete the rest","make it portrait; invent facts","export from 1:72 to 2:00","export from 3 to 1","export from NaN to 5","use 8k","make it portrait\u{0}"])
    func ambiguousNegatedCompoundAndMalformedWordsNeverBecomeAnEdit(_ text: String) {
        #expect(ConversationLocalEditInterpreter.parse(text)==nil)
    }
    @Test func exactTimeAndFrameBoundsRefusePaddingOrAnEmptyOutput() throws {
        let target = target(duration: 10)
        for text in ["trim from 9 to 11","trim from 0 to 0.00001"] {
            let patches = try #require(ConversationLocalEditInterpreter.parse(text))
            #expect(throws: (any Error).self) { _ = try patches.reduce(target.initialRequest) { try $1.applying(to: $0,target: target) } }
        }
        let full = try #require(ConversationLocalEditInterpreter.parse("use the full cut"))
        let request = try full[0].applying(to: .init(start: 1,end: 2),target: target)
        #expect(request.start==0 && request.end==nil)
    }
    @Test func immutableJobRequestHashSurvivesJSONRoundtripAndRejectsForeignSources() throws {
        let target = target(),id = UUID(),session = UUID()
        let request = ConversationLocalEditRequest(schemaVersion: 1,projectID: target.projectID,sessionID: session,feedbackIDs: [id],commandIDs: [id],textSHA256: [id.uuidString:String(repeating: "b",count: 64)],target: target,output: target.initialRequest)
        try request.validate(project: target.projectID)
        let bytes = try CreativeAssetFiles.encoder().encode(request)
        let decoded = try CreativeAssetFiles.decode(bytes,as: ConversationLocalEditRequest.self)
        #expect(try CreativeAssetFiles.encoder().encode(decoded)==bytes)
        #expect(throws: (any Error).self) { try request.validate(project: UUID()) }
    }
    @Test func localTargetAndCommandMetadataNeverEnterTheProviderPromptAndOldMessagesStillLoad() throws {
        let target = target(),text = "make it portrait",patches = try #require(ConversationLocalEditInterpreter.parse("make it portrait"))
        let instruction = ConversationLocalEditInstruction(target: target,textSHA256: TranscriptSourceMap.sha(Data(text.utf8)),patches: patches)
        var document = LiveConversationDocument(projectID: target.projectID)
        let id = UUID();document.messages = [.init(id: id,text: text,created: Date(),explicitlySubmitted: true,localEdit: instruction)]
        try document.validate(project: target.projectID)
        #expect(try document.prompt(for: [id])==text)
        let bytes = try CreativeAssetFiles.encoder().encode(document)
        let restored = try CreativeAssetFiles.decode(bytes,as: LiveConversationDocument.self)
        #expect(restored.messages.first?.localEdit==instruction)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
        var messages = try #require(object["messages"] as? [[String:Any]])
        messages[0].removeValue(forKey: "localEdit");object["messages"] = messages
        let legacy = try CreativeAssetFiles.decode(JSONSerialization.data(withJSONObject: object),as: LiveConversationDocument.self)
        try legacy.validate(project: target.projectID);#expect(legacy.messages.first?.localEdit==nil)
        #expect(try legacy.prompt(for: [id])==text)
    }
    @Test func corruptEmptyJobEventHistoryRefusesWithoutAForceUnwrap() throws {
        let target = target(),id = UUID()
        let request = ConversationLocalEditRequest(schemaVersion: 1,projectID: target.projectID,sessionID: UUID(),feedbackIDs: [id],commandIDs: [id],textSHA256: [id.uuidString:String(repeating: "c",count: 64)],target: target,output: target.initialRequest)
        let job = ConversationLocalEditLedger.Job(id: UUID(),request: request,requestSHA256: TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(request)),created: Date(),events: [])
        var ledger = ConversationLocalEditLedger(project: target.projectID);ledger.jobs = [job]
        #expect(throws: (any Error).self) { try ledger.validate(project: target.projectID) }
    }
}
