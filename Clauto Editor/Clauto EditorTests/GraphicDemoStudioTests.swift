import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

@Suite(.serialized) struct GraphicDemoStudioTests {
    private func request() -> GraphicDemoRequest {
        .init(schemaVersion: 1,requestID: UUID(uuidString: "4AE28527-E372-4B25-A0EB-E422D1B0AC19")!,label: "Pan form inspection",width: 1920,height: 1080,frameCount: 96,
              rig: .preset(.hero),mesh: .cube,
              provenance: .init(assetID: "local-pan",name: "Local pan geometry",creator: "Project original",sourceURL: "local-project:Pan Seasoning",license: "Local rights not independently verified",sourceSHA256: String(repeating: "a",count: 64),modifications: "Geometry retained; illustrative matte material",rightsStatus: .localUnverified,sourceFiles: [:],licenseText: ""),
              assumptions: ["Illustrative form only; no material or scientific inference"],reviewNotes: "Visual and scientific review remain separate.")
    }
    private func bytes(_ value: GraphicDemoRequest) throws -> Data { try CreativeAssetFiles.encoder().encode(value) }

    @Test func preparedSceneRepeatsExactIdentityAssumptionsAndProvenance() throws {
        let a = try GraphicDemoRequest.decode(bytes(request())),b = try GraphicDemoRequest.decode(bytes(request()))
        let first = try a.scene(),second = try b.scene()
        #expect(first==second && first.id==a.requestID)
        #expect(first.assumptions.first?.id==second.assumptions.first?.id)
        #expect(first.demoRig?.stepFrames==2 && first.demoProvenance?.rightsStatus == .localUnverified)
        #expect(first.width==1920 && first.height==1080 && first.frameCount==96)
    }
    @Test func preparedRequestsRejectUnknownDuplicateNonfiniteAndMissingFields() throws {
        let input = try bytes(request())
        var object = try JSONSerialization.jsonObject(with: input) as! [String:Any]
        object["unknown"] = "not silently ignored"
        #expect(throws: (any Error).self) { _ = try GraphicDemoRequest.decode(JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "unknown");var rig = object["rig"] as! [String:Any];rig["focalLength"] = 85;object["rig"] = rig
        #expect(throws: (any Error).self) { _ = try GraphicDemoRequest.decode(JSONSerialization.data(withJSONObject: object)) }
        let duplicate = Data(("{\"schemaVersion\":1,"+String(String(decoding: input,as: UTF8.self).dropFirst())).utf8)
        #expect(throws: (any Error).self) { _ = try GraphicDemoRequest.decode(duplicate) }
        let nonfinite = Data(String(decoding: input,as: UTF8.self).replacingOccurrences(of: "\"yawRadians\":0.6",with: "\"yawRadians\":NaN").utf8)
        #expect(throws: (any Error).self) { _ = try GraphicDemoRequest.decode(nonfinite) }
        object = try JSONSerialization.jsonObject(with: input) as! [String:Any];object.removeValue(forKey: "provenance")
        #expect(throws: (any Error).self) { _ = try GraphicDemoRequest.decode(JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func rigAndLicenseDeclarationsRefuseUnsafeOrAmbiguousInputs() throws {
        var rig = GraphicDemoRig.preset(.hero);rig.stepFrames = 1
        #expect(throws: (any Error).self) { try rig.validate() }
        rig = .preset(.hero);rig.seed = 0
        #expect(throws: (any Error).self) { try rig.validate() }
        rig = .preset(.hero);rig.pitchRadians = Double.pi
        #expect(throws: (any Error).self) { try rig.validate() }
        var provenance = request().provenance;provenance.rightsStatus = .cc0
        #expect(throws: (any Error).self) { try provenance.validate() }
        provenance.licenseText = "Recorded CC0 notice";provenance.sourceFiles = ["source.gltf":String(repeating: "b",count: 64)]
        try provenance.validate();provenance.sourceFiles = ["../source.gltf":String(repeating: "b",count: 64)]
        #expect(throws: (any Error).self) { try provenance.validate() }
    }
    @Test func legacyScenesRemainRiglessAndNewObjectScenesUseCraftPreset() throws {
        let legacy = GraphicScene(kind: .object,object: .cube)
        let bytes = try CreativeAssetFiles.encoder().encode(legacy)
        let restored = try CreativeAssetFiles.decode(bytes,as: GraphicScene.self)
        #expect(restored.demoRig==nil && restored.demoProvenance==nil)
        let craft = GraphicScene.preset(.object)
        #expect(craft.demoRig?.template == .hero && craft.demoRig?.material == .sageClay)
        #expect(craft.width==1920 && craft.height==1080)
        for template in GraphicDemoRig.Template.allCases { try GraphicDemoRig.preset(template).validate() }
    }
    @MainActor @Test func repeatedImportKeepsOneSceneAndRefusesToReplaceNewerEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-demo-import-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true);defer { try? FileManager.default.removeItem(at: root) }
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try await ProjectRepository().create(name: "Synthetic reusable demo",root: root,engine: engine)
        let repository = GraphicStudioRepository(),controller = GraphicStudioController(project: project,repository: repository)
        let url = root.appendingPathComponent("prepared.json");try bytes(request()).write(to: url)
        @MainActor func wait() async throws {
            for _ in 0..<1000 { if controller.busy==nil { return };try await Task.sleep(for: .milliseconds(5)) }
            throw WorkflowFailure.invalid("Synthetic demo import timed out")
        }
        controller.importDemo(url);try await wait()
        #expect(controller.issue==nil && controller.draft?.id==request().requestID)
        let first = try #require(controller.saved)
        controller.importDemo(url);try await wait()
        #expect(controller.issue==nil && controller.saved==first)
        #expect(try await repository.list(project).count==1)
        controller.changeScene(first.draft.id) { $0.label = "Newer saved correction" }
        #expect(await controller.saveNow())
        let edited = try #require(controller.saved)
        controller.importDemo(url);try await wait()
        #expect(controller.issue?.contains("different saved edits")==true)
        let reopened = try await repository.load(project,id: first.draft.id)
        #expect(controller.saved==edited && reopened==edited)
        controller.applyDemoTemplate(.overhead,sceneID: UUID())
        #expect(controller.draft?.scene.demoRig?.template == .hero)
        controller.useCube(sceneID: first.draft.id)
        #expect(controller.draft?.scene.demoProvenance==nil && controller.draft?.scene.demoRig != nil)
        #expect(await controller.flushForExit())
    }
}
