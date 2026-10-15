import Foundation
import CoreGraphics

struct ReviewClockTime: Codable, Equatable, Sendable {
    let value: Int64
    let timescale: Int32
}
struct ReviewFrameAnchor: Codable, Equatable, Sendable {
    let clock: ReviewClockTime
    let frameIndex: Int
    let frameCount: Int
    var presentationValue: Int64 { Int64(frameIndex)*1001 }
    var presentationTimescale: Int32 { 24000 }
    var seconds: Double { Double(presentationValue)/24000 }
    static func capture(_ clock: ReviewClockTime, duration: Double) throws -> Self {
        let count = duration*24000/1001
        guard clock.value >= 0, clock.timescale > 0, count.isFinite, count >= 1, count <= 86_400,
              abs(count-count.rounded()) < 0.002 else { throw WorkflowFailure.invalid("Choose a ready saved 24000/1001 version before adding a frame comment.") }
        let (numerator,overflow) = clock.value.multipliedReportingOverflow(by: 24000)
        guard !overflow else { throw ProjectFailure.invalidProject }
        let denominator = Int64(clock.timescale)*1001, frames = Int(count.rounded())
        let at = Double(clock.value)/Double(clock.timescale)
        guard at.isFinite, at <= duration+0.001 else { throw WorkflowFailure.invalid("The playback clock is outside the selected saved version.") }
        return .init(clock: clock,frameIndex: min(frames-1,Int(numerator/denominator)),frameCount: frames)
    }
    func validate(duration: Double) throws {
        guard try Self.capture(clock,duration: duration) == self else { throw ProjectFailure.invalidProject }
    }
}
struct FrameCommentRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let target: VoiceReviewTarget
    let frame: ReviewFrameAnchor
}
struct NormalizedVideoRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    func validate() throws {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x+width <= 1.000000001, y+height <= 1.000000001 else { throw WorkflowFailure.invalid("Draw inside the video or enter finite bounds between zero and one.") }
    }
}
enum FrameAnnotationKind: String, Codable, CaseIterable, Sendable {
    case ellipse, circle, highlight, freehand
    var label: String { switch self { case .ellipse: "Ellipse"; case .circle: "Circle"; case .highlight: "Highlight"; case .freehand: "Draw" } }
}
struct NormalizedVideoPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { throw ProjectFailure.invalidProject }
    }
}
/// A closed drawing is still a drag. Final displacement alone loses loops.
struct FrameMarkGesture: Sendable {
    let start: CGPoint
    private(set) var moved = false
    mutating func observe(_ point: CGPoint) {
        if !point.x.isFinite || !point.y.isFinite || hypot(point.x-start.x,point.y-start.y) >= 3 { moved = true }
    }
    var isClick: Bool { !moved }
}
struct FrameEllipse: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: FrameAnnotationKind
    let bounds: NormalizedVideoRect
    var points: [NormalizedVideoPoint]? = nil
    var tag: String? = nil
    var note: String? = nil
    func validate(width: Int, height: Int) throws {
        try bounds.validate()
        guard width > 0, height > 0, bounds.width*Double(width) >= 1, bounds.height*Double(height) >= 1,
              kind != .circle || abs(bounds.width*Double(width)-bounds.height*Double(height)) <= 0.01 else { throw WorkflowFailure.invalid("A circle must have equal width and height in the captured video, with at least one pixel on each axis.") }
        if kind == .freehand {
            guard let points, (2...512).contains(points.count) else { throw WorkflowFailure.invalid("A drawing needs between two and 512 points.") }
            for point in points {
                try point.validate()
                guard point.x >= bounds.x-1e-9, point.y >= bounds.y-1e-9,
                      point.x <= bounds.x+bounds.width+1e-9, point.y <= bounds.y+bounds.height+1e-9 else { throw ProjectFailure.invalidProject }
            }
        } else if points != nil { throw ProjectFailure.invalidProject }
        if let tag { guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tag.utf8.count <= 160,
            !tag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw WorkflowFailure.invalid("Use a short label for this region.") } }
        if let note { guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.utf8.count <= 4096 else { throw WorkflowFailure.invalid("A region note must contain up to 4096 UTF-8 bytes.") } }
    }
}
enum VideoAnnotationGeometry {
    static func normalize(_ point: CGPoint,video: CGRect) -> NormalizedVideoPoint? {
        guard point.x.isFinite, point.y.isFinite, [video.minX,video.minY,video.width,video.height].allSatisfy(\.isFinite), video.width > 0, video.height > 0 else { return nil }
        return .init(x: min(1,max(0,(point.x-video.minX)/video.width)),y: min(1,max(0,(point.y-video.minY)/video.height)))
    }
    static func stroke(_ points: [CGPoint],video: CGRect,image: CGSize,id: UUID = UUID()) -> FrameEllipse? {
        guard (2...512).contains(points.count), let first = points.first, video.contains(first),
              [image.width,image.height].allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= 7680 }) else { return nil }
        let normalized = points.compactMap { normalize($0,video: video) }
        guard normalized.count == points.count else { return nil }
        let minX = normalized.map(\.x).min()!, maxX = normalized.map(\.x).max()!, minY = normalized.map(\.y).min()!, maxY = normalized.map(\.y).max()!
        let w = max(1/image.width,maxX-minX), h = max(1/image.height,maxY-minY)
        let bounds = NormalizedVideoRect(x: min(minX,1-w),y: min(minY,1-h),width: w,height: h)
        let result = FrameEllipse(id: id,kind: .freehand,bounds: bounds,points: normalized)
        guard (try? result.validate(width: Int(image.width),height: Int(image.height))) != nil else { return nil }
        return result
    }
    static func pin(at point: CGPoint,video: CGRect) -> NormalizedVideoRect? {
        guard video.contains(point), let center = normalize(point,video: video) else { return nil }
        let diameter = min(video.width,video.height)*0.06, w = diameter/video.width, h = diameter/video.height
        return .init(x: min(1-w,max(0,center.x-w/2)),y: min(1-h,max(0,center.y-h/2)),width: w,height: h)
    }
    static func videoRect(image: CGSize, canvas: CGRect) -> CGRect? {
        guard image.width.isFinite, image.height.isFinite, image.width > 0, image.height > 0,
              canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return nil }
        let scale = min(canvas.width/image.width,canvas.height/image.height)
        let size = CGSize(width: image.width*scale,height: image.height*scale)
        return CGRect(x: canvas.midX-size.width/2,y: canvas.midY-size.height/2,width: size.width,height: size.height)
    }
    static func display(_ rect: NormalizedVideoRect, video: CGRect) -> CGRect {
        CGRect(x: video.minX+rect.x*video.width,y: video.minY+rect.y*video.height,width: rect.width*video.width,height: rect.height*video.height)
    }
    static func drawn(from start: CGPoint, to end: CGPoint, kind: FrameAnnotationKind, video: CGRect) -> NormalizedVideoRect? {
        guard video.width > 0, video.height > 0, video.contains(start), [start.x,start.y,end.x,end.y].allSatisfy(\.isFinite) else { return nil }
        var finish = CGPoint(x: min(video.maxX,max(video.minX,end.x)),y: min(video.maxY,max(video.minY,end.y)))
        if kind == .circle {
            let side = min(abs(finish.x-start.x),abs(finish.y-start.y))
            finish = CGPoint(x: start.x+(finish.x<start.x ? -side:side),y: start.y+(finish.y<start.y ? -side:side))
        }
        let rect = NormalizedVideoRect(x: (min(start.x,finish.x)-video.minX)/video.width,y: (min(start.y,finish.y)-video.minY)/video.height,width: abs(finish.x-start.x)/video.width,height: abs(finish.y-start.y)/video.height)
        guard (try? rect.validate()) != nil else { return nil }; return rect
    }
}
struct FrameAnnotationHistory: Sendable {
    private(set) var shapes: [FrameEllipse] = []
    private var undoStates: [[FrameEllipse]] = []
    private var redoStates: [[FrameEllipse]] = []
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    init(shapes: [FrameEllipse] = []) { self.shapes = shapes }
    mutating func replace(_ next: [FrameEllipse]) throws {
        guard next.count <= 32, Set(next.map(\.id)).count == next.count else { throw WorkflowFailure.invalid("A frame comment supports at most 32 unique marks.") }
        guard next != shapes else { return }
        undoStates.append(shapes); if undoStates.count > 100 { undoStates.removeFirst() }; redoStates = []; shapes = next
    }
    mutating func add(_ shape: FrameEllipse) throws { try replace(shapes+[shape]) }
    mutating func remove(_ id: UUID) throws { try replace(shapes.filter { $0.id != id }) }
    mutating func undo() { if let previous = undoStates.popLast() { redoStates.append(shapes); shapes = previous } }
    mutating func redo() { if let next = redoStates.popLast() { undoStates.append(shapes); shapes = next } }
}
struct FrozenReviewFrame: Sendable {
    let request: FrameCommentRequest
    let png: Data
    let pngSHA256: String
    let width: Int
    let height: Int
    let actualTime: ReviewClockTime
}
struct SavedFrameComment: Codable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let supersedesID: UUID?
    let request: FrameCommentRequest
    let text: String
    let annotations: [FrameEllipse]
    let framePNG_SHA256: String
    let width: Int
    let height: Int
    let actualFrameTime: ReviewClockTime
    let created: Date
    let reviewOnly: Bool
    let productionAuthorized: Bool
    let appliedToVideo: Bool
    func validate() throws {
        try request.frame.validate(duration: request.target.duration)
        guard schemaVersion == 1, id != supersedesID, (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || annotations.contains { $0.note != nil }), text.utf8.count <= 16_384,
              annotations.count <= 32, Set(annotations.map(\.id)).count == annotations.count,
              width > 0, height > 0, width <= 7680, height <= 7680, width*height <= 33_177_600,
              actualFrameTime == ReviewClockTime(value: request.frame.presentationValue,timescale: 24000), TranscriptCatalog.isSHA(framePNG_SHA256), reviewOnly, !productionAuthorized, !appliedToVideo else { throw ProjectFailure.invalidProject }
        for shape in annotations { try shape.validate(width: width,height: height) }
    }
}
