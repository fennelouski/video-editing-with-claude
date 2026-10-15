import Foundation
import Darwin
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A cancelled waiter may return before a synchronous OS read does. The queue
/// retains that job's capacity until its actual work ends; replacement requests
/// cannot create unbounded blocked workers.
final class FrameBlockingJob<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var claimed = false
    private var bound = false
    private var result: Result<Value,any Error>?
    private var continuation: CheckedContinuation<Value,any Error>?
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }; claimed = true; return true
    }
    func bind(_ continuation: CheckedContinuation<Value,any Error>) -> Bool {
        lock.lock()
        guard !bound else { lock.unlock(); continuation.resume(throwing: ProjectFailure.invalidProject); return false }
        bound = true
        if let result { lock.unlock(); continuation.resume(with: result); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func finish(_ result: Result<Value,any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let waiting = continuation; continuation = nil; lock.unlock()
        waiting?.resume(with: result)
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
}
final class FrameBlockingExecutor: @unchecked Sendable {
    static let frameChecks = FrameBlockingExecutor(label: "com.clauto.frame-grid",capacity: 64)
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let capacity: Int
    private var occupied = 0
    init(label: String,capacity: Int) {
        precondition((1...64).contains(capacity)); self.capacity = capacity
        queue = DispatchQueue(label: label,qos: .userInitiated)
    }
    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return occupied }
    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard occupied < capacity else { return false }; occupied += 1; return true
    }
    private func release() { lock.lock(); occupied -= 1; lock.unlock() }
    func perform<Value: Sendable>(job: FrameBlockingJob<Value>,_ work: @escaping @Sendable (FrameBlockingJob<Value>) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        // Only the one claimed caller may install a handler that cancels this
        // job. A rejected duplicate must never acquire cancellation ownership.
        guard job.claim() else { throw ProjectFailure.invalidProject }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard job.bind(continuation) else { return }
                guard reserve() else { job.finish(.failure(WorkflowFailure.invalid("Frame checks are busy. Retry after an earlier capture finishes."))); return }
                queue.async {
                    defer { self.release() }
                    do {
                        try job.checkCancellation(); let value = try work(job); try job.checkCancellation()
                        job.finish(.success(value))
                    } catch { job.finish(.failure(error)) }
                }
            }
        } onCancel: { job.cancel() }
        try Task.checkCancellation(); return value
    }
}

