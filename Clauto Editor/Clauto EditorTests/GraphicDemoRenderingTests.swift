import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@Suite(.serialized) struct GraphicDemoRenderingTests {
    @Test func craftActionsRepeatOnPairsAndRandomAccessMatchesSequentialPreview() async throws {
        var scene = GraphicScene.preset(.object);scene.width = 640;scene.height = 360;scene.frameCount = 24
        let renderer = GraphicSceneRenderer()
        let first = try await renderer.render(scene,frame: 0)
        #expect(try await renderer.render(scene,frame: 1).rgba==first.rgba)
        let next = try await renderer.render(scene,frame: 2)
        #expect(next.rgba != first.rgba)
        _ = try await renderer.render(scene,frame: 20)
        #expect(try await renderer.render(scene,frame: 2).rgba==next.rgba)
        #expect(try await GraphicSceneRenderer().render(scene,frame: 0).rgba==first.rgba)
        #expect(first.rgba[3]==0)
    }
    @Test func normalizedCameraIgnoresSourceOffsetAndUnits() throws {
        var scene = GraphicScene.preset(.object);scene.frameCount = 24
        var before = try GraphicFrameBuilder(scene)
        let first = try before.frame(12).primitives
        for i in scene.object!.vertices.indices {
            scene.object!.vertices[i].x = scene.object!.vertices[i].x*3+100
            scene.object!.vertices[i].y = scene.object!.vertices[i].y*3-200
            scene.object!.vertices[i].z = scene.object!.vertices[i].z*3+300
        }
        var after = try GraphicFrameBuilder(scene)
        let second = try after.frame(12).primitives
        #expect(first.count==second.count)
        for (a,b) in zip(first,second) { #expect(a.a==b.a && a.b==b.b && a.color==b.color && a.tags==b.tags) }
    }
    @Test func translucentContactShadowDoesNotDisableOpaqueMeshDepth() async throws {
        let shadow = GraphicPrimitiveGPU.triangle(.init(0,0),.init(64,0),.init(0,64),color: .init(r: 0.3,g: 0.2,b: 0.1,a: 0.2))
        let red = GraphicPrimitiveGPU.triangle(.init(4,4),.init(60,4),.init(4,60),color: .init(r: 1,g: 0,b: 0),depth: .init(0.1,0.9,0.1))
        let blue = GraphicPrimitiveGPU.triangle(.init(4,4),.init(60,4),.init(4,60),color: .init(r: 0,g: 0,b: 1),depth: .init(repeating: 0.5))
        let renderer = GraphicMetalRenderer(),a = try await renderer.render([shadow,red,blue],width: 64,height: 64)
        let b = try await renderer.render([shadow,blue,red],width: 64,height: 64)
        #expect(a.rgba==b.rgba)
    }
    /// Optional real library proof. The environment opts into disposable output;
    /// regular tests remain self-contained and never discover private projects.
    @Test func preparedLibraryPanRendersAndExportsThroughExistingVerifiedContract() async throws {
        guard let input = ProcessInfo.processInfo.environment["CLAUTO_DEMO_PREPARED"],
              let destination = ProcessInfo.processInfo.environment["CLAUTO_DEMO_PROOF"] else { return }
        let request = try GraphicDemoRequest.decode(Data(contentsOf: URL(fileURLWithPath: input)))
        let scene = try request.scene(),root = URL(fileURLWithPath: destination,isDirectory: true)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false)
        var geometry = try GraphicFrameBuilder(scene)
        for frame in stride(from: 0,to: scene.frameCount,by: 2) {
            for shape in try geometry.frame(frame).primitives {
                let x = [shape.a.x,shape.a.z,shape.b.x],y = [shape.a.y,shape.a.w,shape.b.y]
                #expect(x.allSatisfy { $0>=Float(scene.width)*0.06 && $0<=Float(scene.width)*0.94 })
                #expect(y.allSatisfy { $0>=Float(scene.height)*0.06 && $0<=Float(scene.height)*0.77 })
            }
        }
        let renderer = GraphicSceneRenderer()
        var hashes: [String:String] = [:]
        for frame in [0,scene.frameCount/2/2*2,scene.frameCount-2,scene.frameCount-1] {
            let raster = try await renderer.render(scene,frame: frame),png = try CutoutImageIO.png(raster)
            #expect(try await GraphicSceneRenderer().render(scene,frame: frame).rgba==raster.rgba)
            let name = String(format: "after-%04d.png",frame)
            try png.write(to: root.appendingPathComponent(name),options: .withoutOverwriting)
            hashes[name] = TranscriptSourceMap.sha(png)
        }
        var legacy = scene;legacy.demoRig = nil;legacy.demoProvenance = nil
        try CutoutImageIO.png(await GraphicSceneRenderer().render(legacy,frame: 0)).write(to: root.appendingPathComponent("same-model-legacy-rig.png"),options: .withoutOverwriting)
        let movie = root.appendingPathComponent("export",isDirectory: true)
        try FileManager.default.createDirectory(at: movie,withIntermediateDirectories: false)
        let output = try await GraphicAnimationExporter().export(scene,assets: .init(),to: SourceRenderDirectory.open(movie))
        let proof = try await GraphicMovieVerifier().verify(SourceRenderDirectory.open(movie),scene: scene,output: output)
        #expect(proof.decodedEveryFrame && proof.frameCount==scene.frameCount)
        try CreativeAssetFiles.encoder().encode(proof).write(to: movie.appendingPathComponent("decode-proof.json"),options: .withoutOverwriting)
        try GraphicFinalCutXML.make(scene: scene,label: request.label,movie: output.movieURL).write(to: movie.appendingPathComponent("timeline.fcpxml"),options: .withoutOverwriting)
        try Data(contentsOf: URL(fileURLWithPath: input)).write(to: root.appendingPathComponent("prepared.json"),options: .withoutOverwriting)
        try CreativeAssetFiles.encoder().encode(hashes).write(to: root.appendingPathComponent("frame-hashes.json"),options: .withoutOverwriting)
    }
}
