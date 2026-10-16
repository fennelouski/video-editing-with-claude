import Foundation
import Synchronization

/// Tiny cross-actor admission state, checked only after a waiting terminal
/// mutation owns its project lease. No mutex is held through disk I/O or await.
final class ConversationLocalEditAdmission: Sendable {
    private let storage = Mutex(false)
    func cancel() { storage.withLock { $0 = true } }
    var cancelled: Bool { storage.withLock { $0 } }
}

/// Local-only anchor captured when an exact supported command is submitted.
/// It is never appended to the text-only provider prompt.
struct ConversationLocalEditTarget: Codable,Equatable,Sendable {
    let projectID: UUID
    let versionID: UUID
    let versionNumber: Int
    let timelineSHA256: String
    let engineVersion: String
    let duration: Double
    let aspect: String
    let resolution: ExportResolution
    func validate(project: UUID) throws {
        guard projectID==project,versionNumber>0,CutoutSourceInfo.validHash(timelineSHA256),
              !engineVersion.isEmpty,engineVersion.utf8.count<=256,
              duration.isFinite,duration>0,duration<=86400,["16:9","9:16"].contains(aspect) else { throw ProjectFailure.invalidProject }
    }
    var initialRequest: DerivativeRequest { .init(aspect: aspect,resolution: resolution) }
}

struct ConversationLocalEditPatch: Codable,Equatable,Sendable {
    var start: Double?
    var end: Double?
    var aspect: String?
    var resolution: ExportResolution?
    var fullRange = false
    func applying(to previous: DerivativeRequest,target: ConversationLocalEditTarget) throws -> DerivativeRequest {
        try target.validate(project: target.projectID)
        guard (start==nil)==(end==nil),!fullRange || start==nil,
              start != nil || aspect != nil || resolution != nil || fullRange,
              aspect==nil || ["16:9","9:16"].contains(aspect!) else { throw ProjectFailure.invalidProject }
        var value = previous
        if fullRange { value.start = 0;value.end = nil }
        if let start,let end { value.start = start;value.end = end }
        if let aspect { value.aspect = aspect }
        if let resolution { value.resolution = resolution }
        try value.validate(duration: target.duration)
        guard DerivativeRequest.snapped(value.end ?? target.duration)>DerivativeRequest.snapped(value.start) else { throw ProjectFailure.invalidProject }
        return value
    }
}