protocol ReviewFrameCapturing: Sendable {
    func capture(_ request: FrameCommentRequest, project: Project) async throws -> FrozenReviewFrame
    func cancel(_ id: UUID) async
}
protocol ReviewPeopleDetecting: Sendable {
    func detect(_ frame: FrozenReviewFrame) async throws -> [FramePersonProposal]
}
actor LocalFramePeopleDetector: ReviewPeopleDetecting {
    private static let executor = FrameBlockingExecutor(label: "com.clauto.frame-people",capacity: 4)
    func detect(_ frame: FrozenReviewFrame) async throws -> [FramePersonProposal] {
        try await Self.executor.perform(job: FrameBlockingJob<[FramePersonProposal]>()) { job in
            try Self.findPeople(in: frame,job: job)
        }
    }
    private nonisolated static func findPeople(in frame: FrozenReviewFrame,job: FrameBlockingJob<[FramePersonProposal]>) throws -> [FramePersonProposal] {
        try job.checkCancellation()
        guard frame.width > 0, frame.height > 0, frame.width <= 7680, frame.height <= 7680,
              frame.width*frame.height <= 33_177_600, !frame.png.isEmpty, frame.png.count <= FrameCommentRepository.pngLimit,
              TranscriptSourceMap.sha(frame.png) == frame.pngSHA256,
              let source = CGImageSourceCreateWithData(frame.png as CFData,nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              properties[kCGImagePropertyPixelWidth] as? Int == frame.width,
              properties[kCGImagePropertyPixelHeight] as? Int == frame.height,
              properties[kCGImagePropertyOrientation] == nil || properties[kCGImagePropertyOrientation] as? Int == 1,
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width == frame.width, image.height == frame.height, CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else { throw ProjectFailure.invalidProject }
        let request = VNDetectHumanRectanglesRequest()
        defer { request.cancel() }
        request.revision = VNDetectHumanRectanglesRequestRevision2; request.upperBodyOnly = false
        try job.checkCancellation()
        try VNImageRequestHandler(cgImage: image,orientation: .up,options: [:]).perform([request])
        try job.checkCancellation()
        return Array((request.results ?? []).sorted { $0.confidence > $1.confidence }.compactMap {
            FramePersonProposal.fromVision($0.boundingBox,confidence: Double($0.confidence),frame: frame)
        }.prefix(32))
    }
}
actor ReviewFrameCaptureService: ReviewFrameCapturing {
    private var active: (UUID,AVAssetImageGenerator)?
    private var busyID: UUID?
    private var cancelled = false
    private var gridJob: FrameBlockingJob<Void>?
    func cancel(_ id: UUID) { if busyID == id { cancelled = true; gridJob?.cancel(); active?.1.cancelAllCGImageGeneration() } }
    func capture(_ request: FrameCommentRequest, project: Project) async throws -> FrozenReviewFrame {
        guard busyID == nil, request.target.projectID == project.id else { throw ProjectFailure.invalidProject }
        busyID = request.id; cancelled = false
        defer { gridJob?.cancel(); gridJob = nil; busyID = nil; active = nil; cancelled = false }
        try request.frame.validate(duration: request.target.duration)
        try VoiceReviewProvenance.check(request.target,project: project)
        let movie = try VoiceReviewProvenance.url(request.target.preview.relativePath,project: project)
        let directory = try SourceRenderDirectory.open(movie.deletingLastPathComponent())
        guard try directory.voiceHash(movie.lastPathComponent,limit: VoiceMasterByteContract.sourceLimit) == request.target.preview.sha256 else { throw ProjectFailure.invalidProject }
        let asset = AVURLAsset(url: movie)
        try await validateFrameGrid(asset,frames: request.frame.frameCount)
        guard !cancelled else { throw CancellationError() }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        active = (request.id,generator)
        let time = CMTime(value: request.frame.presentationValue,timescale: 24000)
        let result = try await generator.image(at: time)
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard CMTimeCompare(result.actualTime,time) == 0, result.image.width > 0, result.image.height > 0,
              result.image.width <= 7680, result.image.height <= 7680, result.image.width*result.image.height <= 33_177_600 else { throw WorkflowFailure.invalid("The decoder did not return the exact paused frame. Seek to another supported frame before commenting.") }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil) else { throw ProjectFailure.invalidProject }
        CGImageDestinationAddImage(destination,result.image,nil)
        guard CGImageDestinationFinalize(destination), bytes.length <= FrameCommentRepository.pngLimit else { throw WorkflowFailure.invalid("The paused frame exceeds the 16 MiB comment image limit.") }
        try VoiceReviewProvenance.check(request.target,project: project)
        guard try directory.voiceHash(movie.lastPathComponent,limit: VoiceMasterByteContract.sourceLimit) == request.target.preview.sha256 else { throw ProjectFailure.invalidProject }
        let png = bytes as Data
        return .init(request: request,png: png,pngSHA256: TranscriptSourceMap.sha(png),width: result.image.width,height: result.image.height,actualTime: .init(value: time.value,timescale: time.timescale))
    }
    private func validateFrameGrid(_ asset: AVAsset, frames: Int) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw ProjectFailure.invalidProject }
        let (size,transform) = try await track.load(.naturalSize,.preferredTransform)
        let shown = CGRect(origin: .zero,size: size).applying(transform).standardized.size
        guard [size.width,size.height,shown.width,shown.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 7680 }),
              size.width*size.height <= 33_177_600, shown.width*shown.height <= 33_177_600 else { throw WorkflowFailure.invalid("This saved movie exceeds the 33 megapixel frame-comment limit.") }
        let segments = try await track.load(.segments)
        guard segments.count == 1, let segment = segments.first, !segment.isEmpty else { throw WorkflowFailure.invalid("Frame comments require a single continuous saved movie track.") }
        let mapping = segment.timeMapping
        guard CMTimeCompare(mapping.target.start,.zero) == 0,
              CMTimeCompare(mapping.source.duration,mapping.target.duration) == 0,
              mapping.target.duration.isNumeric, abs(mapping.target.duration.seconds-Double(frames)*1001/24000) <= 0.001 else { throw WorkflowFailure.invalid("The saved movie's presentation clock is unsupported for frame comments.") }
        try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
        let job = FrameBlockingJob<Void>(); gridJob = job
        try await FrameBlockingExecutor.frameChecks.perform(job: job) { job in
            try Self.checkGrid(asset: asset,track: track,mapping: mapping,frames: frames,job: job)
        }
        try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
    }
    private nonisolated static func checkGrid(asset: AVAsset,track: AVAssetTrack,mapping: CMTimeMapping,frames: Int,job: FrameBlockingJob<Void>) throws {
        try job.checkCancellation()
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track,outputSettings: nil)
        // Reader creation, reads and cancellation stay on one owned queue.
        // AVAssetReader forbids cancelReading racing copyNextSampleBuffer.
        defer { reader.cancelReading() }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProjectFailure.invalidProject }; reader.add(output)
        try job.checkCancellation()
        guard reader.startReading() else { throw WorkflowFailure.invalid("The saved frame grid could not be read.") }
        var seen = Set<Int>()
        while true {
            try job.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { break }
            try job.checkCancellation()
            // AVFoundation may emit zero-sample decoder boundary markers.
            // They are not frames; completeness still requires every real PTS.
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            // Compressed samples use the segment's media clock. Map through
            // its edit-list offset into the displayed presentation clock.
            let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample),mapping.source.start)
            let duration = CMSampleBufferGetDuration(sample)
            guard CMSampleBufferGetNumSamples(sample) == 1, pts.isNumeric, pts.epoch == 0,
                  pts.seconds >= 0, pts.seconds < Double(frames)*1001/24000,
                  CMTimeCompare(duration,CMTime(value: 1001,timescale: 24000)) == 0 else { throw WorkflowFailure.invalid("Frame comments currently require a constant 24000/1001 frame grid starting at zero.") }
            let index = Int((pts.seconds*24000/1001).rounded())
            guard index >= 0, index < frames, seen.insert(index).inserted,
                  CMTimeCompare(pts,CMTime(value: Int64(index)*1001,timescale: 24000)) == 0 else { throw ProjectFailure.invalidProject }
        }
        try job.checkCancellation()
        guard reader.status == .completed, seen.count == frames else { throw WorkflowFailure.invalid("The saved movie has an incomplete or unsupported frame grid.") }
    }
}
actor FrameCommentRepository {
    static let pngLimit = 16*1024*1024
    let project: Project
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    init(project: Project) {
        self.project = project
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
    }
    private func root(create: Bool) throws -> SourceRenderDirectory {
        try ProjectMutationLease.checkedRoot(project).child("notes").child("frame-comments",create: create)
    }
    private func validatePNG(_ png: Data, sha: String, width: Int, height: Int) throws {
        guard !png.isEmpty, png.count <= Self.pngLimit, TranscriptSourceMap.sha(png) == sha,
              let source = CGImageSourceCreateWithData(png as CFData,nil), CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width, properties[kCGImagePropertyPixelHeight] as? Int == height else { throw ProjectFailure.invalidProject }
        guard let decoded = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              decoded.width == width, decoded.height == height, CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else { throw ProjectFailure.invalidProject }
    }
    func save(frame: FrozenReviewFrame, text: String, annotations: [FrameEllipse], supersedes: UUID? = nil, id: UUID = UUID()) throws -> SavedFrameComment {
        try Task.checkCancellation()
        guard frame.request.target.projectID == project.id else { throw ProjectFailure.invalidProject }
        var record = SavedFrameComment(schemaVersion: 1,id: id,supersedesID: supersedes,request: frame.request,text: text.trimmingCharacters(in: .whitespacesAndNewlines),annotations: annotations,framePNG_SHA256: frame.pngSHA256,width: frame.width,height: frame.height,actualFrameTime: frame.actualTime,created: Date(),reviewOnly: true,productionAuthorized: false,appliedToVideo: false)
        try record.validate(); try validatePNG(frame.png,sha: frame.pngSHA256,width: frame.width,height: frame.height)
        let references = annotations.compactMap(\.person)
        let parent = try root(create: true)
        let lock = openat(parent.descriptor,"save.lock",O_CREAT | O_RDWR | O_NOFOLLOW,S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw ProjectFailure.invalidProject }; defer { Darwin.close(lock) }
        var lockInfo = stat()
        guard fstat(lock,&lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, flock(lock,LOCK_EX | LOCK_NB) == 0 else { throw WorkflowFailure.invalid("Another window is saving a frame comment. Retry after it finishes.") }
        defer { flock(lock,LOCK_UN) }
        try parent.checkPath()
        var existing = stat()
        if fstatat(parent.descriptor,id.uuidString,&existing,AT_SYMLINK_NOFOLLOW) == 0 {
            let folder = try parent.child(id.uuidString)
            if fstatat(folder.descriptor,"completion.json",&existing,AT_SYMLINK_NOFOLLOW) == 0 {
                let saved = try read(id)
                guard samePayload(saved.0,record), saved.1.png == frame.png else { throw ProjectFailure.invalidProject }
                return saved.0 // Recovery of a completed but unacknowledged Save.
            }
            guard errno == ENOENT else { throw ProjectFailure.invalidProject }
            if fstatat(folder.descriptor,"comment.json",&existing,AT_SYMLINK_NOFOLLOW) == 0 {
                let bytes = try folder.read("comment.json",limit: 1024*1024)
                try TranscriptJSONKeys.validate(bytes)
                let previous = try decoder.decode(SavedFrameComment.self,from: bytes)
                try previous.validate()
                guard samePayload(previous,record) else { throw ProjectFailure.invalidProject }
                record = previous // Retain the original creation timestamp.
            } else if errno != ENOENT { throw ProjectFailure.invalidProject }
        } else if errno != ENOENT { throw ProjectFailure.invalidProject }
        let peopleLease = references.isEmpty ? nil : try ProjectMutationLease.acquire(project)
        defer { withExtendedLifetime(peopleLease) {} }
        if !references.isEmpty { try ProjectPeopleRepository.checkReferences(references,project: project) }
        try VoiceReviewProvenance.check(frame.request.target,project: project)
        let movie = try VoiceReviewProvenance.url(frame.request.target.preview.relativePath,project: project)
        let source = try SourceRenderDirectory.open(movie.deletingLastPathComponent())
        guard try source.voiceHash(movie.lastPathComponent,limit: VoiceMasterByteContract.sourceLimit) == frame.request.target.preview.sha256 else { throw ProjectFailure.invalidProject }
        // A superseded revision must be a real existing saved comment in this
        // project, with the exact same frozen frame. No arbitrary lineage edges.
        if let supersedes {
            let previous = try read(supersedes)
            guard previous.0.request == frame.request, previous.1.png == frame.png, previous.1.width == frame.width, previous.1.height == frame.height, previous.1.actualTime == frame.actualTime, try list().contains(where: { $0.id == supersedes }) else { throw WorkflowFailure.invalid("This frame comment has a newer saved revision. Cancel and reopen the latest entry before revising it.") }
        }
        let folder = try parent.child(record.id.uuidString,create: true)
        try writeExpected(frame.png,name: "frame.png",folder: folder)
        let bytes = try encoder.encode(record)
        guard bytes.count <= 1024*1024 else { throw WorkflowFailure.invalid("This frame comment is too large. Keep the notes and drawing shorter before saving.") }
        try writeExpected(bytes,name: "comment.json",folder: folder)
        try VoiceReviewProvenance.check(frame.request.target,project: project)
        guard try source.voiceHash(movie.lastPathComponent,limit: VoiceMasterByteContract.sourceLimit) == frame.request.target.preview.sha256 else { throw ProjectFailure.invalidProject }
        try parent.checkPath(); try folder.checkPath(); try Task.checkCancellation()
        guard try folder.read("comment.json",limit: 1024*1024) == bytes,
              try folder.read("frame.png",limit: Self.pngLimit) == frame.png else { throw ProjectFailure.invalidProject }
        // Completion is last. Incomplete evidence is never listed as a comment.
        try folder.writeNew(JSONSerialization.data(withJSONObject: ["commentSHA256":TranscriptSourceMap.sha(bytes),"frameSHA256":frame.pngSHA256],options: [.sortedKeys]),name: "completion.json")
        try parent.checkPath(); try folder.checkPath(); return record
    }
    private func samePayload(_ a: SavedFrameComment,_ b: SavedFrameComment) -> Bool {
        a.id == b.id && a.supersedesID == b.supersedesID && a.request == b.request && a.text == b.text &&
        a.annotations == b.annotations && a.framePNG_SHA256 == b.framePNG_SHA256 && a.width == b.width &&
        a.height == b.height && a.actualFrameTime == b.actualFrameTime && a.reviewOnly && !a.productionAuthorized && !a.appliedToVideo
    }
    private func writeExpected(_ bytes: Data,name: String,folder: SourceRenderDirectory) throws {
        var info = stat()
        if fstatat(folder.descriptor,name,&info,AT_SYMLINK_NOFOLLOW) == 0 {
            guard try folder.read(name,limit: Self.pngLimit) == bytes else { throw WorkflowFailure.invalid("An incomplete frame-comment save has conflicting bytes. Cancel this draft and start a new comment; saved history is preserved.") }
        } else {
            guard errno == ENOENT else { throw ProjectFailure.invalidProject }
            try folder.writeNew(bytes,name: name)
        }
    }
    func read(_ id: UUID) throws -> (SavedFrameComment,FrozenReviewFrame) {
        let parent = try root(create: false), folder = try parent.child(id.uuidString)
        let bytes = try folder.read("comment.json",limit: 1024*1024), png = try folder.read("frame.png",limit: Self.pngLimit)
        let completion = try folder.read("completion.json",limit: 4096)
        try TranscriptJSONKeys.validate(bytes); try TranscriptJSONKeys.validate(completion)
        let record = try decoder.decode(SavedFrameComment.self,from: bytes)
        guard record.id == id, record.request.target.projectID == project.id,
              let hashes = try JSONSerialization.jsonObject(with: completion) as? [String:String],
              hashes == ["commentSHA256":TranscriptSourceMap.sha(bytes),"frameSHA256":record.framePNG_SHA256] else { throw ProjectFailure.invalidProject }
        try record.validate(); try validatePNG(png,sha: record.framePNG_SHA256,width: record.width,height: record.height)
        try parent.checkPath(); try folder.checkPath()
        return (record,.init(request: record.request,png: png,pngSHA256: record.framePNG_SHA256,width: record.width,height: record.height,actualTime: record.actualFrameTime))
    }
    func list() throws -> [SavedFrameComment] {
        let projectRoot = try ProjectMutationLease.checkedRoot(project)
        let path = projectRoot.url.appendingPathComponent("notes/frame-comments")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let parent = try root(create: false)
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.url.path)
        guard names.count <= 10_000 else { throw WorkflowFailure.invalid("This project's frame-comment history is too large to load safely.") }
        var records: [SavedFrameComment] = []
        for name in names {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: name) else { continue }
            let folder = try parent.child(name)
            // Ignore only unfinished bundles; refuse corrupt completed history.
            var info = stat()
            guard fstatat(folder.descriptor,"completion.json",&info,AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            records.append(try read(id).0)
        }
        let previous = Set(records.compactMap(\.supersedesID))
        guard records.allSatisfy({ record in record.supersedesID == nil || records.contains(where: { $0.id == record.supersedesID && $0.request == record.request && $0.created <= record.created }) }) else { throw ProjectFailure.invalidProject }
        return records.filter { !previous.contains($0.id) }.sorted { $0.created < $1.created }
    }
}

