import Foundation
import Testing
import AVFoundation
import CoreVideo
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@Suite(.serialized) struct GraphicStudioTests {
    @Test func headlessMetalActuallyRendersTransparentAntialiasedPixelsAndRepeatsDeterministically() async throws {
        let renderer = GraphicMetalRenderer(), color = GraphicColor(r: 1,g: 0,b: 0)
        let shapes: [GraphicPrimitiveGPU] = [.circle(x: 31.5,y: 31.5,radius: 15.25,color: color)]
        let image = try await renderer.render(shapes,width: 64,height: 64)
        #expect(image.width==64 && image.height==64 && image.rgba.count==16384)
        #expect(image.rgba[(31*64+31)*4]==255 && image.rgba[(31*64+31)*4+3]==255 && image.rgba[3]==0)
        #expect(stride(from: 3,to: image.rgba.count,by: 4).contains { image.rgba[$0]>0 && image.rgba[$0]<255 })
        #expect(try await renderer.render(shapes,width: 64,height: 64).rgba == image.rgba)
        let png = try CutoutImageIO.png(image), decoded = try CutoutImageIO.decode(png)
        #expect(decoded.raster.rgba[(31*64+31)*4+3]==255 && decoded.raster.rgba[3]==0)
        if let path = ProcessInfo.processInfo.environment["CLAUTO_GRAPHICS_GPU_SYNTHETIC_OUTPUT"] {
            let folder = URL(fileURLWithPath: path,isDirectory: true)
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("metal-circle-alpha.png"),options: .withoutOverwriting)
        }
    }
    @Test func headlessMetalComposesStraightAlphaInAuthoredOrder() async throws {
        let shapes: [GraphicPrimitiveGPU] = [.circle(x: 32,y: 32,radius: 20,color: .init(r: 1,g: 0,b: 0)),
                                             .circle(x: 32,y: 32,radius: 12,color: .init(r: 0,g: 0,b: 1,a: 0.5))]
        let image = try await GraphicMetalRenderer().render(shapes,width: 64,height: 64)
        let i = (32*64+32)*4
        #expect(abs(Int(image.rgba[i])-128)<=1 && image.rgba[i+1]==0 && abs(Int(image.rgba[i+2])-128)<=1 && image.rgba[i+3]==255)
        #expect(image.rgba[(32*64+49)*4]==255 && image.rgba[(32*64+49)*4+2]==0)
    }
    @Test func typedReactionBalanceAndAnalyticMarketBoundsAreExplicit() throws {
        let water = ReactionGraphicModel(reactants: [.init(coefficient: 2,atoms: ["H":2]),.init(coefficient: 1,atoms: ["O":2])],products: [.init(coefficient: 2,atoms: ["H":2,"O":1])])
        try water.validate();var wrong = water;wrong.products[0].coefficient=1
        #expect(throws: (any Error).self) { try wrong.validate() }
        let market = LinearMarketGraphicModel();let result = try market.equilibrium(at: 0)
        #expect(result.quantity==6 && result.price==4)
        var invalid = market;invalid.demandSlope = .nan
        #expect(throws: (any Error).self) { try invalid.validate() }
        let scene = GraphicScene(kind: .atom,atom: .init())
        #expect(scene.validationLabel.contains("not a quantum simulation"));try scene.validate()
        var missing = scene;missing.atom = nil
        #expect(throws: (any Error).self) { try missing.validate() }
    }
    @Test func malformedGPUInputAndPrecancelledJobsCannotReturnAFrame() async throws {
        let renderer = GraphicMetalRenderer(), invalid = GraphicPrimitiveGPU(a: .init(.nan,0,1,0),b: .zero,color: .init(1,1,1,1),tags: .zero)
        await #expect(throws: (any Error).self) { _ = try await renderer.render([invalid],width: 64,height: 64) }
        let task = Task { try Task.checkCancellation(); return try await renderer.render([],width: 64,height: 64) }
        task.cancel();await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test func deterministicIdealDiskTrajectoryConservesElasticEnergyAndDissipatesInelasticEnergy() throws {
        var model = ParticleGraphicModel();model.count = 16;model.speed = 1.5
        var a = try GraphicParticleSimulation(model),b = try GraphicParticleSimulation(model)
        let energy = a.kineticEnergy
        for _ in 0..<240 { try a.advance();try b.advance() }
        #expect(a.particles==b.particles && abs(a.kineticEnergy-energy)<1e-8)
        #expect(a.particles.allSatisfy { $0.x>=model.radius && $0.x<=model.width-model.radius && $0.y>=model.radius && $0.y<=model.height-model.radius && [$0.x,$0.y,$0.vx,$0.vy].allSatisfy(\.isFinite) })
        model.restitution = 0.6;var dissipative = try GraphicParticleSimulation(model)
        for _ in 0..<240 { try dissipative.advance() }
        #expect(dissipative.kineticEnergy<energy)
    }
    @Test func boundedOBJImportsRealGeometryWithoutLoadingMaterialReferences() throws {
        let bytes = Data("v -1 -1 0\nv 1 -1 0\nv 1 1 0\nv -1 1 0\nf 1 2 3 4\n".utf8)
        let mesh = try GraphicMeshImport.parseOBJ(bytes)
        #expect(mesh.vertices.count==4 && mesh.triangles==[[0,1,2],[0,2,3]])
        #expect(throws: (any Error).self) { _ = try GraphicMeshImport.parseOBJ(Data("mtllib https://example.invalid/private\n".utf8)) }
        #expect(throws: (any Error).self) { _ = try GraphicMeshImport.parseOBJ(Data("v nan 0 0\nf 1 2 3".utf8)) }
    }
    @Test func allSixTypedModelsProduceActualHeadlessFramesWithVisibleFooterAndTransparentSpace() async throws {
        let water = MolecularGraphicModel(atoms: [.init(id: 1,element: "O",position: .init(x: 0,y: 0),radius: 0.4,color: .sage),.init(id: 2,element: "H",position: .init(x: -1,y: 1),radius: 0.24,color: .oat),.init(id: 3,element: "H",position: .init(x: 1,y: 1),radius: 0.24,color: .oat)],bonds: [.init(first: 1,second: 2),.init(first: 1,second: 3)])
        let reaction = ReactionGraphicModel(reactants: [.init(coefficient: 2,atoms: ["H":2]),.init(coefficient: 1,atoms: ["O":2])],products: [.init(coefficient: 2,atoms: ["H":2,"O":1])])
        let scenes = [GraphicScene(kind: .particles,particles: .init()),GraphicScene(kind: .molecule,molecule: water),GraphicScene(kind: .atom,atom: .init()),GraphicScene(kind: .reaction,reaction: reaction),GraphicScene(kind: .object,object: .cube),GraphicScene(kind: .market,market: .init())]
        let renderer = GraphicSceneRenderer()
        for var scene in scenes {
            scene.width = 640;scene.height = 360;scene.frameCount = 24
            let first = try await renderer.render(scene,frame: 0),last = try await renderer.render(scene,frame: 23)
            #expect(first.rgba[3]==0)
            let footer = (340*scene.width+scene.width/2)*4
            #expect(first.rgba[footer+3]>200)
            #expect(stride(from: 3,to: first.rgba.count,by: 4).filter { first.rgba[$0]>0 }.count>1000)
            if scene.kind != .market { #expect(first.rgba != last.rgba) }
            #expect(try await renderer.render(scene,frame: 0).rgba==first.rgba)
            if let path = ProcessInfo.processInfo.environment["CLAUTO_GRAPHICS_GPU_SYNTHETIC_OUTPUT"] {
                let folder = URL(fileURLWithPath: path,isDirectory: true);try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                try CutoutImageIO.png(first).write(to: folder.appendingPathComponent("scene-"+scene.kind.rawValue+".png"),options: .withoutOverwriting)
            }
        }
    }
    @Test func actualProRes4444ContainsEveryExactFrameAndDecodedTransparency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-graphics-prores-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true);defer { try? FileManager.default.removeItem(at: root) }
        var scene = GraphicScene(kind: .particles,particles: .init());scene.width = 320;scene.height = 240;scene.frameCount = 8
        let output = try await GraphicAnimationExporter().export(scene,assets: .init(),to: SourceRenderDirectory.open(root))
        let asset = AVURLAsset(url: output.movieURL),track = try #require(await asset.loadTracks(withMediaType: .video).first)
        #expect(abs(try await asset.load(.duration).seconds-Double(scene.frameCount)*GraphicScene.frameDuration)<1e-6)
        let reader = try AVAssetReader(asset: asset),frames = AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        try #require(reader.canAdd(frames));reader.add(frames);try #require(reader.startReading())
        var count = 0,transparent = false,opaque = false
        while let sample = frames.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            #expect(abs(pts.seconds-Double(count)*GraphicScene.frameDuration)<1e-7)
            let image = try #require(CMSampleBufferGetImageBuffer(sample));#expect(CVPixelBufferGetWidth(image)==scene.width && CVPixelBufferGetHeight(image)==scene.height)
            CVPixelBufferLockBaseAddress(image,.readOnly)
            let memory = try #require(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self),stride = CVPixelBufferGetBytesPerRow(image)
            for y in 0..<scene.height { for x in 0..<scene.width { let alpha = memory[y*stride+x*4+3];transparent = transparent || alpha==0;opaque = opaque || alpha>=254 } }
            CVPixelBufferUnlockBaseAddress(image,.readOnly);count += 1
        }
        #expect(reader.status == .completed && count==8 && transparent && opaque)
        #expect(output.firstPNG != output.finalPNG)
    }

    @Test func adjacentTranslucentMeshTrianglesHaveNoInternalAlphaSeam() async throws {
        let color = GraphicColor(r: 0.32,g: 0.46,b: 0.37,a: 0.5)
        let shapes: [GraphicPrimitiveGPU] = [.triangle(.init(8,8),.init(56,8),.init(56,56),color: color),.triangle(.init(8,8),.init(56,56),.init(8,56),color: color)]
        let image = try await GraphicMetalRenderer().render(shapes,width: 64,height: 64)
        for n in 12..<52 {
            let diagonal = (n*64+n)*4,interior = (n*64+n+1)*4
            #expect(abs(Int(image.rgba[diagonal+3])-128)<=1 && abs(Int(image.rgba[interior+3])-128)<=1)
            #expect(abs(Int(image.rgba[diagonal])-82)<=1)
        }
        #expect(image.rgba[3]==0)
    }

    @Test func degenerateConcaveMeshesAndUnknownElementFormulasRefuseWhileTranslatedGeometryCenters() async throws {
        #expect(try GraphicElements.parseFormula("C6H12O6")==["C":6,"H":12,"O":6])
        for formula in ["Xx2","H0","Mg(OH)2","C99999999999999999999999999","H2O+","β"] {
            #expect(throws: (any Error).self) { _ = try GraphicElements.parseFormula(formula) }
        }
        let collapsed = Data("v 0 0 0\nv 1 0 0\nv 2 0 0\nf 1 2 3\n".utf8)
        let concave = Data("v 0 0 0\nv 2 0 0\nv 1 1 0\nv 2 2 0\nv 0 2 0\nf 1 2 3 4 5\n".utf8)
        #expect(throws: (any Error).self) { _ = try GraphicMeshImport.parseOBJ(collapsed) }
        #expect(throws: (any Error).self) { _ = try GraphicMeshImport.parseOBJ(concave) }
        var scene = GraphicScene.preset(.object);scene.width = 320;scene.height = 240;scene.frameCount = 1
        let first = try await GraphicSceneRenderer().render(scene,frame: 0)
        for i in scene.object!.vertices.indices { scene.object!.vertices[i].x += 100;scene.object!.vertices[i].y -= 200;scene.object!.vertices[i].z += 300 }
        #expect(try await GraphicSceneRenderer().render(scene,frame: 0).rgba==first.rgba)
        var molecule = GraphicScene.preset(.molecule);molecule.width = 320;molecule.height = 240;molecule.frameCount = 1
        let original = try await GraphicSceneRenderer().render(molecule,frame: 0)
        for i in molecule.molecule!.atoms.indices { molecule.molecule!.atoms[i].position.x += 100;molecule.molecule!.atoms[i].position.y -= 200;molecule.molecule!.atoms[i].position.z += 300 }
        #expect(try await GraphicSceneRenderer().render(molecule,frame: 0).rgba==original.rgba)
    }

    @Test func opaqueIntersectingTrianglesUseInterpolatedDepthInsteadOfSubmissionOrder() async throws {
        let red = GraphicPrimitiveGPU.triangle(.init(4,4),.init(60,4),.init(4,60),color: .init(r: 1,g: 0,b: 0),depth: .init(0.1,0.9,0.1))
        let blue = GraphicPrimitiveGPU.triangle(.init(4,4),.init(60,4),.init(4,60),color: .init(r: 0,g: 0,b: 1),depth: .init(repeating: 0.5))
        let renderer = GraphicMetalRenderer(),first = try await renderer.render([red,blue],width: 64,height: 64),reverse = try await renderer.render([blue,red],width: 64,height: 64)
        let left = (12*64+12)*4,right = (10*64+45)*4
        #expect(first.rgba[left]==255 && first.rgba[left+2]==0 && first.rgba[right]==0 && first.rgba[right+2]==255)
        #expect(first.rgba==reverse.rgba)
    }

    @Test func existingMovieIsPreservedAndRenamedRenderWorkspaceRefusesCurrentPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-graphic-path-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true);defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing");try FileManager.default.createDirectory(at: existing,withIntermediateDirectories: true)
        let sentinel = Data("Existing movie must survive".utf8);try sentinel.write(to: existing.appendingPathComponent("animation.mov"))
        var scene = GraphicScene.preset(.object);scene.width = 320;scene.height = 240;scene.frameCount = 3
        let stable = scene
        await #expect(throws: (any Error).self) { _ = try await GraphicAnimationExporter().export(stable,assets: .init(),to: SourceRenderDirectory.open(existing)) }
        #expect(try Data(contentsOf: existing.appendingPathComponent("animation.mov"))==sentinel)
        let path = root.appendingPathComponent("owned"),moved = root.appendingPathComponent("owned-moved")
        try FileManager.default.createDirectory(at: path,withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            _ = try await GraphicAnimationExporter().export(stable,assets: .init(),to: SourceRenderDirectory.open(path)) { done,_ in
                if done==1 {
                    try? FileManager.default.moveItem(at: path,to: moved)
                    try? FileManager.default.createDirectory(at: path,withIntermediateDirectories: true)
                    try? sentinel.write(to: path.appendingPathComponent("animation.mov"))
                }
            }
        }
        #expect(try Data(contentsOf: path.appendingPathComponent("animation.mov"))==sentinel)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("animation.mov").path))
    }

    @Test func movieBudgetRefusesBeforeEncodingAndChecksUnexpectedGrowingFileBetweenFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-graphic-budget-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true);defer { try? FileManager.default.removeItem(at: root) }
        var scene = GraphicScene.preset(.object);scene.width = 320;scene.height = 240;scene.frameCount = 2
        let folder = try SourceRenderDirectory.open(root),value = scene
        await #expect(throws: (any Error).self) { _ = try await GraphicAnimationExporter(movieByteLimit: 1024).export(value,assets: .init(),to: folder) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("animation.mov").path))
        #expect(throws: (any Error).self) { try GraphicMovieBudget.checkSpace(folder,remaining: 1,headroom: Int64.max) }
        let limit = try GraphicMovieBudget.plannedBytes(scene)+1024
        await #expect(throws: (any Error).self) {
            _ = try await GraphicAnimationExporter(movieByteLimit: limit).export(value,assets: .init(),to: folder) { done,_ in
                if done==1,let handle = try? FileHandle(forWritingTo: root.appendingPathComponent("animation.mov")) {
                    defer { try? handle.close() };try? handle.seekToEnd();try? handle.write(contentsOf: Data(repeating: 0,count: Int(limit)+1))
                }
            }
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("animation.mov").path))
    }

}
