import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@Suite(.serialized) struct GraphicCompositionTests {
    private func fixture() async throws -> (URL,Project) {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-graphic-composition-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        return (root,try await ProjectRepository().create(name: "Synthetic graphic composition",root: root,engine: engine))
    }
    private func exported(_ project: Project) async throws -> GraphicExportResult {
        let repo = GraphicStudioRepository();var scene = GraphicScene.preset(.object)
        scene.width = 640;scene.height = 360;scene.frameCount = 4;scene.object!.color = .init(r: 0.9,g: 0.1,b: 0.1)
        let saved = try await repo.create(project,id: UUID(),label: "Synthetic red graphic",scene: scene)
        return try await GraphicSceneExportService(repository: repo).export(project,snapshot: saved) { _,_ in }
    }
    @Test func selectedOlderRevisionRemainsPinnedAfterAnotherExportAndRefusesMissingFrames() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = GraphicStudioRepository(),first = try await exported(project)
        let choices = try await repo.exportedChoices(project),selected = try #require(choices.first?.selection)
        #expect(choices.count==1 && selected.revisionID==first.revision.id && selected.movieSHA256==first.revision.proof.movie.sha256)
        let oldBytes = try Data(contentsOf: first.movieURL)
        var changed = first.snapshot.draft;changed.scene.object!.color = .init(r: 0.1,g: 0.1,b: 0.9)
        let saved = try await repo.save(project,base: first.snapshot,draft: changed)
        let second = try await GraphicSceneExportService(repository: repo).export(project,snapshot: saved) { _,_ in }
        #expect(second.revision.id != selected.revisionID && second.revision.proof.movie.sha256 != selected.movieSHA256)
        let reopened = try await repo.exportRevision(project,sceneID: selected.sceneID,revisionID: selected.revisionID)
        let reopenedBytes = try Data(contentsOf: reopened.movieURL)
        #expect(reopened.revision==first.revision && reopenedBytes==oldBytes)
        try selected.validate(cutDuration: 1);try selected.validateSource(reopened.revision,project: project.id)
        var missing = selected;missing.sourceStart = GraphicScene.frameDuration*4
        #expect(throws: (any Error).self) { try missing.validateSource(reopened.revision,project: project.id) }
        var tooShort = selected;tooShort.duration = 0.00001
        #expect(throws: (any Error).self) { try tooShort.validate(cutDuration: 1) }
        var outside = selected;outside.at = 1
        #expect(throws: (any Error).self) { try outside.validate(cutDuration: 1) }
        #expect(throws: (any Error).self) { try selected.validateSource(reopened.revision,project: UUID()) }
        #expect(try await repo.exportedChoices(project).first?.selection.revisionID==second.revision.id)
    }
    @Test func nativeGraphicReceiptAdmissionBindsCopiedInputsMovieIdentityPlacementAndAllProvenance() async throws {
        let (root,project) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let result = try await exported(project),selected = try #require(try await GraphicStudioRepository().exportedChoices(project).first?.selection)
        let manifest = project.folder.appendingPathComponent(selected.relativeManifestPath).resolvingSymlinksInPath(),folder = manifest.deletingLastPathComponent()
        let rawRevision = try Data(contentsOf: manifest),rawScene = try Data(contentsOf: folder.appendingPathComponent("scene.json"))
        let physicalManifest = try GraphicCompositionPaths.canonical(manifest),physicalFolder = (physicalManifest as NSString).deletingLastPathComponent
        var sources = [physicalManifest:selected.manifestSHA256]
        for (name,record) in result.revision.files { sources[(physicalFolder as NSString).appendingPathComponent(name)] = record.sha256 }
        let requestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected))
        let placement: [String:Any] = ["at":0.0,"source_start":0.0,"duration":selected.duration,"scale":1.0,"x":0.0,"y":0.0]
        let metadata: [String:Any] = ["request":requestObject,"placement":placement,"source_dimensions":[640,360],"source_frame_count":4,
            "revision_path":physicalManifest,"renderer_version":result.revision.rendererVersion,"metal_shader_sha256":result.revision.metalShaderSHA256,
            "validation_label":result.revision.validationLabel,"assumptions":result.revision.assumptions,"source_sha256":sources]
        try selected.verifyMetadata(metadata,revisionBytes: rawRevision,sceneBytes: rawScene,project: project)
        var wrong = metadata,p = placement;p["at"] = GraphicScene.frameDuration;wrong["placement"] = p
        #expect(throws: (any Error).self) { try selected.verifyMetadata(wrong,revisionBytes: rawRevision,sceneBytes: rawScene,project: project) }
        wrong = metadata;wrong["source_sha256"] = [manifest.path:selected.manifestSHA256]
        #expect(throws: (any Error).self) { try selected.verifyMetadata(wrong,revisionBytes: rawRevision,sceneBytes: rawScene,project: project) }
        wrong = metadata;wrong["renderer_version"] = "unrelated renderer"
        #expect(throws: (any Error).self) { try selected.verifyMetadata(wrong,revisionBytes: rawRevision,sceneBytes: rawScene,project: project) }
        #expect(throws: (any Error).self) { try selected.verifyMetadata(metadata,revisionBytes: Data("replaced manifest".utf8),sceneBytes: rawScene,project: project) }
        var nonfinite = selected;nonfinite.scale = .infinity
        #expect(throws: (any Error).self) { try nonfinite.validate(cutDuration: 1) }
    }
}
