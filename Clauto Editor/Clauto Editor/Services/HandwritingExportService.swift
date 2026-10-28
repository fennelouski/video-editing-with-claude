import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import Darwin

/// Pins the encoder-created leaf for its entire write. Checks accept growth but
/// refuse a different inode, symlink or workspace before output is admitted.
private final class HandwritingEncodedFile: Sendable {
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
/// Writes a real ProRes 4444 movie, one rendered frame at each exact 1001/24000
/// timestamp. The caller owns the exclusive staging folder; publication follows
/// decoded frame/timing/alpha verification and immutable provenance checks.
private actor HandwritingMovieEncoder {
    private var busy = false
    private let movieByteLimit: Int64
    private let freeHeadroom: Int64
    init(movieByteLimit: Int64 = GraphicArtifactFiles.movieLimit,freeHeadroom: Int64 = 32*1024*1024) {
        self.movieByteLimit = max(1,min(movieByteLimit,GraphicArtifactFiles.movieLimit));self.freeHeadroom = max(0,min(freeHeadroom,1024*1024*1024))
    }
    func export(_ scene: GraphicScene,ink: CutoutRaster,recipe: HandwritingRecipe,to folder: SourceRenderDirectory,progress: (@Sendable (Int,Int) async -> Void)? = nil) async throws -> GraphicAnimationOutput {
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
        let encoded = try HandwritingEncodedFile(folder)
        var firstPNG = Data(),finalPNG = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(7200))
        for frame in 0..<scene.frameCount {
            try Task.checkCancellation();guard ContinuousClock.now<deadline else { throw WorkflowFailure.invalid("This graphics export exceeded two hours. Its scene and previous exported revision remain available.") }
            try encoded.check(limit: movieByteLimit)
            let reservedRemaining = Int64(scene.width)*Int64(scene.height)*16*Int64(scene.frameCount-frame)+Int64(scene.frameCount-frame)*4096
            try GraphicMovieBudget.checkSpace(folder,remaining: reservedRemaining,headroom: freeHeadroom)
            let raw = try HandwritingRenderer().render(ink: ink,recipe: recipe,frame: frame)
            let raster = try HandwritingExportService.padded(raw,width: scene.width,height: scene.height)
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

struct HandwritingExportResult: Sendable {
    let folderURL: URL
    let movieURL: URL
    let timelineURL: URL
    let proof: GraphicMovieProof
}

/// A separate alpha layer, with editable paths and the exact approved original
/// alongside it. Source pixels are deterministic; the codec bitstream is not promised.
actor HandwritingExportService {
    private let repository = HandwritingRepository()
    private let encoder = HandwritingMovieEncoder()
    private let verifier = GraphicMovieVerifier()
    static func padded(_ image: CutoutRaster,width: Int,height: Int) throws -> CutoutRaster {
        try image.validate()
        guard width >= image.width,height >= image.height,width*height<=4_100_000 else { throw CutoutFailure.invalidImage }
        if width == image.width && height == image.height { return image }
        var bytes = Data(count: width*height*4)
        let x = (width-image.width)/2,y = (height-image.height)/2
        for row in 0..<image.height {
            if row%64 == 0 { try Task.checkCancellation() }
            let start = ((row+y)*width+x)*4
            bytes.replaceSubrange(start..<(start+image.width*4),with: image.rgba[(row*image.width*4)..<((row+1)*image.width*4)])
        }
        return .init(width: width,height: height,rgba: bytes)
    }
    func export(_ project: Project,document: HandwritingDocument,original: Data,id: UUID = UUID()) async throws -> HandwritingExportResult {
        try Task.checkCancellation()
        let stored = try await repository.load(project,assetID: document.id,revisionID: document.revisionID)
        guard stored.0 == document,stored.1 == original,document.review.status == .approved else { throw HandwritingFailure.invalid("Export the exact saved, approved handwriting revision. Drafts and rejected artwork remain editable.") }
        let source = try CutoutImageIO.decode(original).raster
        let ink = try HandwritingRenderer().extract(source: source,recipe: document.recipe)
        let quality = try HandwritingRenderer().quality(ink: ink,recipe: document.recipe)
        guard quality.unrevealedPixels == 0,quality.boundaryInkPixels == 0 else { throw HandwritingFailure.invalid("Correct unrevealed or clipped ink before exporting.") }
        // This scene supplies only the existing verified movie/FCPXML contract;
        // handwriting pixels are rendered independently, never by a toy model.
        var metadata = GraphicScene.preset(.object)
        metadata.width = max(320,(ink.width+1)/2*2);metadata.height = max(240,(ink.height+1)/2*2)
        metadata.frameCount = document.recipe.frameCount
        let folder = try await repository.prepareExport(project,document: document,id: id)
        try folder.writeNew(original,name: "original.image")
        try folder.writeNew(CutoutImageIO.png(ink),name: "ink.png")
        try folder.writeNew(CreativeAssetFiles.encoder().encode(quality),name: "quality.json")
        let output = try await encoder.export(metadata,ink: ink,recipe: document.recipe,to: folder)
        let proof = try await verifier.verify(folder,scene: metadata,output: output)
        try folder.writeNew(GraphicFinalCutXML.make(scene: metadata,label: document.exactText,movie: output.movieURL),name: "timeline.fcpxml")
        try folder.writeNew(output.firstPNG,name: "first.png");try folder.writeNew(output.finalPNG,name: "final.png")
        try folder.writeNew(CreativeAssetFiles.encoder().encode(proof),name: "export-proof.json")
        let reloaded = try await repository.load(project,assetID: document.id,revisionID: document.revisionID)
        guard reloaded.0 == document,reloaded.1 == original else { throw CutoutFailure.changedSource }
        try Task.checkCancellation();try folder.checkPath()
        try folder.writeNew(Data(HandwritingRecipe.capability.utf8),name: "COMPLETE.txt")
        return .init(folderURL: folder.url,movieURL: output.movieURL,timelineURL: folder.url.appendingPathComponent("timeline.fcpxml"),proof: proof)
    }
}
