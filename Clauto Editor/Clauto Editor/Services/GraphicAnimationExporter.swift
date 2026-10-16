import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import Darwin

/// Pins the encoder-created leaf for its entire write. Checks accept growth but
/// refuse a different inode, symlink or workspace before output is admitted.
private final class GraphicEncodedFile: Sendable {
    let folder: SourceRenderDirectory
    let descriptor: Int32
    let device: dev_t
    let inode: ino_t
    init(_ folder: SourceRenderDirectory) throws {
        self.folder = folder
        let fd = openat(folder.descriptor,"animation.mov",O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else { throw ProjectFailure.invalidProject }
        var info = stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG else { close(fd);throw ProjectFailure.invalidProject }
        descriptor = fd;device = info.st_dev;inode = info.st_ino
        try check(limit: GraphicArtifactFiles.movieLimit)
    }
    deinit { close(descriptor) }
    func check(limit: Int64) throws {
        try folder.checkPath();var info = stat(),current = stat()
        guard fstat(descriptor,&info)==0,fstatat(folder.descriptor,"animation.mov",&current,AT_SYMLINK_NOFOLLOW)==0,
              info.st_mode&S_IFMT==S_IFREG,current.st_mode&S_IFMT==S_IFREG,info.st_dev==device,info.st_ino==inode,current.st_dev==device,current.st_ino==inode,
              info.st_size>=0,info.st_size<=limit else { throw WorkflowFailure.invalid("The graphics movie changed or exceeded its output budget. Its saved inputs and previous revision remain available.") }
    }
    func digest(limit: Int64,checkCancellation: () throws -> Void) throws -> GraphicFileRecord {
        try check(limit: limit);let result = try GraphicArtifactFiles.digest(folder,name: "animation.mov",limit: limit,check: checkCancellation);try check(limit: limit);return result
    }
}
enum GraphicMovieBudget {
    /// Conservative admission, charged before encoding rather than assuming a
    /// particular compression ratio. Checked arithmetic remains far below Int64.
    static func plannedBytes(_ scene: GraphicScene) throws -> Int64 {
        try scene.validate();return Int64(scene.width)*Int64(scene.height)*16*Int64(scene.frameCount)+Int64(scene.frameCount)*4096+2*1024*1024
    }
    static func checkSpace(_ folder: SourceRenderDirectory,remaining: Int64,headroom: Int64) throws {
        let total = remaining.addingReportingOverflow(headroom)
        var volume = statfs();guard remaining>=0,headroom>=0,!total.overflow,fstatfs(folder.descriptor,&volume)==0,Double(volume.f_bavail)*Double(volume.f_bsize)>=Double(total.partialValue) else {
            throw WorkflowFailure.invalid("This drive does not have enough available space for this graphic. Its inputs are saved; free space or choose a smaller canvas/duration and retry.")
        }
    }
}
struct GraphicAnimationOutput: Sendable {
    let movieURL: URL
    let movie: GraphicFileRecord
    let firstPNG: Data
    let finalPNG: Data
    let frames: Int
    let durationValue: Int64
    let durationScale: Int32
    let codec: String
}
/// Writes a real ProRes 4444 movie, one rendered frame at each exact 1001/24000
/// timestamp. The caller owns the exclusive staging folder; publication follows
/// decoded frame/timing/alpha verification and immutable provenance checks.
actor GraphicAnimationExporter {
    private var busy = false
    private let movieByteLimit: Int64
    private let freeHeadroom: Int64
    init(movieByteLimit: Int64 = GraphicArtifactFiles.movieLimit,freeHeadroom: Int64 = 32*1024*1024) {
        self.movieByteLimit = max(1,min(movieByteLimit,GraphicArtifactFiles.movieLimit));self.freeHeadroom = max(0,min(freeHeadroom,1024*1024*1024))
    }
    func export(_ scene: GraphicScene,assets: GraphicResolvedAssets,to folder: SourceRenderDirectory,progress: (@Sendable (Int,Int) async -> Void)? = nil) async throws -> GraphicAnimationOutput {
        try Task.checkCancellation();try scene.validate()
        guard !busy else { throw WorkflowFailure.invalid("This graphics exporter is already writing a scene.") }
        busy = true;defer { busy = false }
        try folder.checkPath();let planned = try GraphicMovieBudget.plannedBytes(scene)
        guard planned<=movieByteLimit else { throw WorkflowFailure.invalid("This canvas and duration exceed the graphic's conservative output budget. Its inputs are saved; choose a smaller canvas or shorter animation and retry.") }
        try GraphicMovieBudget.checkSpace(folder,remaining: planned,headroom: freeHeadroom)
        guard !(try CreativeAssetFiles.exists("animation.mov",in: folder)) else { throw ProjectFailure.invalidProject }
        let url = folder.url.appendingPathComponent("animation.mov"),writer = try AVAssetWriter(outputURL: url,fileType: .mov)
        writer.movieTimeScale = 24000
        let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey:AVVideoCodecType.proRes4444,AVVideoWidthKey:scene.width,AVVideoHeightKey:scene.height,AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_IEC_sRGB,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2],AVVideoCompressionPropertiesKey:[AVVideoExpectedSourceFrameRateKey:24000.0/1001.0]])
        input.expectsMediaDataInRealTime = false;input.mediaTimeScale = 24000
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:scene.width,kCVPixelBufferHeightKey as String:scene.height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        guard writer.canAdd(input) else { throw WorkflowFailure.invalid("This Mac cannot encode the requested ProRes alpha scene.") }
        writer.add(input);guard writer.startWriting() else { throw writer.error ?? ProjectFailure.invalidProject };writer.startSession(atSourceTime: .zero)
        var submitted = 0
        do {
        let encoded = try GraphicEncodedFile(folder)
        let renderer = GraphicSceneRenderer();var firstPNG = Data(),finalPNG = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(7200))
        for frame in 0..<scene.frameCount {
            try Task.checkCancellation();guard ContinuousClock.now<deadline else { throw WorkflowFailure.invalid("This graphics export exceeded two hours. Its scene and previous exported revision remain available.") }
            try encoded.check(limit: movieByteLimit)
            let reservedRemaining = Int64(scene.width)*Int64(scene.height)*16*Int64(scene.frameCount-frame)+Int64(scene.frameCount-frame)*4096
            try GraphicMovieBudget.checkSpace(folder,remaining: reservedRemaining,headroom: freeHeadroom)
            let raster = try await renderer.render(scene,frame: frame,assets: assets)
            if frame==0 { firstPNG = try CutoutImageIO.png(raster) };if frame==scene.frameCount-1 { finalPNG = try CutoutImageIO.png(raster) }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation();guard writer.status == .writing,ContinuousClock.now<deadline else { throw writer.error ?? ProjectFailure.invalidProject };try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adapter.pixelBufferPool else { throw ProjectFailure.invalidProject }
            var value: CVPixelBuffer?;guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&value)==kCVReturnSuccess,let buffer = value else { throw ProjectFailure.invalidProject }
            CVBufferSetAttachment(buffer,kCVImageBufferAlphaChannelModeKey,kCVImageBufferAlphaChannelMode_StraightAlpha,.shouldPropagate)
            CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
            CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,.shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer,[])
            guard let destination = CVPixelBufferGetBaseAddress(buffer) else { CVPixelBufferUnlockBaseAddress(buffer,[]);throw ProjectFailure.invalidProject }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            // ProRes 4444 accepts BGRA with straight alpha; do not drop the
            // transparency or premultiply the RGB a second time.
            raster.rgba.withUnsafeBytes { memory in
                let source = memory.bindMemory(to: UInt8.self),target = destination.assumingMemoryBound(to: UInt8.self)
                for y in 0..<scene.height { for x in 0..<scene.width {
                    let a = (y*scene.width+x)*4,b = y*stride+x*4
                    target[b] = source[a+2];target[b+1] = source[a+1];target[b+2] = source[a];target[b+3] = source[a+3]
                } }
            }
            CVPixelBufferUnlockBaseAddress(buffer,[])
            let pts = CMTime(value: Int64(frame)*1001,timescale: 24000)
            guard adapter.append(buffer,withPresentationTime: pts) else { throw writer.error ?? ProjectFailure.invalidProject }
            submitted = frame+1
            try encoded.check(limit: movieByteLimit)
            if let progress { await progress(frame+1,scene.frameCount) }
        }
        input.markAsFinished();writer.endSession(atSourceTime: CMTime(value: Int64(scene.frameCount)*1001,timescale: 24000))
        await writer.finishWriting();try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? ProjectFailure.invalidProject }
        try folder.checkPath();let limit = movieByteLimit
        let movie: GraphicFileRecord = try await GraphicArtifactFiles.executor.perform { job in try encoded.digest(limit: limit,checkCancellation: job.checkCancellation) }
        try Task.checkCancellation()
        return .init(movieURL: url,movie: movie,firstPNG: firstPNG,finalPNG: finalPNG,frames: scene.frameCount,durationValue: Int64(scene.frameCount)*1001,durationScale: 24000,codec: "ap4h")
        } catch {
            // cancelWriting deletes by its original URL. If a folder was moved
            // and replaced, that cleanup could remove somebody else's file.
            // Drain only already submitted frames, retain owned evidence and
            // never request pathname deletion during cancellation/error cleanup.
            if writer.status == .writing {
                input.markAsFinished()
                if submitted>0 { writer.endSession(atSourceTime: CMTime(value: Int64(submitted)*1001,timescale: 24000)) }
                await writer.finishWriting()
            }
            throw error
        }
    }
}
