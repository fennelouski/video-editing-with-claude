import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@MainActor @Suite(.serialized) struct GraphicSavedCutRenderTests {
    private func wait(_ ready: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return };try await Task.sleep(for: .milliseconds(5)) }
        throw WorkflowFailure.invalid("Synthetic graphic/font preparation timed out")
    }
    private func parent(project: Project,engine: URL) async throws -> CutVersion {
        let disk = WorkflowRepository();var run = try await disk.prepare(project: project,engine: engine,label: "Synthetic composition parent")
        let fm = FileManager.default
        for name in ["plan","exports","roughcut"] { try fm.createDirectory(at: run.folder.appendingPathComponent(name),withIntermediateDirectories: true) }
        try Data(#"{"script":"script.md","cues":[],"issues":[],"unresolved":[]}"#.utf8).write(to: run.folder.appendingPathComponent("plan/video.plan.json"))
        let source = project.folder.appendingPathComponent("synthetic-originals/a.mov")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11"><resources>
        <format id="rOut" frameDuration="1001/24000s" width="1920" height="1080"/>
        <format id="rIn" frameDuration="1001/24000s" width="320" height="180"/>
        <asset id="rA" name="Synthetic color and tone" start="0s" duration="72072/24000s" hasVideo="1" hasAudio="1" audioSources="1" audioChannels="2" format="rIn"><media-rep kind="original-media" src="\(source.absoluteString)"/></asset>
        </resources><library><event name="Synthetic"><project name="Synthetic parent"><sequence format="rOut" duration="12012/24000s" tcStart="0s" tcFormat="NDF"><spine><asset-clip ref="rA" offset="0s" start="0s" duration="12012/24000s"/></spine></sequence></project></event></library></fcpxml>
        """
        try Data(xml.utf8).write(to: run.folder.appendingPathComponent("exports/video.fcpxml"))
        let evidence: [String:Any] = ["timeline":"video.fcpxml","sha256":TranscriptSourceMap.sha(Data(xml.utf8)),"problems":[],"schemaChecked":false]
        try JSONSerialization.data(withJSONObject: evidence).write(to: run.folder.appendingPathComponent("exports/video.validation.json"))
        try Data("Synthetic fixture text; not ASR evidence.".utf8).write(to: run.folder.appendingPathComponent("roughcut/a.heard.txt"))
        run.state = .complete;run.approvedPlanHash = try await disk.plan(run).hash
        return try await disk.snapshot(run,project: project)
    }
    private func layeredScene(project: Project,engine: URL) async throws -> GraphicScene {
        let cuts = CutoutRepository(),bytes = try CutoutImageIO.png(.init(width: 32,height: 32,rgba: Data((0..<1024).flatMap { _ in [UInt8(240),20,40,255] })))
        var cut = try await cuts.create(project,id: UUID(),createdMilliseconds: 1,name: "Synthetic circle original.png",bytes: bytes)
        var corrected = cut.draft;corrected.recipe.strokes = [.init(mode: .restore,radiusPixels: 8,points: [.init(x: 0.5,y: 0.5)])]
        cut = try await cuts.save(project,base: cut,draft: corrected)
        let cutout = try await cuts.export(project,snapshot: cut,id: UUID(),created: Date())
        let font = FontStudioController(project: project,engine: engine)
        font.create(label: "Synthetic licensed custom S");try await wait { font.saved != nil && font.busy==nil }
        font.addGeneratedMapping();let mapping = try #require(font.selectedMappingID)
        font.updateMapping(mapping) { $0.character = "S" };font.trace(mapping);try await wait { font.busy==nil }
        font.compileFont();try await wait { font.busy==nil }
        let compiled = try #require(font.exported)
        var scene = GraphicScene.preset(.object);scene.width = 640;scene.height = 360;scene.frameCount = 12
        scene.object!.color = .init(r: 0.1,g: 0.8,b: 0.2)
        scene.imageLayers = [.init(cutoutID: cut.source.id,revisionID: cutout.revision.id,imageSHA256: TranscriptSourceMap.sha(try Data(contentsOf: cutout.pngURL)),transform: .init(x: 0.2,y: 0.25,width: 0.2,height: 0.2))]
        let reference = GraphicFontReference(fontID: compiled.revision.fontID,revisionID: compiled.revision.id,ttfSHA256: compiled.revision.ttfSHA256)
        scene.textLayers = [.init(text: "S",font: reference,fontSize: 0.08,transform: .init(x: 0.8,y: 0.25,width: 0.2,height: 0.2))]
        #expect(await font.flushForExit());return scene
    }
    @Test func actualNativeSavedCutCompositionUsesFrozenGraphicCutoutAndFontInputsAndKeepsTheParent() async throws {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-saved-graphic-render-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true);var completed = false;defer { if completed { try? FileManager.default.removeItem(at: root) } else { print("SYNTHETIC_COMPOSITION_FAILURE_ROOT="+root.path) } }
        let fixture = try await SyntheticSourceSpanFixture.generate(root: root,engine: engine)
        let imported = try await ProjectRepository().add([fixture.project.folder.appendingPathComponent("synthetic-originals/a.mov")],to: fixture.project)
        let project = try await ProjectRepository().approveScript("Synthetic composition fixture only.",project: imported)
        let disk = WorkflowRepository(),version = try await parent(project: project,engine: engine)
        let source = try await disk.derivativeSource(version,project: project),parentBytes = try Data(contentsOf: source.timeline)
        let repo = GraphicStudioRepository(),scene = try await layeredScene(project: project,engine: engine)
        let initial = try await repo.create(project,id: UUID(),label: "Synthetic layered scene",scene: scene)
        let first = try await GraphicSceneExportService(repository: repo).export(project,snapshot: initial) { _,_ in }
        var selected = try #require(try await repo.exportedChoices(project).first?.selection)
        selected.at = GraphicScene.frameDuration*2;selected.sourceStart = GraphicScene.frameDuration*2;selected.duration = GraphicScene.frameDuration*8
        selected.scale = 0.75;selected.x = 10
        var newer = first.snapshot.draft;newer.scene.object!.color = .init(r: 0.8,g: 0.1,b: 0.2)
        let next = try await repo.save(project,base: first.snapshot,draft: newer)
        let second = try await GraphicSceneExportService(repository: repo).export(project,snapshot: next) { _,_ in }
        #expect(second.revision.id != selected.revisionID)
        let request = DerivativeRequest(aspect: "16:9",resolution: .hd,end: GraphicScene.frameDuration*12,graphic: selected)
        let result = try await DerivativeService(runner: ProcessRunner(),disk: disk).export(request,version: version,project: project,engine: engine,onLine: { _ in })
        #expect(result.parentVersionID==version.id && result.request.graphic==selected)
        #expect(try await disk.current(project: project)?.id==version.id)
        let afterParent = try Data(contentsOf: source.timeline);#expect(afterParent==parentBytes)
        #expect(try await disk.derivatives(project: project).contains { $0.id==result.id })
        let folder = try await disk.derivativeFolder(result.id,project: project)
        let copied = try CreativeAssetFiles.decode(Data(contentsOf: folder.appendingPathComponent("graphic-scene.json")),as: GraphicSceneDraft.self)
        #expect(copied.scene==first.snapshot.draft.scene && copied.scene.imageLayers.count==1 && copied.scene.textLayers.first?.font != nil)
        let recipeURL = folder.appendingPathComponent("derivative.json"),originalRecipe = try Data(contentsOf: recipeURL)
        var recipe = try #require(JSONSerialization.jsonObject(with: originalRecipe) as? [String:Any])
        var graphic = try #require(recipe["generated_graphic"] as? [String:Any]),placement = try #require(graphic["placement"] as? [String:Any])
        placement["at"] = selected.at+GraphicScene.frameDuration;graphic["placement"] = placement;recipe["generated_graphic"] = graphic
        try JSONSerialization.data(withJSONObject: recipe).write(to: recipeURL)
        await #expect(throws: (any Error).self) { _ = try await disk.verifyDerivative(folder: folder,parentVersionID: version.id,parentHash: source.timelineSHA256,request: request,project: project) }
        try originalRecipe.write(to: recipeURL)
        #expect(try await disk.derivatives(project: project).contains { $0.id==result.id })
        #expect(try await disk.current(project: project)?.id==version.id)
        completed = true
    }
}
