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
    @Test func faintShadowKeepsWarmColorThroughGPUAndOverlayComposition() async throws {
        let color = GraphicColor(r: 74.0/255,g: 60.0/255,b: 46.0/255,a: 0.021)
        let triangle = GraphicPrimitiveGPU.triangle(.init(0,0),.init(64,0),.init(0,64),color: color)
        let raster = try await GraphicMetalRenderer().render([triangle],width: 320,height: 240)
        let scene = GraphicScene(kind: .titleCard,width: 320,height: 240,frameCount: 2)
        let composed = try GraphicFrameCompositor.composite(raster,frame: .init(primitives: [],annotations: []),scene: scene,index: 0,assets: .init())
        let i = (12*320+12)*4
        #expect(composed.rgba==raster.rgba)
        for (channel,expected) in [74,60,46].enumerated() { #expect(abs(Int(composed.rgba[i+channel])-expected)<=1) }
        #expect((4...6).contains(Int(composed.rgba[i+3])))
    }
    private func overBackground(_ image: CutoutRaster,_ rgb: [UInt8]) -> CutoutRaster {
        var bytes = image.rgba
        bytes.withUnsafeMutableBytes { memory in
            let pixels = memory.bindMemory(to: UInt8.self)
            for i in stride(from: 0,to: pixels.count,by: 4) {
                let alpha = Int(pixels[i+3])
                for channel in 0..<3 { pixels[i+channel] = UInt8((Int(pixels[i+channel])*alpha+Int(rgb[channel])*(255-alpha)+127)/255) }
                pixels[i+3] = 255
            }
        }
        return .init(width: image.width,height: image.height,rgba: bytes)
    }
    /// Optional real library proof. The environment opts into disposable output;
    /// regular tests remain self-contained and never discover private projects.
    @MainActor @Test func preparedLibraryPanRendersAndExportsThroughExistingVerifiedContract() async throws {
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
        for frame in [0,scene.frameCount/4/2*2,scene.frameCount/2/2*2,scene.frameCount*3/4/2*2,scene.frameCount-2,scene.frameCount-1] {
            let raster = try await renderer.render(scene,frame: frame),png = try CutoutImageIO.png(raster)
            let repeated = try await GraphicSceneRenderer().render(scene,frame: frame)
            let repeatedPNG = try CutoutImageIO.png(repeated)
            #expect(repeated.rgba==raster.rgba && repeatedPNG==png)
            let name = String(format: "after-%04d.png",frame)
            try png.write(to: root.appendingPathComponent(name),options: .withoutOverwriting)
            hashes[name] = TranscriptSourceMap.sha(png)
            if frame==0 {
                for (suffix,color) in [("oat",[UInt8(232),223,200]),("contrast",[UInt8(64),89,100])] {
                    let displayed = try CutoutImageIO.png(overBackground(raster,color)),name = "after-0000-on-"+suffix+".png"
                    try displayed.write(to: root.appendingPathComponent(name),options: .withoutOverwriting)
                    hashes[name] = TranscriptSourceMap.sha(displayed)
                }
            }
        }
        var legacy = scene;legacy.demoRig = nil;legacy.demoProvenance = nil
        try CutoutImageIO.png(await GraphicSceneRenderer().render(legacy,frame: 0)).write(to: root.appendingPathComponent("same-model-legacy-rig.png"),options: .withoutOverwriting)
        for template in GraphicDemoRig.Template.allCases {
            var variation = scene
            variation.demoRig = .preset(template)
            variation.demoRig!.material = .walnutIron
            variation.demoRig!.seed = request.rig.seed
            let raster = try await GraphicSceneRenderer().render(variation,frame: scene.frameCount/2)
            let name = "template-\(template.rawValue).png",png = try CutoutImageIO.png(raster)
            try png.write(to: root.appendingPathComponent(name),options: .withoutOverwriting)
            hashes[name] = TranscriptSourceMap.sha(png)
        }
        let engine = root.appendingPathComponent("synthetic-engine",isDirectory: true)
        try FileManager.default.createDirectory(at: engine,withIntermediateDirectories: false)
        let project = try await ProjectRepository().create(name: "Synthetic 3D studio proof",root: root,engine: engine)
        let repository = GraphicStudioRepository(),controller = GraphicStudioController(project: project,repository: repository)
        controller.importDemo(URL(fileURLWithPath: input))
        for _ in 0..<2000 { if controller.busy==nil { break };try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.issue==nil)
        let snapshot = try #require(controller.saved)
        #expect(snapshot.draft.scene==scene && snapshot.draft.scene.demoProvenance==request.provenance)
        let result = try await GraphicSceneExportService(repository: repository).export(project,snapshot: snapshot)
        #expect(result.revision.proof.decodedEveryFrame && result.revision.proof.frameCount==scene.frameCount)
        #expect(result.becameCurrent && result.snapshot.draft.currentRevisionID==result.revision.id)
        let current = try await repository.currentExport(project,sceneID: scene.id)
        #expect(current?.revision.id==result.revision.id)
        controller.importDemo(URL(fileURLWithPath: input))
        for _ in 0..<2000 { if controller.busy==nil { break };try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.issue==nil && controller.saved?.draft.currentRevisionID==result.revision.id)
        #expect(try await repository.list(project).count==1)
        #expect(await controller.flushForExit())
        let locations = ["movie":result.movieURL.path,"timeline":result.timelineURL.path,"sceneID":scene.id.uuidString,"revisionID":result.revision.id.uuidString]
        try CreativeAssetFiles.encoder().encode(locations).write(to: root.appendingPathComponent("export-location.json"),options: .withoutOverwriting)
        try Data(contentsOf: URL(fileURLWithPath: input)).write(to: root.appendingPathComponent("prepared.json"),options: .withoutOverwriting)
        try CreativeAssetFiles.encoder().encode(hashes).write(to: root.appendingPathComponent("frame-hashes.json"),options: .withoutOverwriting)
    }
}
