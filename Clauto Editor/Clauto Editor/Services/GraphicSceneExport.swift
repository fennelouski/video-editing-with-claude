import Foundation
import CryptoKit
import Darwin
@preconcurrency import AVFoundation
import CoreVideo

struct GraphicFileRecord: Codable,Equatable,Sendable {
    let sha256: String
    let byteCount: Int64
}
enum GraphicArtifactFiles {
    static let executor = GraphicBlockingExecutor(label: "com.clauto.graphics-artifact-io")
    static let movieLimit: Int64 = 16*1024*1024*1024
    static func digest(_ folder: SourceRenderDirectory,name: String,limit: Int64 = movieLimit,check: () throws -> Void = { try Task.checkCancellation() }) throws -> GraphicFileRecord {
        guard CreativeAssetFiles.validLeaf(name),limit>0 else { throw ProjectFailure.invalidProject }
        try folder.checkPath();let fd = openat(folder.descriptor,name,O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else { throw ProjectFailure.invalidProject };defer { close(fd) }
        func signature(_ info: stat) -> [Int64] { [Int64(info.st_dev),Int64(info.st_ino),info.st_size,Int64(info.st_mtimespec.tv_sec),Int64(info.st_mtimespec.tv_nsec),Int64(info.st_ctimespec.tv_sec),Int64(info.st_ctimespec.tv_nsec)] }
        var info = stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_size>0,info.st_size<=limit else { throw WorkflowFailure.invalid("The graphics artifact is missing, replaced or exceeds its size budget.") }
        let before = signature(info);var hash = SHA256(),count: Int64 = 0,buffer = [UInt8](repeating: 0,count: 1024*1024)
        while true {
            try check();let size = Darwin.read(fd,&buffer,buffer.count)
            guard size>=0 else { throw ProjectFailure.invalidProject };if size==0 { break }
            count += Int64(size);guard count<=limit else { throw ProjectFailure.invalidProject };hash.update(data: Data(buffer.prefix(size)))
        }
        let pathFD = openat(folder.descriptor,name,O_RDONLY|O_NOFOLLOW);guard pathFD>=0 else { throw ProjectFailure.invalidProject };defer { close(pathFD) }
        var current = stat()
        guard fstat(fd,&info)==0,fstat(pathFD,&current)==0,signature(info)==before,signature(current)==before,count==info.st_size else { throw CutoutFailure.changedSource }
        try check();try folder.checkPath();return .init(sha256: hash.finalize().map { String(format: "%02x",$0) }.joined(),byteCount: count)
    }
}
struct GraphicMovieProof: Codable,Equatable,Sendable {
    let frameCount: Int
    let width: Int
    let height: Int
    let durationValue: Int64
    let durationScale: Int32
    let codec: String
    let decodedEveryFrame: Bool
    let maximumEndpointAlphaError: Int
    let movie: GraphicFileRecord
}
actor GraphicMovieVerifier {
    private static let executor = GraphicBlockingExecutor(label: "com.clauto.graphics-movie-proof")
    func verify(_ folder: SourceRenderDirectory,scene: GraphicScene,output: GraphicAnimationOutput) async throws -> GraphicMovieProof {
        try scene.validate();guard output.movieURL==folder.url.appendingPathComponent("animation.mov"),output.frames==scene.frameCount,output.durationValue==Int64(scene.frameCount)*1001,output.durationScale==24000,output.codec=="ap4h",CutoutSourceInfo.validHash(output.movie.sha256),output.movie.byteCount>0,output.movie.byteCount<=GraphicArtifactFiles.movieLimit else { throw ProjectFailure.invalidProject }
        let before: GraphicFileRecord = try await GraphicArtifactFiles.executor.perform { job in try GraphicArtifactFiles.digest(folder,name: "animation.mov",check: job.checkCancellation) }
        guard before==output.movie else { throw CutoutFailure.changedSource }
        let asset = SourceMediaVerifier.asset(at: folder.url.appendingPathComponent("animation.mov"))
        let tracks = try await asset.loadTracks(withMediaType: .video),audio = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count==1,audio.isEmpty else { throw ProjectFailure.invalidProject }
        let track = tracks[0],size = try await track.load(.naturalSize),transform = try await track.load(.preferredTransform),duration = try await asset.load(.duration),formats = try await track.load(.formatDescriptions)
        guard Int(size.width)==scene.width,Int(size.height)==scene.height,transform == .identity,
              CMTimeCompare(duration,CMTime(value: Int64(scene.frameCount)*1001,timescale: 24000))==0,
              formats.count==1,CMFormatDescriptionGetMediaSubType(formats[0])==kCMVideoCodecType_AppleProRes4444 else { throw WorkflowFailure.invalid("The encoded graphic does not match its canvas, codec or exact frame duration.") }
        let expectedFirst = try CutoutImageIO.decode(output.firstPNG).raster,expectedLast = try CutoutImageIO.decode(output.finalPNG).raster
        guard expectedFirst.width==scene.width,expectedFirst.height==scene.height,expectedLast.width==scene.width,expectedLast.height==scene.height else { throw ProjectFailure.invalidProject }
        let proof: GraphicMovieProof = try await Self.executor.perform { job in
            let reader = try AVAssetReader(asset: asset),frames = AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            frames.alwaysCopiesSampleData = false;guard reader.canAdd(frames) else { throw ProjectFailure.invalidProject };reader.add(frames)
            guard reader.startReading() else { throw reader.error ?? ProjectFailure.invalidProject };defer { reader.cancelReading() }
            var count = 0,maximumError = 0
            while true {
                try job.checkCancellation();guard let sample = frames.copyNextSampleBuffer() else { break }
                try job.checkCancellation();guard count<scene.frameCount,CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value: Int64(count)*1001,timescale: 24000))==0,
                      let buffer = CMSampleBufferGetImageBuffer(sample),CVPixelBufferGetWidth(buffer)==scene.width,CVPixelBufferGetHeight(buffer)==scene.height else { throw ProjectFailure.invalidProject }
                if count==0 || count==scene.frameCount-1 {
                    let expected = count==0 ? expectedFirst:expectedLast
                    CVPixelBufferLockBaseAddress(buffer,.readOnly);defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
                    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ProjectFailure.invalidProject }
                    let pixels = base.assumingMemoryBound(to: UInt8.self),row = CVPixelBufferGetBytesPerRow(buffer)
                    expected.rgba.withUnsafeBytes { memory in
                        let rgba = memory.bindMemory(to: UInt8.self)
                        for y in 0..<scene.height { for x in 0..<scene.width { maximumError = max(maximumError,abs(Int(pixels[y*row+x*4+3])-Int(rgba[(y*scene.width+x)*4+3]))) } }
                    }
                }
                count += 1
            }
            guard reader.status == .completed,count==scene.frameCount,maximumError<=2 else { throw WorkflowFailure.invalid("The graphics movie did not fully decode with its expected timing and alpha. Its earlier revision remains available.") }
            try job.checkCancellation()
            return .init(frameCount: count,width: scene.width,height: scene.height,durationValue: Int64(count)*1001,durationScale: 24000,codec: "ap4h",decodedEveryFrame: true,maximumEndpointAlphaError: maximumError,movie: before)
        }
        let after: GraphicFileRecord = try await GraphicArtifactFiles.executor.perform { job in try GraphicArtifactFiles.digest(folder,name: "animation.mov",check: job.checkCancellation) }
        guard after==before else { throw CutoutFailure.changedSource };return proof
    }
}
struct GraphicExportRevision: Codable,Equatable,Identifiable,Sendable {
    let schemaVersion: Int
    let id: UUID
    let sceneID: UUID
    let projectID: UUID
    let parentRevisionID: UUID?
    let createdMilliseconds: Int64
    let draftSHA256: String
    let rendererVersion: String
    let metalShaderSHA256: String
    let files: [String:GraphicFileRecord]
    let proof: GraphicMovieProof
    let validationLabel: String
    let assumptions: [String]
}
struct GraphicExportJob: Sendable {
    let id: UUID
    let createdMilliseconds: Int64
    let snapshot: GraphicDraftSnapshot
    let folder: SourceRenderDirectory
    let capturedFiles: [String:GraphicFileRecord]
}
struct GraphicExportResult: Sendable {
    var becameCurrent = true
    let revision: GraphicExportRevision
    let snapshot: GraphicDraftSnapshot
    let movieURL: URL
    let timelineURL: URL
}
enum GraphicFinalCutXML {
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&",with: "&amp;").replacingOccurrences(of: "<",with: "&lt;").replacingOccurrences(of: ">",with: "&gt;").replacingOccurrences(of: "\"",with: "&quot;").replacingOccurrences(of: "'",with: "&apos;") }
    static func make(scene: GraphicScene,label: String,movie: URL) throws -> Data {
        try scene.validate();guard movie.isFileURL else { throw ProjectFailure.invalidProject }
        let duration = "\(Int64(scene.frameCount)*1001)/24000s"
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11"><resources>
        <format id="r1" name="Clauto Graphic" frameDuration="1001/24000s" width="\(scene.width)" height="\(scene.height)" colorSpace="1-13-1"/>
        <asset id="r2" name="\(escape(label))" start="0s" duration="\(duration)" hasVideo="1" format="r1"><media-rep kind="original-media" src="\(escape(movie.absoluteString))"/></asset>
        </resources><library><event name="Clauto Graphics"><project name="\(escape(label))"><sequence format="r1" duration="\(duration)" tcStart="0s" tcFormat="NDF"><spine>
        <gap name="Transparent graphic layer" offset="0s" start="0s" duration="\(duration)"><asset-clip name="\(escape(label))" ref="r2" lane="1" offset="0s" start="0s" duration="\(duration)"/></gap>
        </spine></sequence></project></event></library></fcpxml>
        """.utf8)
    }
}
actor GraphicSceneExportService {
    private let repository: GraphicStudioRepository
    private let exporter = GraphicAnimationExporter()
    private let verifier = GraphicMovieVerifier()
    init(repository: GraphicStudioRepository) { self.repository = repository }
    func export(_ project: Project,snapshot: GraphicDraftSnapshot,id: UUID = UUID(),progress: (@Sendable (Int,Int) async -> Void)? = nil) async throws -> GraphicExportResult {
        try Task.checkCancellation();try snapshot.draft.scene.validate()
        let assets = try await GraphicAssetResolver().resolve(snapshot.draft.scene,project: project)
        let job = try await repository.prepareExport(project,snapshot: snapshot,id: id,assets: assets)
        let output = try await exporter.export(snapshot.draft.scene,assets: assets,to: job.folder,progress: progress)
        let proof = try await verifier.verify(job.folder,scene: snapshot.draft.scene,output: output)
        return try await repository.publishExport(project,job: job,output: output,proof: proof)
    }
}
