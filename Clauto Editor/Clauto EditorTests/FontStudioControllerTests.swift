import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
#if canImport(ClautoCore)
@testable import ClautoCore
#else
@testable import Clauto_Editor
#endif

struct FontStudioControllerTests {
    private func fixture() async throws -> (URL,Project,URL) {
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-font-controls-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        return (root,try await ProjectRepository().create(name: "Synthetic font controls",root: root,engine: engine),engine)
    }
    @MainActor private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(for: .milliseconds(5)) }
        throw WorkflowFailure.invalid("Synthetic font condition timed out")
    }
    @MainActor @Test func incompleteMappingConflictRecoveryGeneratedOutlinesAndRealRebuildPreserveBothRevisions() async throws {
        let (root,project,engine) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let repo = FontStudioRepository(),controller = FontStudioController(project: project,engine: engine)
        controller.create(label: "Synthetic generated font");try await wait { controller.saved != nil && controller.busy == nil }
        controller.addGeneratedMapping()
        let id = try #require(controller.selectedMappingID)
        controller.updateMapping(id) { $0.character = "S";$0.baseline = "0.";$0.threshold = "-" }
        #expect(await controller.saveNow())
        let base = try #require(controller.saved),fontID = base.draft.id
        #expect(try await repo.load(project,id: fontID).draft.pendingMappings[0].threshold == "-")
        var other = base.draft;other.label = "Other writer"
        let foreign = try await repo.save(project,base: base,draft: other)
        controller.updateMapping(id) { $0.baseline = "0.8";$0.threshold = "0.55" }
        #expect(!(await controller.saveNow()) && controller.dirty && controller.conflict)
        #expect(!(await controller.flushForExit()))
        controller.keepBoth();try await wait { controller.busy == nil }
        let copyID = try #require(controller.draft?.id);#expect(copyID != fontID)
        #expect(try await repo.load(project,id: fontID) == foreign)
        #expect(controller.draft?.pendingMappings[0].character == "S" && controller.draft?.pendingMappings[0].baseline == "0.8")
        controller.trace(id);try await wait { controller.busy == nil }
        #expect(controller.issue == nil)
        let glyph = try #require(controller.draft?.glyphs.first)
        #expect(glyph.origin == .generatedFallback && glyph.sourceID == nil && glyph.outline.contours.flatMap({ $0 }).contains(where: { !$0.onCurve }))
        controller.compileFont();try await wait { controller.busy == nil }
        let first = try #require(controller.exported),firstBytes = try Data(contentsOf: first.ttfURL)
        #expect(first.revision.licenseSHA256 != nil)
        let provider = try #require(CGDataProvider(data: firstBytes as CFData)),parsed = try #require(CGFont(provider)),font = CTFontCreateWithGraphicsFont(parsed,48,nil,nil)
        let preview = try FontPreviewGeometry.layout("S?S",font: font,width: 600)
        #expect(preview.glyphs.count==3 && preview.glyphs[0] != 0 && preview.glyphs[1]==0 && preview.glyphs[2]==preview.glyphs[0])
        #expect(preview.missing == ["?"] && preview.paths.count==3)
        let p = try #require(glyph.outline.contours.first?.first)
        controller.editPoint(glyphID: glyph.id,contour: 0,point: 0,x: p.x+8,y: p.y,onCurve: p.onCurve)
        #expect(controller.draft?.glyphs[0].origin == .editedOutline && controller.draft?.glyphs[0].provenanceLabel.contains("generated") == true)
        controller.undoChange();#expect(controller.draft?.glyphs[0] == glyph)
        controller.redoChange();#expect(controller.draft?.glyphs[0].outline != glyph.outline)
        controller.compileFont();try await wait { controller.busy == nil }
        let second = try #require(controller.exported)
        #expect(second.revision.id != first.revision.id && second.revision.parentRevisionID == first.revision.id)
        #expect(try Data(contentsOf: first.ttfURL) == firstBytes)
        #expect(try Data(contentsOf: second.ttfURL) != firstBytes)
        #expect(try await repo.revisions(project,fontID: copyID).map(\.id) == [second.revision.id,first.revision.id])
        #expect(try await repo.fontBytes(project,fontID: copyID,revisionID: first.revision.id).bytes == firstBytes)
        #expect(await controller.flushForExit())
        let reopened = FontStudioController(project: project,engine: engine);reopened.open(copyID)
        try await wait { reopened.saved != nil && reopened.busy == nil }
        #expect(reopened.draft?.currentFontRevisionID == second.revision.id && reopened.draft?.glyphs[0].revisionID == second.snapshot.draft.glyphs[0].revisionID)
        #expect(await reopened.flushForExit())
    }
    @Test func folderIntakeSkipsSymlinksAndNonImagesAndSortsTheExplicitSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clauto-font-folder-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cells"),withIntermediateDirectories: true);defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("cells/A.PNG"),b = root.appendingPathComponent("B.heic")
        try Data([1]).write(to: a);try Data([2]).write(to: b);try Data([3]).write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.jpg"),withDestinationURL: a)
        let found = try await FontImageIntake().images(in: [root,b])
        #expect(found.map(\.lastPathComponent) == ["B.heic","A.PNG"])
        await #expect(throws: (any Error).self) { _ = try await FontImageIntake().images(in: [root.appendingPathComponent("notes.txt")]) }
    }
    @Test func rotatedSheetRetainsEncodedOriginalAndHashesOneCanonicalWorkingRaster() async throws {
        let (root,project,_) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let raster = CutoutRaster(width: 6,height: 4,rgba: Data(repeating: 255,count: 6*4*4)),data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(writer,try CutoutImageIO.image(raster),[kCGImagePropertyOrientation:6] as CFDictionary);#expect(CGImageDestinationFinalize(writer))
        let raw = data as Data,repo = FontStudioRepository(),id = UUID()
        _ = try await repo.create(project,id: id,label: "Synthetic rotated sheet")
        let source = try await repo.importImage(project,fontID: id,id: UUID(),name: "sheet.tiff",bytes: raw)
        #expect(source.width==4 && source.height==6 && source.orientation==6)
        #expect(try await repo.imageBytes(project,fontID: id,source: source)==raw)
        let working = try #require(await repo.rasterBytes(project,fontID: id,source: source)),decoded = try CutoutImageIO.decode(working)
        #expect(decoded.orientation==1 && decoded.raster.width==4 && decoded.raster.height==6 && TranscriptSourceMap.sha(working)==source.workingRasterSHA256)
        let path = project.folder.appendingPathComponent("assets/generated-fonts/\(id)/sources/\(source.id)/working-raster.image")
        try Data("changed raster".utf8).write(to: path)
        await #expect(throws: (any Error).self) { _ = try await repo.rasterBytes(project,fontID: id,source: source) }
    }
    @Test func TrueTypePreviewRetainsOffCurveStartAndImpliedMidpoints() throws {
        let outline = FontGlyphOutline(advance: 500,contours: [[.init(x: 0,y: 500,onCurve: false),.init(x: 500,y: 500,onCurve: false),.init(x: 500,y: 0,onCurve: true),.init(x: 0,y: 0,onCurve: false)]])
        let path = try FontOutlineGeometry.path(outline);var curves = 0,lines = 0
        path.applyWithBlock { element in if element.pointee.type == .addQuadCurveToPoint { curves += 1 };if element.pointee.type == .addLineToPoint { lines += 1 } }
        #expect(curves==3 && lines==0 && path.contains(CGPoint(x: 250,y: 200)))
    }
}