/// Local project metadata only. No embeddings, face library, network lookup or
/// automatic name association is stored or requested by this repository.
actor ProjectPeopleRepository {
    private struct Envelope: Codable { let sha256: String; let payload: Data }
    let project: Project
    private let encoder: JSONEncoder
    init(project: Project) {
        self.project = project
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
    }
    nonisolated private static func read(_ state: SourceRenderDirectory,projectID: UUID) throws -> ProjectPeopleDocument {
        var info = stat()
        if fstatat(state.descriptor,"people.json",&info,AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ProjectFailure.invalidProject }; return .init(projectID: projectID)
        }
        let bytes = try state.read("people.json",limit: 4*1024*1024); try TranscriptJSONKeys.validate(bytes)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(Envelope.self,from: bytes)
        guard envelope.payload.count <= 3*1024*1024, TranscriptSourceMap.sha(envelope.payload) == envelope.sha256 else { throw ProjectFailure.invalidProject }
        try TranscriptJSONKeys.validate(envelope.payload)
        let value = try decoder.decode(ProjectPeopleDocument.self,from: envelope.payload); try value.validate(project: projectID); return value
    }
    nonisolated private static func document(project: Project) throws -> ProjectPeopleDocument {
        let root = try ProjectMutationLease.checkedRoot(project)
        var info = stat()
        if fstatat(root.descriptor,".clauto",&info,AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ProjectFailure.invalidProject }; try root.checkPath(); return .init(projectID: project.id)
        }
        let state = try root.child(".clauto"), value = try read(state,projectID: project.id)
        try root.checkPath(); try state.checkPath(); return value
    }
    func load() throws -> ProjectPeopleDocument { try Self.document(project: project) }
    nonisolated static func checkReferences(_ references: [ProjectPersonReference],project: Project) throws {
        let value = try document(project: project)
        // An explicit choice may have been renamed or archived while the draft
        // was open. Preserve its known historical ID/label rather than guessing
        // another person or rewriting the user's earlier association.
        for reference in references { try value.validateReference(reference,historical: true) }
    }
    private func mutate(_ change: (inout ProjectPeopleDocument) throws -> Void) throws -> ProjectPeopleDocument {
        let lease = try ProjectMutationLease.acquire(project); defer { withExtendedLifetime(lease) {} }
        let state = try lease.root.child(".clauto"), original = try Self.read(state,projectID: project.id)
        guard original.changes.count < 4096 else { throw WorkflowFailure.invalid("This project's person history is full. Existing names remain saved.") }
        var value = original; try change(&value); try value.validate(project: project.id)
        if value == original { return original }
        let payload = try encoder.encode(value), bytes = try encoder.encode(Envelope(sha256: TranscriptSourceMap.sha(payload),payload: payload))
        guard payload.count <= 3*1024*1024, bytes.count <= 4*1024*1024 else { throw WorkflowFailure.invalid("This project's person history is full. Existing names remain saved.") }
        try lease.root.checkPath(); try state.checkPath(); try Task.checkCancellation()
        try state.replacePointer(bytes,name: "people.json"); try lease.root.checkPath(); try state.checkPath(); return value
    }
    private static func record(_ kind: ProjectPeopleChange.Kind,people: [UUID],previous: String? = nil,name: String? = nil,in value: inout ProjectPeopleDocument) {
        value.revision += 1; value.changes.append(.init(id: UUID(),revision: value.revision,kind: kind,people: people,previousName: previous,name: name,created: Date()))
    }
    func create(name: String,splitFrom source: UUID? = nil) throws -> ProjectPerson {
        let name = ProjectPersonNames.cleaned(name), id = UUID()
        guard ProjectPersonNames.valid(name) else { throw WorkflowFailure.invalid("Use a short name for this person.") }
        let result = try mutate { value in
            guard value.people.count < 512 else { throw WorkflowFailure.invalid("This project already has 512 people. Existing names remain saved.") }
            if let source { guard value.people.contains(where: { $0.id == source && $0.active }) else { throw ProjectFailure.invalidProject } }
            value.people.append(.init(id: id,name: name))
            Self.record(source == nil ? .create:.split,people: source.map { [$0,id] } ?? [id],name: name,in: &value)
        }
        guard let created = result.people.first(where: { $0.id == id }) else { throw ProjectFailure.invalidProject }; return created
    }
    func rename(_ id: UUID,name: String) throws -> ProjectPeopleDocument {
        let name = ProjectPersonNames.cleaned(name)
        guard ProjectPersonNames.valid(name) else { throw WorkflowFailure.invalid("Use a short name for this person.") }
        return try mutate { value in
            guard let i = value.people.firstIndex(where: { $0.id == id && $0.active }) else { throw ProjectFailure.invalidProject }
            let previous = value.people[i].name
            guard previous != name else { return }
            guard value.people[i].previousNames.contains(previous) || value.people[i].previousNames.count < 64 else { throw WorkflowFailure.invalid("This person has reached the name-history limit. The saved name remains unchanged.") }
            if !value.people[i].previousNames.contains(previous) { value.people[i].previousNames.append(previous) }
            value.people[i].name = name; value.people[i].revision += 1
            Self.record(.rename,people: [id],previous: previous,name: name,in: &value)
        }
    }
    func archive(_ id: UUID,archived: Bool) throws -> ProjectPeopleDocument {
        try mutate { value in
            guard let i = value.people.firstIndex(where: { $0.id == id && $0.mergedIntoID == nil }) else { throw ProjectFailure.invalidProject }
            guard value.people[i].archived != archived else { return }
            value.people[i].archived = archived; value.people[i].revision += 1
            Self.record(archived ? .archive:.restore,people: [id],in: &value)
        }
    }
    func merge(_ source: UUID,into destination: UUID) throws -> ProjectPeopleDocument {
        try mutate { value in
            guard source != destination, let i = value.people.firstIndex(where: { $0.id == source && $0.active }),
                  value.people.contains(where: { $0.id == destination && $0.active }) else { throw ProjectFailure.invalidProject }
            value.people[i].archived = true; value.people[i].mergedIntoID = destination; value.people[i].revision += 1
            Self.record(.merge,people: [source,destination],in: &value)
        }
    }
}
