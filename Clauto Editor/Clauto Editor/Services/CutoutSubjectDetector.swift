import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Apple Vision runs on its own bounded serial executor, independently of frame
/// capture. Cancellation refuses late publication; Vision's synchronous request
/// may finish before physical executor capacity is released.
actor LocalCutoutSubjectDetector: CutoutSubjectDetecting {
    private static let executor = FrameBlockingExecutor(label: "com.clauto.cutout-subjects",capacity: 2)
    func detect(_ image: CutoutRaster) async throws -> CutoutDetection {
        try await Self.executor.perform(job: FrameBlockingJob<CutoutDetection>()) { job in
            try job.checkCancellation(); try image.validate()
            let request = VNGenerateForegroundInstanceMaskRequest()
            request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
            defer { request.cancel() }
            let handler = VNImageRequestHandler(cgImage: try CutoutImageIO.image(image),orientation: .up,options: [:])
            try handler.perform([request]); try job.checkCancellation()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw CutoutFailure.noSubject }
            let ids = Array(observation.allInstances)
            guard ids.count <= 32, ids.count*image.width*image.height <= 64*1024*1024 else { throw CutoutFailure.unavailable }
            let context = CIContext(options: [.cacheIntermediates:false])
            let bounds = CGRect(x: 0,y: 0,width: image.width,height: image.height)
            var subjects: [CutoutSubject] = []
            for id in ids {
                try job.checkCancellation()
                let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: id),from: handler)
                let ci = CIImage(cvPixelBuffer: buffer)
                guard let mask = context.createCGImage(ci,from: bounds,format: .L8,colorSpace: CGColorSpaceCreateDeviceGray()) else { throw CutoutFailure.invalidMask }
                var bytes = Data(count: image.width*image.height)
                let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
                    guard let bitmap = CGContext(data: storage.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width,
                                                 space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                    bitmap.draw(mask,in: bounds); return true
                }
                guard drawn else { throw CutoutFailure.invalidMask }
                subjects.append(.init(id: id,mask: bytes))
            }
            try job.checkCancellation()
            let result = CutoutDetection(width: image.width,height: image.height,subjects: subjects,model: "Apple Vision foreground instances",modelRevision: VNGenerateForegroundInstanceMaskRequestRevision1)
            try result.validate(); return result
        }
    }
}
