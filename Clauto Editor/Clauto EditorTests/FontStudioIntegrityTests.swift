import Foundation
import Testing
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

actor FontMismatchedReplyRunner: CommandRunning {
    enum Mutation: String,CaseIterable,Sendable { case character,crop,raster }
    let mutation: Mutation
    init(_ mutation: Mutation) { self.mutation = mutation }
    func run(_ command: ProcessCommand,onLine: (@Sendable (ProcessLine) async -> Void)?) async throws -> ProcessResult {
        let request = try #require(command.arguments.count==4 ? URL(fileURLWithPath: command.arguments[2]):nil)
        var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: request)) as? [String:Any])
        let outline = FontGlyphOutline(advance: 500,contours: [[.init(x: 0,y: 0,onCurve: true),.init(x: 250,y: 700,onCurve: true),.init(x: 500,y: 0,onCurve: true)]])
        value["origin"] = "supplied_image";value["outline"] = try JSONSerialization.jsonObject(with: CreativeAssetFiles.encoder().encode(outline));value["outline_sha256"] = try outline.sha256
        switch mutation {
        case .character:value["scalar"] = (value["scalar"] as! Int)+1
        case .crop:value["crop"] = [0,0,0.5,1]
        case .raster:value.removeValue(forKey: "raster_file");value.removeValue(forKey: "raster_sha256")
        }
        let output = URL(fileURLWithPath: command.arguments[3]);try FileManager.default.createDirectory(at: output,withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: value,options: [.sortedKeys]).write(to: output.appendingPathComponent("glyph.json"),options: .withoutOverwriting)
        return .init(exitCode: 0,output: "{\"ok\":true}",error: "",cancelled: false)
    }
    func cancel() async {}
}
struct FontStudioIntegrityTests {
    private func fixture() async throws -> (URL,Project,URL) {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-font-integrity-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        return (root,try await ProjectRepository().create(name: "Synthetic font integrity",root: root,engine: engine),engine)
    }
    private func image() throws -> Data { try CutoutImageIO.png(.init(width: 8,height: 8,rgba: Data(repeating: 255,count: 8*8*4))) }
    @MainActor private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(for: .milliseconds(5)) }
        throw WorkflowFailure.invalid("Synthetic font integrity condition timed out")
    }
    @MainActor @Test(arguments: FontMismatchedReplyRunner.Mutation.allCases) func mismatchedSuccessfulTraceNeverConsumesOrReplacesTheRequestedMapping(_ mutation: FontMismatchedReplyRunner.Mutation) async throws {
        let (root,project,engine) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let runner = FontMismatchedReplyRunner(mutation),controller = FontStudioController(project: project,engine: engine,compiler: FontCompilerService(makeRunner: { runner }))
        controller.create(label: "Synthetic mismatched reply");try await wait { controller.saved != nil && controller.busy == nil }
        let url = root.appendingPathComponent("A.png");try image().write(to: url)
        controller.importImages([url]);try await wait { controller.busy == nil }
        let mapping = try #require(controller.draft?.pendingMappings.first),before = try #require(controller.saved)
        controller.trace(mapping.id);try await wait { controller.busy == nil }
        #expect(controller.draft?.pendingMappings == [mapping] && controller.draft?.glyphs.isEmpty == true && controller.issue != nil)
        #expect(controller.saved == before && !controller.dirty)
        #expect(await controller.flushForExit())
        #expect(try await FontStudioRepository().load(project,id: before.draft.id).draft.pendingMappings == [mapping])
    }
    @Test func replacedLeafAndReplacedParentAreRefusedBeforeCopyingUnselectedBytes() async throws {
        let (root,_,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("chosen"),other = root.appendingPathComponent("other.png")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true);let leaf = folder.appendingPathComponent("A.png")
        try image().write(to: leaf);try image().write(to: other)
        let intake = FontImageIntake(),candidate = try #require(await intake.candidates(in: [leaf]).first)
        try FileManager.default.removeItem(at: leaf);try FileManager.default.createSymbolicLink(at: leaf,withDestinationURL: other)
        await #expect(throws: (any Error).self) { _ = try await intake.read(candidate) }
        try FileManager.default.removeItem(at: leaf);try image().write(to: leaf)
        try FileManager.default.moveItem(at: folder,to: root.appendingPathComponent("preserved"))
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true);try image().write(to: leaf)
        await #expect(throws: (any Error).self) { _ = try await intake.read(candidate) }
    }
    @Test func sourceCollectionAndRecoveryEnforceBudgetBeforePublishingTheDraft() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = FontStudioRepository(inputByteLimit: 8),id = UUID(),initial = try await repo.create(project,id: id,label: "Synthetic bounded collection")
        let source = try await repo.importImage(project,fontID: id,id: UUID(),name: "A.png",bytes: image())
        let outline = FontGlyphOutline(advance: 500,contours: [[.init(x: 0,y: 0,onCurve: true),.init(x: 250,y: 700,onCurve: true),.init(x: 500,y: 0,onCurve: true)]])
        var draft = initial.draft;draft.sources = [source];draft.glyphs = [.init(id: UUID(),revisionID: UUID(),scalar: 65,origin: .suppliedImage,sourceID: source.id,sourceFile: source.id.uuidString+".image",sourceSHA256: source.sha256,outline: outline,outlineSHA256: try outline.sha256)]
        await #expect(throws: (any Error).self) { _ = try await repo.save(project,base: initial,draft: draft) }
        await #expect(throws: (any Error).self) { _ = try await repo.copyDraft(project,snapshot: initial,draft: draft,newID: UUID()) }
        #expect(try await repo.load(project,id: id)==initial)
        #expect(try await repo.list(project).count==1)
        #expect(try await repo.imageBytes(project,fontID: id,source: source)==image())
    }
}
