import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

actor RegionDictationRepository {
    let project: Project
    init(project: Project) { self.project = project }
    private struct Envelope: Codable { let sha256: String; let payload: Data }
    private static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; value.dateEncodingStrategy = .millisecondsSince1970; return value
    }
    private nonisolated static func read(_ folder: SourceRenderDirectory,project: UUID) throws -> RegionDictationRecord {
        let bytes = try folder.read("speech.json",limit: 4*1024*1024); try TranscriptJSONKeys.validate(bytes)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(Envelope.self,from: bytes)
        guard envelope.payload.count <= 3*1024*1024, TranscriptSourceMap.sha(envelope.payload) == envelope.sha256 else { throw ProjectFailure.invalidProject }
        try TranscriptJSONKeys.validate(envelope.payload)
        let record = try decoder.decode(RegionDictationRecord.self,from: envelope.payload); try record.validate(project: project)
        try folder.checkPath(); return record
    }
    private func directory(create: Bool) throws -> SourceRenderDirectory {
        try ProjectMutationLease.checkedRoot(project).child(".clauto").child("region-dictation",create: create)
    }
    private func write(_ value: RegionDictationRecord,folder: SourceRenderDirectory) throws {
        let payload = try Self.encoder().encode(value)
        let bytes = try Self.encoder().encode(Envelope(sha256: TranscriptSourceMap.sha(payload),payload: payload))
        guard payload.count <= 3*1024*1024, bytes.count <= 4*1024*1024 else { throw WorkflowFailure.invalid("This dictation reached its local history limit. Your existing words remain saved.") }
        try folder.checkPath(); try folder.replacePointer(bytes,name: "speech.json"); try folder.checkPath()
    }
    func begin(_ record: RegionDictationRecord,frame: FrozenReviewFrame) throws {
        try record.validate(project: project.id)
        guard record.state == .prepared, record.revisions.isEmpty, record.failure == nil,
              record.request == frame.request, record.frameSHA256 == frame.pngSHA256,
              record.width == frame.width, record.height == frame.height, record.actualFrameTime == frame.actualTime else { throw ProjectFailure.invalidProject }
        try Self.validatePNG(frame.png,record: record)
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        try VoiceReviewProvenance.check(frame.request.target,project: project)
        let parent = try directory(create: true), folder = try parent.child(record.id.uuidString,create: true)
        var info = stat()
        if fstatat(folder.descriptor,"speech.json",&info,AT_SYMLINK_NOFOLLOW) == 0 {
            guard try Self.read(folder,project: project.id) == record,
                  try folder.read("frame.png",limit: FrameCommentRepository.pngLimit) == frame.png else { throw ProjectFailure.invalidProject }; return
        }
        guard errno == ENOENT else { throw ProjectFailure.invalidProject }
        if fstatat(folder.descriptor,"frame.png",&info,AT_SYMLINK_NOFOLLOW) == 0 {
            guard try folder.read("frame.png",limit: FrameCommentRepository.pngLimit) == frame.png else { throw ProjectFailure.invalidProject }
        } else {
            guard errno == ENOENT else { throw ProjectFailure.invalidProject }; try folder.writeNew(frame.png,name: "frame.png")
        }
        try lease.root.checkPath(); try parent.checkPath(); try write(record,folder: folder)
    }
    func update(_ value: RegionDictationRecord,from previous: RegionDictationRecord) throws {
        try value.validate(project: project.id)
        guard value.follows(previous) else { throw ProjectFailure.invalidProject }
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let parent = try directory(create: false), folder = try parent.child(value.id.uuidString)
        let current = try Self.read(folder,project: project.id)
        if current == value { return } // An uncertain publication can be retried.
        guard current == previous else { throw WorkflowFailure.invalid("This dictated region changed in another window. Its saved words are preserved.") }
        try lease.root.checkPath(); try parent.checkPath(); try write(value,folder: folder)
    }
    func read(_ id: UUID) throws -> (RegionDictationRecord,FrozenReviewFrame) {
        let parent = try directory(create: false), folder = try parent.child(id.uuidString)
        let record = try Self.read(folder,project: project.id), png = try folder.read("frame.png",limit: FrameCommentRepository.pngLimit)
        guard record.id == id else { throw ProjectFailure.invalidProject }; try Self.validatePNG(png,record: record)
        try parent.checkPath()
        return (record,.init(request: record.request,png: png,pngSHA256: record.frameSHA256,width: record.width,height: record.height,actualTime: record.actualFrameTime))
    }
    func list() throws -> [RegionDictationRecord] {
        let root = try ProjectMutationLease.checkedRoot(project)
        var info = stat(); let state = try root.child(".clauto")
        if fstatat(state.descriptor,"region-dictation",&info,AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ProjectFailure.invalidProject }; return []
        }
        let parent = try directory(create: false), names = try FileManager.default.contentsOfDirectory(atPath: parent.url.path)
        guard names.count <= 4096 else { throw WorkflowFailure.invalid("This project's dictated-region history is too large to load.") }
        var result: [RegionDictationRecord] = []
        for name in names {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: name) else { continue }
            let folder = try parent.child(name)
            if fstatat(folder.descriptor,"speech.json",&info,AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw ProjectFailure.invalidProject }; continue
            }
            let record = try Self.read(folder,project: project.id)
            guard record.id == id else { throw ProjectFailure.invalidProject }; result.append(record)
        }
        try root.checkPath(); try parent.checkPath(); return result.sorted { $0.created < $1.created }
    }
    nonisolated static func checkReferences(_ ids: [UUID],region: UUID,frame: FrozenReviewFrame,project: Project) throws {
        guard ids.count <= 64, Set(ids).count == ids.count else { throw ProjectFailure.invalidProject }
        guard !ids.isEmpty else { return }
        let parent = try ProjectMutationLease.checkedRoot(project).child(".clauto").child("region-dictation")
        for id in ids {
            let folder = try parent.child(id.uuidString), record = try read(folder,project: project.id)
            guard record.id == id, record.region.id == region, record.request == frame.request,
                  record.frameSHA256 == frame.pngSHA256, record.width == frame.width, record.height == frame.height,
                  record.actualFrameTime == frame.actualTime,
                  try folder.read("frame.png",limit: FrameCommentRepository.pngLimit) == frame.png else { throw ProjectFailure.invalidProject }
        }
        try parent.checkPath()
    }
    private nonisolated static func validatePNG(_ png: Data,record: RegionDictationRecord) throws {
        guard !png.isEmpty, png.count <= FrameCommentRepository.pngLimit, TranscriptSourceMap.sha(png) == record.frameSHA256,
              let source = CGImageSourceCreateWithData(png as CFData,nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width == record.width, image.height == record.height, CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else { throw ProjectFailure.invalidProject }
    }
}