/// Deliberately small complete-command grammar. Free-form chat never becomes an
/// inferred edit, factual approval or upload. Each clause must be understood.
enum ConversationLocalEditInterpreter {
    static func parse(_ text: String) -> [ConversationLocalEditPatch]? {
        guard text.utf8.count<=16384,!text.utf8.contains(0) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let clauses = value.components(separatedBy: CharacterSet(charactersIn: ";\n")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !clauses.isEmpty,clauses.count<=8 else { return nil }
        var values: [ConversationLocalEditPatch] = []
        for clause in clauses {
            guard let patch = clausePatch(clause.trimmingCharacters(in: .whitespaces)) else { return nil };values.append(patch)
        }
        return values
    }
    private static func match(_ pattern: String,_ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),let result = expression.firstMatch(in: text,range: NSRange(text.startIndex...,in: text)),result.range.length==(text as NSString).length else { return nil }
        return (1..<result.numberOfRanges).map { index in let range = result.range(at: index);return range.location==NSNotFound ? "":(text as NSString).substring(with: range) }
    }
    private static func aspect(_ text: String) -> String? {
        switch text { case "portrait","vertical":return "9:16";case "landscape","horizontal":return "16:9";default:return nil }
    }
    private static func resolution(_ text: String) -> ExportResolution? {
        switch text { case "720p":return .hd;case "1080p":return .fullHD;case "2160p","4k":return .ultraHD;default:return nil }
    }
    private static func seconds(_ text: String) -> Double? {
        let pieces = text.split(separator: ":",omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count),pieces.allSatisfy({ !$0.isEmpty }) else { return nil }
        var result = 0.0
        for (index,piece) in pieces.enumerated() {
            guard let number = Double(piece),number.isFinite,number>=0,
                  index==pieces.count-1 || number.rounded(.towardZero)==number,
                  index==0 || number<60 else { return nil }
            result = result*60+number
        }
        return result.isFinite && result<=86400 ? result:nil
    }
    private static func clausePatch(_ text: String) -> ConversationLocalEditPatch? {
        if let parts = match(#"^(?:please )?(?:make|export)(?: it| this)? (?:in )?(portrait|vertical|landscape|horizontal)(?: at (720p|1080p|2160p|4k))?\.?$"#,text) {
            return .init(aspect: aspect(parts[0]),resolution: resolution(parts[1]))
        }
        if let parts = match(#"^(?:please )?(?:trim|export|use)(?: the cut)?(?: from)? ([0-9:.]+) (?:to|through|until) ([0-9:.]+)(?: (?:in|as) (portrait|vertical|landscape|horizontal))?(?: at (720p|1080p|2160p|4k))?\.?$"#,text),let start = seconds(parts[0]),let end = seconds(parts[1]),end>start {
            return .init(start: start,end: end,aspect: aspect(parts[2]),resolution: resolution(parts[3]))
        }
        if let parts = match(#"^(?:please )?(?:use|set resolution to|set the resolution to|export at) (720p|1080p|2160p|4k)\.?$"#,text) {
            return .init(resolution: resolution(parts[0]))
        }
        if match(#"^(?:please )?(?:use|export) (the full cut)\.?$"#,text) != nil { return .init(fullRange: true) }
        return nil
    }
}

struct ConversationLocalEditInstruction: Codable,Equatable,Sendable {
    let target: ConversationLocalEditTarget
    let textSHA256: String
    let patches: [ConversationLocalEditPatch]
    func validate(text: String,project: UUID) throws {
        try target.validate(project: project)
        guard textSHA256==TranscriptSourceMap.sha(Data(text.utf8)),ConversationLocalEditInterpreter.parse(text)==patches,!patches.isEmpty else { throw ProjectFailure.invalidProject }
        _ = try patches.reduce(target.initialRequest) { try $1.applying(to: $0,target: target) }
    }
}

struct ConversationLocalEditRequest: Codable,Equatable,Sendable {
    let schemaVersion: Int
    let projectID: UUID
    let sessionID: UUID
    let feedbackIDs: [UUID]
    let commandIDs: [UUID]
    let textSHA256: [String:String]
    let target: ConversationLocalEditTarget
    let output: DerivativeRequest
    var feedbackSHA256: String? = nil
    var inherited: ConversationHistory.LocalBase? = nil
    func matches(_ document: LiveConversationDocument) -> Bool {
        sessionID==document.sessionID && (feedbackSHA256.map { $0==document.feedbackSHA256 } ?? (document.historyEpoch==0 && feedbackIDs==document.messages.map(\.id)))
    }
    func validate(project: UUID) throws {
        try target.validate(project: project)
        if let inherited { try inherited.validate(project: project);guard inherited.target==target,feedbackSHA256 != nil else { throw ProjectFailure.invalidProject } }
        guard feedbackSHA256.map(CutoutSourceInfo.validHash) ?? true else { throw ProjectFailure.invalidProject }
        guard schemaVersion==1,projectID==project,!feedbackIDs.isEmpty,feedbackIDs.count<=512,
              Set(feedbackIDs).count==feedbackIDs.count,(!commandIDs.isEmpty || inherited != nil),
              Set(commandIDs).count==commandIDs.count,Set(commandIDs).isSubset(of: Set(feedbackIDs)),
              Set(textSHA256.keys)==Set(commandIDs.map(\.uuidString)),textSHA256.values.allSatisfy(CutoutSourceInfo.validHash),
              output.graphic==nil,output.soundFileID==nil,output.effects==nil else { throw ProjectFailure.invalidProject }
        try output.validate(duration: target.duration)
    }
}

struct ConversationLocalEditLedger: Codable,Sendable {
    struct Event: Codable,Sendable {
        enum State: String,Codable,Sendable { case queued,running,succeeded,failed,cancelled,superseded }
        let state: State
        let created: Date
        let ownerID: UUID?
        let ownerPID: Int32?
        let detail: String?
        let exportID: UUID?
        let recipeSHA256: String?
    }
    struct Job: Codable,Identifiable,Sendable {
        let id: UUID
        let request: ConversationLocalEditRequest
        let requestSHA256: String
        let created: Date
        var events: [Event]
        var state: Event.State? { events.last?.state }
    }
    let schemaVersion: Int
    let projectID: UUID
    var revision: Int
    var jobs: [Job]
    init(project: UUID) { schemaVersion = 1;projectID = project;revision = 0;jobs = [] }
    func validate(project: UUID) throws {
        guard schemaVersion==1,projectID==project,(0..<1_000_000).contains(revision),jobs.count<=512,
              Set(jobs.map(\.id)).count==jobs.count,jobs.filter({ $0.state == .running }).count<=1 else { throw ProjectFailure.invalidProject }
        for job in jobs {
            try job.request.validate(project: project)
            guard job.requestSHA256==TranscriptSourceMap.sha(try CreativeAssetFiles.encoder().encode(job.request)),
                  job.created.timeIntervalSince1970.isFinite,!job.events.isEmpty,job.events.count<=4,job.events.first?.state == .queued else { throw ProjectFailure.invalidProject }
            var earlier: Event.State?
            for event in job.events {
                guard event.created.timeIntervalSince1970.isFinite,(event.detail?.utf8.count ?? 0)<=4096 else { throw ProjectFailure.invalidProject }
                if let earlier {
                    guard earlier == .queued ? [.running,.superseded,.cancelled].contains(event.state):earlier == .running && [.succeeded,.failed,.cancelled,.superseded].contains(event.state) else { throw ProjectFailure.invalidProject }
                }
                if event.state == .running { guard event.ownerID != nil,(event.ownerPID ?? 0)>0 else { throw ProjectFailure.invalidProject } }
                if event.state == .succeeded { guard event.exportID != nil,event.recipeSHA256.map(CutoutSourceInfo.validHash)==true else { throw ProjectFailure.invalidProject } }
                else { guard event.exportID==nil,event.recipeSHA256==nil else { throw ProjectFailure.invalidProject } }
                earlier = event.state
            }
        }
    }
}
