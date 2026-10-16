import Foundation

struct GraphicLayerTransform: Codable,Equatable,Sendable {
    var x = 0.5
    var y = 0.4
    var width = 0.3
    var height = 0.3
    var rotationDegrees = 0.0
    var opacity = 1.0
    var startFrame = 0
    var endFrame: Int?
    func validate(frameCount: Int) throws {
        guard [x,y,width,height,rotationDegrees,opacity].allSatisfy(\.isFinite),(-1...2).contains(x),(-1...2).contains(y),
              (0.001...3).contains(width),(0.001...3).contains(height),abs(rotationDegrees)<=3600,(0...1).contains(opacity),
              startFrame>=0,startFrame<frameCount,endFrame.map({ $0>startFrame && $0<=frameCount }) ?? true else { throw WorkflowFailure.invalid("Choose a valid layer position, size, opacity and frame range.") }
    }
    func active(_ frame: Int) -> Bool { frame>=startFrame && (endFrame.map { frame<$0 } ?? true) }
}
struct GraphicImageLayer: Codable,Equatable,Identifiable,Sendable {
    var id = UUID()
    var cutoutID: UUID
    var revisionID: UUID
    var imageSHA256: String
    var transform = GraphicLayerTransform()
}
struct GraphicFontReference: Codable,Equatable,Sendable {
    var fontID: UUID
    var revisionID: UUID
    var ttfSHA256: String
}
struct GraphicTextLayer: Codable,Equatable,Identifiable,Sendable {
    var id = UUID()
    var text: String
    var font: GraphicFontReference?
    var fontSize = 0.08
    var color = GraphicColor.sage
    var transform = GraphicLayerTransform()
}
struct GraphicResolvedAssets: Sendable {
    var images: [UUID:CutoutRaster] = [:]
    var fonts: [UUID:Data] = [:]
    /// These exact inputs accompany every exported scene revision.
    var files: [String:Data] = [:]
}
