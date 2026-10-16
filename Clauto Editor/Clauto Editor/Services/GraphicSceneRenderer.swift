import Foundation

actor GraphicSceneRenderer {
    private static let compositor = GraphicBlockingExecutor(label: "com.clauto.graphics-compositor")
    private let gpu = GraphicMetalRenderer()
    private var builder: GraphicFrameBuilder?
    func render(_ scene: GraphicScene,frame: Int,assets: GraphicResolvedAssets = .init()) async throws -> CutoutRaster {
        try Task.checkCancellation();try scene.validate()
        if builder?.scene != scene { builder = try GraphicFrameBuilder(scene) }
        let geometry = try builder!.frame(frame)
        let base = try await gpu.render(geometry.primitives,width: scene.width,height: scene.height)
        return try await Self.compositor.perform { job in
            try job.checkCancellation();let result = try GraphicFrameCompositor.composite(base,frame: geometry,scene: scene,index: frame,assets: assets);try job.checkCancellation();return result
        }
    }
}
